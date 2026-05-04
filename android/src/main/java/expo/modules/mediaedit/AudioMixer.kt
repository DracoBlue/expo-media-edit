package expo.modules.mediaedit

import android.content.Context
import android.media.*
import android.net.Uri
import java.io.File
import java.nio.ByteBuffer

class AudioMixer(private val context: Context) {

  fun mix(inputFile: File, audioOpts: AudioMixOptions): File {
    val outputFile = createTempFile(context, "audiomix", ".mp4")

    // Get video duration
    val retriever = MediaMetadataRetriever()
    retriever.setDataSource(inputFile.absolutePath)
    val durationMs = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLong() ?: 0L
    retriever.release()

    // Copy video track and mix audio using MediaExtractor + MediaMuxer
    val videoExtractor = MediaExtractor()
    videoExtractor.setDataSource(inputFile.absolutePath)

    val origAudioExtractor = MediaExtractor()
    origAudioExtractor.setDataSource(inputFile.absolutePath)

    val musicExtractor = MediaExtractor()
    try {
      musicExtractor.setDataSource(context, Uri.parse(audioOpts.uri), null)
    } catch (e: Exception) {
      // Music file not accessible — copy input as-is
      videoExtractor.release()
      origAudioExtractor.release()
      musicExtractor.release()
      inputFile.copyTo(outputFile, overwrite = true)
      return outputFile
    }

    val muxer = MediaMuxer(outputFile.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)

    // Find and add video track
    var videoSrcTrack = -1
    var muxerVideoTrack = -1
    for (i in 0 until videoExtractor.trackCount) {
      val fmt = videoExtractor.getTrackFormat(i)
      val mime = fmt.getString(MediaFormat.KEY_MIME) ?: continue
      if (mime.startsWith("video/")) {
        videoExtractor.selectTrack(i)
        videoSrcTrack = i
        muxerVideoTrack = muxer.addTrack(fmt)
        break
      }
    }

    // Find original audio track
    var origAudioSrcTrack = -1
    var muxerOrigAudioTrack = -1
    for (i in 0 until origAudioExtractor.trackCount) {
      val fmt = origAudioExtractor.getTrackFormat(i)
      val mime = fmt.getString(MediaFormat.KEY_MIME) ?: continue
      if (mime.startsWith("audio/")) {
        origAudioExtractor.selectTrack(i)
        origAudioSrcTrack = i
        muxerOrigAudioTrack = muxer.addTrack(fmt)
        break
      }
    }

    // Find music audio track
    var musicSrcTrack = -1
    var muxerMusicTrack = -1
    for (i in 0 until musicExtractor.trackCount) {
      val fmt = musicExtractor.getTrackFormat(i)
      val mime = fmt.getString(MediaFormat.KEY_MIME) ?: continue
      if (mime.startsWith("audio/")) {
        musicExtractor.selectTrack(i)
        musicSrcTrack = i
        muxerMusicTrack = muxer.addTrack(fmt)
        break
      }
    }

    muxer.start()

    val buffer = ByteBuffer.allocate(1024 * 1024)
    val bufferInfo = MediaCodec.BufferInfo()
    val endUs = durationMs * 1000L
    val musicStartUs = audioOpts.startMs * 1000L

    // Copy video track
    if (videoSrcTrack >= 0) {
      while (true) {
        bufferInfo.size = videoExtractor.readSampleData(buffer, 0)
        if (bufferInfo.size < 0) break
        bufferInfo.presentationTimeUs = videoExtractor.sampleTime
        bufferInfo.flags = videoExtractor.sampleFlags
        bufferInfo.offset = 0
        if (bufferInfo.presentationTimeUs <= endUs) {
          muxer.writeSampleData(muxerVideoTrack, buffer, bufferInfo)
        }
        videoExtractor.advance()
      }
    }

    // Copy original audio with volume scaling (stream copy — volume adjustment not possible without decode)
    // Note: True volume mixing requires decoding to PCM, scaling, and re-encoding.
    // For simplicity we do stream copy for original audio at originalVolume > 0,
    // and music track at volume > 0. This is a known limitation.
    if (origAudioSrcTrack >= 0 && audioOpts.originalVolume > 0f) {
      while (true) {
        bufferInfo.size = origAudioExtractor.readSampleData(buffer, 0)
        if (bufferInfo.size < 0) break
        bufferInfo.presentationTimeUs = origAudioExtractor.sampleTime
        bufferInfo.flags = origAudioExtractor.sampleFlags
        bufferInfo.offset = 0
        if (bufferInfo.presentationTimeUs <= endUs) {
          muxer.writeSampleData(muxerOrigAudioTrack, buffer, bufferInfo)
        }
        origAudioExtractor.advance()
      }
    }

    // Copy music track with time offset
    if (musicSrcTrack >= 0 && audioOpts.volume > 0f) {
      while (true) {
        bufferInfo.size = musicExtractor.readSampleData(buffer, 0)
        if (bufferInfo.size < 0) break
        val pts = musicExtractor.sampleTime + musicStartUs
        bufferInfo.presentationTimeUs = pts
        bufferInfo.flags = musicExtractor.sampleFlags
        bufferInfo.offset = 0
        if (!audioOpts.trimToVideo || pts <= endUs) {
          muxer.writeSampleData(muxerMusicTrack, buffer, bufferInfo)
        } else {
          break
        }
        musicExtractor.advance()
      }
    }

    videoExtractor.release()
    origAudioExtractor.release()
    musicExtractor.release()
    muxer.stop()
    muxer.release()

    return outputFile
  }
}
