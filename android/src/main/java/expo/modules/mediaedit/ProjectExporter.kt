package expo.modules.mediaedit

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.Composition
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import java.io.File

/**
 * Runs a media3 [Composition] through [Transformer] to an MP4 on
 * disk. Mirrors the iOS ProjectExporter lifecycle: in-flight cancel,
 * periodic progress polling, single completion callback.
 *
 * One ProjectExporter instance ↔ one in-flight export. Reusable
 * after each completion.
 */
@UnstableApi
class ProjectExporter(private val context: Context) {

  private var transformer: Transformer? = null
  private val mainHandler = Handler(Looper.getMainLooper())
  private val progressHolder = ProgressHolder()
  private var progressPoll: Runnable? = null

  fun cancel() {
    mainHandler.post {
      transformer?.cancel()
    }
  }

  fun export(
    composition: Composition,
    outputFile: File,
    quality: String,
    onProgress: (Float) -> Unit,
    completion: (Result<File>) -> Unit,
  ) {
    mainHandler.post {
      val t = Transformer.Builder(context)
        .setVideoMimeType(MimeTypes.VIDEO_H264)
        .setAudioMimeType(MimeTypes.AUDIO_AAC)
        .addListener(object : Transformer.Listener {
          override fun onCompleted(composition: Composition, exportResult: ExportResult) {
            stopProgressPolling()
            transformer = null
            onProgress(1f)
            completion(Result.success(outputFile))
          }
          override fun onError(composition: Composition, exportResult: ExportResult, exportException: ExportException) {
            stopProgressPolling()
            transformer = null
            try { outputFile.delete() } catch (_: Exception) {}
            val msg = exportException.message ?: "Unknown export error"
            val isCancel = msg.contains("cancel", ignoreCase = true)
            completion(Result.failure(
              if (isCancel) CancellationException("Export was cancelled")
              else ExportFailed(msg)
            ))
          }
        })
        .build()

      this.transformer = t
      try { outputFile.delete() } catch (_: Exception) {}
      t.start(composition, outputFile.absolutePath)
      startProgressPolling(t, onProgress)
    }
  }

  private fun startProgressPolling(t: Transformer, onProgress: (Float) -> Unit) {
    val r = object : Runnable {
      override fun run() {
        val current = transformer ?: return
        val state = current.getProgress(progressHolder)
        if (state == Transformer.PROGRESS_STATE_AVAILABLE) {
          onProgress(progressHolder.progress / 100f)
        }
        mainHandler.postDelayed(this, 200)
      }
    }
    progressPoll = r
    mainHandler.postDelayed(r, 200)
  }

  private fun stopProgressPolling() {
    progressPoll?.let { mainHandler.removeCallbacks(it) }
    progressPoll = null
  }
}

class ExportFailed(message: String) : Exception(message)
