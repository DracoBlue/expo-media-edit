package expo.modules.mediaedit

import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Bundle
import expo.modules.kotlin.Promise
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import java.io.File

class ExpoMediaEditModule : Module() {

  @Volatile private var cancelRequested = false

  override fun definition() = ModuleDefinition {
    Name("ExpoMediaEdit")

    Events("onProgress")

    AsyncFunction("editVideo") { jobMap: Map<String, Any?>, promise: Promise ->
      val ctx = requireNotNull(appContext.reactContext) { "React context not available" }
      val job = EditJob.fromMap(jobMap)
      cancelRequested = false

      val outputFile = if (job.outputUri != null) {
        val path = Uri.parse(job.outputUri).path
          ?: throw IllegalArgumentException("outputUri path is null")
        File(path)
      } else {
        createTempFile(ctx, "output", ".mp4")
      }

      val progressCallback: (Float) -> Unit = { progress ->
        val bundle = Bundle().apply { putDouble("progress", progress.toDouble()) }
        sendEvent("onProgress", bundle)
      }
      val completion: (Result<Uri>) -> Unit = { result ->
        cancelRequested = false
        result.fold(
          onSuccess = { uri -> promise.resolve(uri.toString()) },
          onFailure = { e ->
            if (e is CancellationException) {
              promise.reject("CANCELLED", "Edit was cancelled", e)
            } else {
              promise.reject("EDIT_FAILED", e.message ?: "Unknown error", e)
            }
          }
        )
      }

      Thread {
        val playlist = job.playlist
        if (playlist != null && (playlist.size > 1 || playlist.firstOrNull() is PlaylistItemConfig.ImageItem)) {
          PlaylistCompositor(ctx).composite(
            playlist = playlist,
            overlays = job.overlays,
            audio = job.audio,
            quality = job.quality,
            outputFile = outputFile,
            progressCallback = progressCallback,
            cancelCheck = { cancelRequested },
            completion = completion
          )
        } else {
          // Single-video fast path
          val firstItem = playlist?.firstOrNull() as? PlaylistItemConfig.VideoItem
          if (firstItem == null) {
            promise.reject("INVALID_INPUT", "No valid video item in playlist", null)
            return@Thread
          }
          val inputUri = Uri.parse(firstItem.uri)
          val singleJob = EditJob(
            outputUri = job.outputUri,
            trim = firstItem.trim,
            overlays = job.overlays,
            audio = job.audio,
            quality = job.quality,
            playlist = null
          )
          VideoEditor(ctx).edit(
            inputUri = inputUri,
            outputFile = outputFile,
            job = singleJob,
            progressCallback = progressCallback,
            cancelCheck = { cancelRequested },
            completion = completion
          )
        }
      }.start()
    }

    AsyncFunction("cancelEdit") { promise: Promise ->
      cancelRequested = true
      promise.resolve(null)
    }

    AsyncFunction("getVideoInfo") { uri: String, promise: Promise ->
      val ctx = requireNotNull(appContext.reactContext)
      val retriever = MediaMetadataRetriever()
      try {
        retriever.setDataSource(ctx, Uri.parse(uri))
        val durationMs = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLong() ?: 0L
        val rawWidth = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toInt() ?: 0
        val rawHeight = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toInt() ?: 0
        val rotation = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toInt() ?: 0
        // Apply rotation so width/height reflect rendered orientation (matches iOS)
        val (width, height) = if (rotation == 90 || rotation == 270) rawHeight to rawWidth else rawWidth to rawHeight
        val codec = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_CODEC)
        val fileSize = if (uri.startsWith("file://")) File(uri.removePrefix("file://")).length() else 0L

        // Frame rate: MediaExtractor reads the video track's KEY_FRAME_RATE which is set
        // for all encoded videos (CAPTURE_FRAMERATE is only set for camera-captured ones).
        var fps = 0f
        val extractor = MediaExtractor()
        try {
          extractor.setDataSource(ctx, Uri.parse(uri), null)
          for (i in 0 until extractor.trackCount) {
            val format = extractor.getTrackFormat(i)
            val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
            if (mime.startsWith("video/")) {
              if (format.containsKey(MediaFormat.KEY_FRAME_RATE)) {
                fps = try { format.getInteger(MediaFormat.KEY_FRAME_RATE).toFloat() }
                      catch (_: Exception) { format.getFloat(MediaFormat.KEY_FRAME_RATE) }
              }
              break
            }
          }
        } catch (_: Exception) {
          // Fall back to CAPTURE_FRAMERATE (best effort)
          fps = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_CAPTURE_FRAMERATE)?.toFloat() ?: 0f
        } finally {
          extractor.release()
        }

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

    AsyncFunction("cleanTempFiles") { promise: Promise ->
      val ctx = requireNotNull(appContext.reactContext)
      val tempDir = File(ctx.cacheDir, "expo-media-edit")
      var count = 0
      tempDir.listFiles()?.forEach { file ->
        if (file.delete()) count++
      }
      promise.resolve(count)
    }
  }
}

class CancellationException(message: String) : Exception(message)
