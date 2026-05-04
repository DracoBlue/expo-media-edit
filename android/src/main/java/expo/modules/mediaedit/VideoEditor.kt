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
    completion: (Result<Uri>) -> Unit
  ) {
    try {
      // Step 1: Trim (stream copy, no re-encode)
      val trimmedFile = if (job.trim != null) {
        VideoTrimmer(context).trim(inputUri, job.trim)
      } else {
        VideoTrimmer(context).copyToTemp(inputUri)
      }

      // Step 2: Burn-in overlays (re-encode video track)
      val overlaidFile = if (job.overlays.isNotEmpty()) {
        OverlayCompositor(context).composite(trimmedFile, job.overlays).also {
          if (it != trimmedFile) trimmedFile.delete()
        }
      } else {
        trimmedFile
      }

      // Step 3: Mix audio
      val finalFile = if (job.audio != null) {
        AudioMixer(context).mix(overlaidFile, job.audio).also {
          if (it != overlaidFile) overlaidFile.delete()
        }
      } else {
        overlaidFile
      }

      // Step 4: Move to output
      finalFile.copyTo(outputFile, overwrite = true)
      if (finalFile != outputFile) finalFile.delete()

      completion(Result.success(Uri.fromFile(outputFile)))
    } catch (e: Exception) {
      completion(Result.failure(e))
    }
  }
}
