package expo.modules.mediaedit

import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Bundle
import androidx.media3.common.util.UnstableApi
import expo.modules.kotlin.Promise
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import java.io.File

@UnstableApi
class ExpoMediaEditModule : Module() {

  @Volatile private var activeExporter: ProjectExporter? = null

  override fun definition() = ModuleDefinition {
    Name("ExpoMediaEdit")

    Events("onProgress")

    // MARK: - exportProject(project, outputUri?, opts?)
    AsyncFunction("exportProject") { projectMap: Map<String, Any?>, outputUri: String?, opts: Map<String, Any?>?, promise: Promise ->
      val ctx = requireNotNull(appContext.reactContext) { "React context not available" }

      val outputFile = if (outputUri != null && outputUri.isNotEmpty()) {
        resolveAllowedOutputFile(ctx, outputUri)
          ?: run {
            promise.reject("INVALID_OUTPUT", "outputUri must be a file:// path inside the app's sandbox", null)
            return@AsyncFunction
          }
      } else {
        createTempFile(ctx, "output", ".mp4")
      }

      val quality = (opts?.get("quality") as? String) ?: "high"

      Thread {
        val compiled = try {
          val project = ProjectParser.parse(projectMap)
          ProjectCompiler.compile(ctx, project, ProjectCompiler.Mode.EXPORT)
        } catch (e: Exception) {
          promise.reject("COMPILE_FAILED", "${e.javaClass.simpleName}: ${e.message ?: ""}", e)
          return@Thread
        }

        val exporter = ProjectExporter(ctx)
        activeExporter = exporter
        exporter.export(
          composition = compiled.composition,
          outputFile = outputFile,
          quality = quality,
          onProgress = { p ->
            sendEvent("onProgress", Bundle().apply { putDouble("progress", p.toDouble()) })
          },
          completion = { result ->
            activeExporter = null
            result.fold(
              onSuccess = { f -> promise.resolve("file://${f.absolutePath}") },
              onFailure = { e ->
                if (e is CancellationException) promise.reject("CANCELLED", e.message ?: "cancelled", e)
                else promise.reject("EXPORT_FAILED", e.message ?: "Unknown export error", e)
              }
            )
          }
        )
      }.start()
    }

    AsyncFunction("cancelExport") { promise: Promise ->
      activeExporter?.cancel()
      promise.resolve(null)
    }

    // MARK: - getVideoInfo / generateThumbnail / extractAudio / cleanTempFiles
    // Unchanged from 0.13.x — independent of the composer.

    AsyncFunction("getVideoInfo") { uri: String, promise: Promise ->
      if (!isReadableUriAllowed(uri)) {
        promise.reject("INVALID_URI", "uri must be a file:// or https:// URI without path traversal", null)
        return@AsyncFunction
      }
      val ctx = requireNotNull(appContext.reactContext)
      val retriever = MediaMetadataRetriever()
      try {
        retriever.setDataSource(ctx, Uri.parse(uri))
        val durationMs = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLong() ?: 0L
        val rawWidth = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toInt() ?: 0
        val rawHeight = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toInt() ?: 0
        val rotation = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toInt() ?: 0
        val (width, height) = if (rotation == 90 || rotation == 270) rawHeight to rawWidth else rawWidth to rawHeight
        val fileSize = if (uri.startsWith("file://")) File(uri.removePrefix("file://")).length() else 0L

        var fps = 0f
        var codecMime: String? = null
        val extractor = MediaExtractor()
        try {
          extractor.setDataSource(ctx, Uri.parse(uri), null)
          for (i in 0 until extractor.trackCount) {
            val format = extractor.getTrackFormat(i)
            val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
            if (mime.startsWith("video/")) {
              codecMime = mime
              if (format.containsKey(MediaFormat.KEY_FRAME_RATE)) {
                fps = try { format.getInteger(MediaFormat.KEY_FRAME_RATE).toFloat() }
                      catch (_: Exception) { format.getFloat(MediaFormat.KEY_FRAME_RATE) }
              }
              break
            }
          }
        } catch (_: Exception) {
          fps = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_CAPTURE_FRAMERATE)?.toFloat() ?: 0f
        } finally {
          extractor.release()
        }
        val codec = mimeToFourCC(codecMime)

        promise.resolve(mapOf(
          "durationMs" to durationMs.toDouble(),
          "width" to width.toDouble(),
          "height" to height.toDouble(),
          "fps" to fps.toDouble(),
          "fileSize" to fileSize.toDouble(),
          "codec" to codec
        ))
      } finally {
        retriever.release()
      }
    }

    AsyncFunction("generateThumbnail") { uri: String, timeMs: Double, options: Map<String, Any?>?, promise: Promise ->
      if (!isReadableUriAllowed(uri)) {
        promise.reject("INVALID_URI", "uri must be a file:// or https:// URI without path traversal", null)
        return@AsyncFunction
      }
      val ctx = requireNotNull(appContext.reactContext)
      val retriever = MediaMetadataRetriever()
      try {
        retriever.setDataSource(ctx, Uri.parse(uri))
        val bitmap = retriever.getFrameAtTime(
          (timeMs * 1000).toLong(),
          MediaMetadataRetriever.OPTION_CLOSEST_SYNC
        )
        if (bitmap != null) {
          val outputFile = createTempFile(ctx, "thumb", ".jpg")
          outputFile.outputStream().use { out ->
            bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG, 80, out)
          }
          bitmap.recycle()
          promise.resolve("file://${outputFile.absolutePath}")
        } else {
          promise.reject("THUMBNAIL_FAILED", "Could not extract frame at ${timeMs}ms", null)
        }
      } finally {
        retriever.release()
      }
    }

    AsyncFunction("extractAudio") { uri: String, promise: Promise ->
      if (!isReadableUriAllowed(uri)) {
        promise.reject("INVALID_URI", "uri must be a file:// or https:// URI without path traversal", null)
        return@AsyncFunction
      }
      val ctx = requireNotNull(appContext.reactContext)
      Thread {
        try {
          val extractor = MediaExtractor()
          extractor.setDataSource(ctx, Uri.parse(uri), null)
          var audioTrack = -1
          var audioFormat: MediaFormat? = null
          for (i in 0 until extractor.trackCount) {
            val format = extractor.getTrackFormat(i)
            val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
            if (mime.startsWith("audio/")) {
              audioTrack = i; audioFormat = format; break
            }
          }
          if (audioTrack < 0 || audioFormat == null) {
            extractor.release()
            promise.reject("NO_AUDIO_TRACK", "Source has no audio track", null)
            return@Thread
          }
          extractor.selectTrack(audioTrack)
          val outputFile = createTempFile(ctx, "audio", ".m4a")
          val muxer = android.media.MediaMuxer(outputFile.absolutePath, android.media.MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
          val muxAudioTrack = muxer.addTrack(audioFormat)
          muxer.start()
          val bufferSize = audioFormat.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE)
            .let { if (it > 0) it else 1024 * 1024 }
          val buffer = java.nio.ByteBuffer.allocate(bufferSize)
          val bufferInfo = android.media.MediaCodec.BufferInfo()
          while (true) {
            val sampleSize = extractor.readSampleData(buffer, 0)
            if (sampleSize < 0) break
            bufferInfo.offset = 0
            bufferInfo.size = sampleSize
            bufferInfo.presentationTimeUs = extractor.sampleTime
            bufferInfo.flags = extractor.sampleFlags
            muxer.writeSampleData(muxAudioTrack, buffer, bufferInfo)
            extractor.advance()
          }
          muxer.stop(); muxer.release(); extractor.release()
          promise.resolve("file://${outputFile.absolutePath}")
        } catch (e: Exception) {
          promise.reject("EXTRACT_FAILED", e.message ?: "Audio extraction failed", e)
        }
      }.start()
    }

    AsyncFunction("cleanTempFiles") { promise: Promise ->
      val ctx = requireNotNull(appContext.reactContext)
      val tempDir = File(ctx.cacheDir, "expo-media-edit")
      var count = 0
      tempDir.listFiles()?.forEach { file -> if (file.delete()) count++ }
      promise.resolve(count)
    }

    // MARK: - <MediaPreview /> view

    View(MediaPreviewView::class) {
      Events("onTime", "onReady", "onError")

      Prop("project") { view: MediaPreviewView, project: Map<String, Any?> ->
        view.updateProject(project)
      }
      Prop("time") { view: MediaPreviewView, time: Double ->
        view.updateTime(time)
      }
      Prop("playing") { view: MediaPreviewView, playing: Boolean ->
        view.updatePlaying(playing)
      }
      Prop("renderScale") { view: MediaPreviewView, scale: Double ->
        view.updateRenderScale(scale)
      }
    }
  }
}

class CancellationException(message: String) : Exception(message)

private fun mimeToFourCC(mime: String?): String? = when (mime) {
  null -> null
  "video/avc" -> "avc1"
  "video/hevc" -> "hvc1"
  "video/x-vnd.on2.vp8" -> "vp08"
  "video/x-vnd.on2.vp9" -> "vp09"
  "video/av01" -> "av01"
  "video/mp4v-es" -> "mp4v"
  else -> mime
}
