package expo.modules.mediaedit

import android.content.Context
import android.net.Uri
import java.io.File

class VideoEditor(private val context: Context) {

  fun edit(
    inputUri: Uri,
    outputFile: File,
    job: EditJob,
    progressCallback: (Float) -> Unit,
    cancelCheck: () -> Boolean,
    completion: (Result<Uri>) -> Unit
  ) {
    val tempFiles = mutableListOf<File>()
    try {
      if (cancelCheck()) throw CancellationException("Cancelled before start")

      val trimmedFile = if (job.trim != null) {
        VideoTrimmer(context).trim(inputUri, job.trim).also { tempFiles.add(it) }
      } else {
        VideoTrimmer(context).copyToTemp(inputUri).also { tempFiles.add(it) }
      }

      progressCallback(0.1f)
      if (cancelCheck()) throw CancellationException("Cancelled after trim")

      val overlaidFile = if (job.overlays.isNotEmpty()) {
        OverlayCompositor(context).composite(
          inputFile = trimmedFile,
          overlays = job.overlays,
          quality = job.quality,
          progressCallback = { p -> progressCallback(0.1f + p * 0.75f) },
          cancelCheck = cancelCheck
        ).also { tempFiles.add(it) }
      } else {
        progressCallback(0.85f)
        trimmedFile
      }

      if (cancelCheck()) throw CancellationException("Cancelled after overlay")

      val finalFile = if (job.audio != null) {
        AudioMixer(context).mix(overlaidFile, job.audio).also { tempFiles.add(it) }
      } else {
        overlaidFile
      }

      progressCallback(0.95f)

      finalFile.copyTo(outputFile, overwrite = true)
      tempFiles.forEach { if (it != outputFile) it.delete() }

      completion(Result.success(Uri.fromFile(outputFile)))
    } catch (e: CancellationException) {
      tempFiles.forEach { it.delete() }
      outputFile.delete()
      completion(Result.failure(e))
    } catch (e: Exception) {
      tempFiles.forEach { it.delete() }
      outputFile.delete()
      completion(Result.failure(e))
    }
  }
}
