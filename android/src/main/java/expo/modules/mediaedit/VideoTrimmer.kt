package expo.modules.mediaedit

import android.content.Context
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaMuxer
import android.net.Uri
import java.io.File
import java.nio.ByteBuffer

class VideoTrimmer(private val context: Context) {

  fun trim(inputUri: Uri, trim: TrimOptions): File {
    val outputFile = createTempFile(context, "trim", ".mp4")

    val extractor = MediaExtractor()
    extractor.setDataSource(context, inputUri, null)

    val muxer = MediaMuxer(outputFile.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)

    val trackMap = mutableMapOf<Int, Int>()
    for (i in 0 until extractor.trackCount) {
      val format = extractor.getTrackFormat(i)
      val mime = format.getString("mime") ?: continue
      if (mime.startsWith("video/") || mime.startsWith("audio/")) {
        extractor.selectTrack(i)
        trackMap[i] = muxer.addTrack(format)
      }
    }

    muxer.start()

    val startUs = trim.startMs * 1000L
    val endUs = trim.endMs * 1000L
    extractor.seekTo(startUs, MediaExtractor.SEEK_TO_CLOSEST_SYNC)

    val buffer = ByteBuffer.allocate(1024 * 1024)
    val bufferInfo = MediaCodec.BufferInfo()

    while (true) {
      val trackIndex = extractor.sampleTrackIndex
      if (trackIndex < 0) break

      val sampleTimeUs = extractor.sampleTime
      if (sampleTimeUs > endUs) break

      val muxerTrack = trackMap[trackIndex]
      if (muxerTrack != null) {
        bufferInfo.offset = 0
        bufferInfo.size = extractor.readSampleData(buffer, 0)
        bufferInfo.presentationTimeUs = sampleTimeUs - startUs
        bufferInfo.flags = extractor.sampleFlags

        if (bufferInfo.size >= 0) {
          muxer.writeSampleData(muxerTrack, buffer, bufferInfo)
        }
      }
      extractor.advance()
    }

    muxer.stop()
    muxer.release()
    extractor.release()

    return outputFile
  }

  fun copyToTemp(inputUri: Uri): File {
    val outputFile = createTempFile(context, "copy", ".mp4")
    context.contentResolver.openInputStream(inputUri)?.use { input ->
      outputFile.outputStream().use { output ->
        input.copyTo(output)
      }
    }
    return outputFile
  }
}
