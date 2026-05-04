package expo.modules.mediaedit

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

    AsyncFunction("editVideo") { inputUri: String, jobMap: Map<String, Any?>, promise: Promise ->
      val ctx = requireNotNull(appContext.reactContext) { "React context not available" }
      val job = EditJob.fromMap(jobMap)
      val parsedInputUri = Uri.parse(inputUri)
      cancelRequested = false

      val outputFile = if (job.outputUri != null) {
        val path = Uri.parse(job.outputUri).path
          ?: throw IllegalArgumentException("outputUri path is null")
        File(path)
      } else {
        createTempFile(ctx, "output", ".mp4")
      }

      Thread {
        VideoEditor(ctx).edit(
          inputUri = parsedInputUri,
          outputFile = outputFile,
          job = job,
          progressCallback = { progress ->
            val bundle = Bundle().apply { putDouble("progress", progress.toDouble()) }
            sendEvent("onProgress", bundle)
          },
          cancelCheck = { cancelRequested },
          completion = { result ->
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
        )
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
        val width = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toInt() ?: 0
        val height = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toInt() ?: 0
        val fps = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_CAPTURE_FRAMERATE)?.toFloat() ?: 0f
        val codec = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_CODEC)
        val fileSize = if (uri.startsWith("file://")) File(uri.removePrefix("file://")).length() else 0L
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
