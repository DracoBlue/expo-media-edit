package expo.modules.mediaedit

import android.content.Context
import android.media.*
import android.net.Uri
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.ShortBuffer

class AudioMixer(private val context: Context) {

  fun mix(inputFile: File, audioOpts: AudioMixOptions): File {
    val outputFile = createTempFile(context, "audiomix", ".mp4")

    val retriever = MediaMetadataRetriever()
    retriever.setDataSource(inputFile.absolutePath)
    val durationMs = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLong() ?: 0L
    retriever.release()

    val videoExtractor = MediaExtractor().also { it.setDataSource(inputFile.absolutePath) }
    val origAudioExtractor = MediaExtractor().also { it.setDataSource(inputFile.absolutePath) }

    val musicExtractor = MediaExtractor()
    val musicAvailable = try {
      musicExtractor.setDataSource(context, Uri.parse(audioOpts.uri), null)
      true
    } catch (e: Exception) {
      false
    }

    if (!musicAvailable) {
      videoExtractor.release(); origAudioExtractor.release(); musicExtractor.release()
      inputFile.copyTo(outputFile, overwrite = true)
      return outputFile
    }

    val muxer = MediaMuxer(outputFile.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
    val endUs = durationMs * 1000L
    val musicStartUs = audioOpts.startMs * 1000L
    val buffer = ByteBuffer.allocate(1024 * 1024)
    val bufferInfo = MediaCodec.BufferInfo()

    // Add video track
    var videoSrcTrack = -1; var muxerVideoTrack = -1
    for (i in 0 until videoExtractor.trackCount) {
      val fmt = videoExtractor.getTrackFormat(i)
      if (fmt.getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true) {
        videoExtractor.selectTrack(i); videoSrcTrack = i; muxerVideoTrack = muxer.addTrack(fmt); break
      }
    }

    // Find original audio format
    var origAudioFmt: MediaFormat? = null
    for (i in 0 until origAudioExtractor.trackCount) {
      val fmt = origAudioExtractor.getTrackFormat(i)
      if (fmt.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
        origAudioExtractor.selectTrack(i); origAudioFmt = fmt; break
      }
    }

    // Find music audio format
    var musicFmt: MediaFormat? = null
    for (i in 0 until musicExtractor.trackCount) {
      val fmt = musicExtractor.getTrackFormat(i)
      if (fmt.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
        musicExtractor.selectTrack(i); musicFmt = fmt; break
      }
    }

    // Decide which audio tracks to include
    val includeOrig = audioOpts.originalVolume > 0f && origAudioFmt != null
    val includeMusic = audioOpts.volume > 0f && musicFmt != null

    // For volume == 1.0, stream copy. Otherwise PCM scale.
    val origStreamCopy = includeOrig && (audioOpts.originalVolume == 1f || audioOpts.originalVolume == 0f)
    val musicStreamCopy = includeMusic && (audioOpts.volume == 1f)

    var muxerOrigAudioTrack = -1
    var muxerMusicTrack = -1

    if (includeOrig && origStreamCopy) muxerOrigAudioTrack = muxer.addTrack(origAudioFmt!!)
    if (includeOrig && !origStreamCopy) {
      // Encode PCM → AAC output format
      val outFmt = buildAacFormat(origAudioFmt!!)
      muxerOrigAudioTrack = muxer.addTrack(outFmt)
    }
    if (includeMusic && musicStreamCopy) muxerMusicTrack = muxer.addTrack(musicFmt!!)
    if (includeMusic && !musicStreamCopy) {
      val outFmt = buildAacFormat(musicFmt!!)
      muxerMusicTrack = muxer.addTrack(outFmt)
    }

    muxer.start()

    // Copy video
    if (videoSrcTrack >= 0) {
      while (true) {
        bufferInfo.size = videoExtractor.readSampleData(buffer, 0)
        if (bufferInfo.size < 0) break
        bufferInfo.presentationTimeUs = videoExtractor.sampleTime
        bufferInfo.flags = videoExtractor.sampleFlags; bufferInfo.offset = 0
        if (bufferInfo.presentationTimeUs <= endUs) muxer.writeSampleData(muxerVideoTrack, buffer, bufferInfo)
        videoExtractor.advance()
      }
    }

    // Original audio
    if (includeOrig) {
      if (origStreamCopy) {
        while (true) {
          bufferInfo.size = origAudioExtractor.readSampleData(buffer, 0)
          if (bufferInfo.size < 0) break
          bufferInfo.presentationTimeUs = origAudioExtractor.sampleTime
          bufferInfo.flags = origAudioExtractor.sampleFlags; bufferInfo.offset = 0
          if (bufferInfo.presentationTimeUs <= endUs) muxer.writeSampleData(muxerOrigAudioTrack, buffer, bufferInfo)
          origAudioExtractor.advance()
        }
      } else {
        encodeAudioWithVolume(origAudioExtractor, origAudioFmt!!, audioOpts.originalVolume, endUs, muxer, muxerOrigAudioTrack)
      }
    }

    // Music audio
    if (includeMusic) {
      if (musicStreamCopy) {
        while (true) {
          bufferInfo.size = musicExtractor.readSampleData(buffer, 0)
          if (bufferInfo.size < 0) break
          val pts = musicExtractor.sampleTime + musicStartUs
          bufferInfo.presentationTimeUs = pts; bufferInfo.flags = musicExtractor.sampleFlags; bufferInfo.offset = 0
          if (!audioOpts.trimToVideo || pts <= endUs) muxer.writeSampleData(muxerMusicTrack, buffer, bufferInfo)
          else break
          musicExtractor.advance()
        }
      } else {
        encodeAudioWithVolume(musicExtractor, musicFmt!!, audioOpts.volume, if (audioOpts.trimToVideo) endUs - musicStartUs else Long.MAX_VALUE, muxer, muxerMusicTrack, musicStartUs)
      }
    }

    videoExtractor.release(); origAudioExtractor.release(); musicExtractor.release()
    muxer.stop(); muxer.release()

    return outputFile
  }

  private fun buildAacFormat(inputFmt: MediaFormat): MediaFormat {
    val sampleRate = inputFmt.getInteger(MediaFormat.KEY_SAMPLE_RATE)
    val channelCount = inputFmt.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
    return MediaFormat.createAudioFormat("audio/mp4a-latm", sampleRate, channelCount).apply {
      setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
      setInteger(MediaFormat.KEY_BIT_RATE, 128_000)
    }
  }

  private fun encodeAudioWithVolume(
    extractor: MediaExtractor,
    inputFmt: MediaFormat,
    volume: Float,
    maxPtsUs: Long,
    muxer: MediaMuxer,
    muxerTrack: Int,
    ptsOffsetUs: Long = 0L
  ) {
    val mime = inputFmt.getString(MediaFormat.KEY_MIME) ?: return
    val sampleRate = inputFmt.getInteger(MediaFormat.KEY_SAMPLE_RATE)
    val channelCount = inputFmt.getInteger(MediaFormat.KEY_CHANNEL_COUNT)

    val decoder = MediaCodec.createDecoderByType(mime)
    decoder.configure(inputFmt, null, null, 0)
    decoder.start()

    val encoderFmt = buildAacFormat(inputFmt)
    val encoder = MediaCodec.createEncoderByType("audio/mp4a-latm")
    encoder.configure(encoderFmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
    encoder.start()

    val bufInfo = MediaCodec.BufferInfo()
    val timeoutUs = 10_000L
    var inputDone = false
    var decoderDone = false
    var encoderDone = false

    val pcmQueue = ArrayDeque<Pair<ByteBuffer, MediaCodec.BufferInfo>>()

    while (!encoderDone) {
      // Feed decoder
      if (!inputDone) {
        val idx = decoder.dequeueInputBuffer(timeoutUs)
        if (idx >= 0) {
          val buf = decoder.getInputBuffer(idx)!!
          val size = extractor.readSampleData(buf, 0)
          if (size < 0 || extractor.sampleTime > maxPtsUs) {
            decoder.queueInputBuffer(idx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
            inputDone = true
          } else {
            decoder.queueInputBuffer(idx, 0, size, extractor.sampleTime, extractor.sampleFlags)
            extractor.advance()
          }
        }
      }

      // Drain decoder → PCM queue
      if (!decoderDone) {
        val idx = decoder.dequeueOutputBuffer(bufInfo, timeoutUs)
        if (idx >= 0) {
          val outBuf = decoder.getOutputBuffer(idx)!!
          if (bufInfo.size > 0) {
            val copy = ByteBuffer.allocate(bufInfo.size)
            copy.put(outBuf)
            copy.flip()
            // Scale PCM (16-bit signed)
            if (volume != 1f) {
              val shorts = copy.asShortBuffer()
              val scaled = ShortBuffer.allocate(shorts.limit())
              while (shorts.hasRemaining()) {
                val s = shorts.get()
                scaled.put((s * volume).toInt().coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort())
              }
              scaled.flip()
              val result = ByteBuffer.allocate(scaled.limit() * 2).order(ByteOrder.nativeOrder())
              result.asShortBuffer().put(scaled)
              result.rewind()
              val scaledInfo = MediaCodec.BufferInfo().apply {
                this.offset = 0; this.size = result.limit(); this.presentationTimeUs = bufInfo.presentationTimeUs; this.flags = bufInfo.flags
              }
              pcmQueue.addLast(Pair(result, scaledInfo))
            } else {
              val copyInfo = MediaCodec.BufferInfo().apply {
                this.offset = 0; this.size = copy.limit(); this.presentationTimeUs = bufInfo.presentationTimeUs; this.flags = bufInfo.flags
              }
              pcmQueue.addLast(Pair(copy, copyInfo))
            }
          }
          if (bufInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) decoderDone = true
          decoder.releaseOutputBuffer(idx, false)
        }
      }

      // Feed encoder from PCM queue
      while (pcmQueue.isNotEmpty()) {
        val encIdx = encoder.dequeueInputBuffer(0)
        if (encIdx < 0) break
        val (pcmBuf, pcmInfo) = pcmQueue.removeFirst()
        val encBuf = encoder.getInputBuffer(encIdx)!!
        encBuf.clear()
        encBuf.put(pcmBuf)
        encoder.queueInputBuffer(encIdx, 0, pcmInfo.size, pcmInfo.presentationTimeUs, if (decoderDone && pcmQueue.isEmpty()) MediaCodec.BUFFER_FLAG_END_OF_STREAM else 0)
      }

      // Drain encoder → muxer
      var encIdx = encoder.dequeueOutputBuffer(bufInfo, timeoutUs)
      while (encIdx >= 0 || encIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
        if (encIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
          // format already added
        } else if (encIdx >= 0) {
          val encBuf = encoder.getOutputBuffer(encIdx)!!
          if (bufInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0 && bufInfo.size > 0) {
            bufInfo.presentationTimeUs += ptsOffsetUs
            muxer.writeSampleData(muxerTrack, encBuf, bufInfo)
          }
          encoder.releaseOutputBuffer(encIdx, false)
          if (bufInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) encoderDone = true
        }
        if (encoderDone) break
        encIdx = encoder.dequeueOutputBuffer(bufInfo, 0)
      }
    }

    decoder.stop(); decoder.release()
    encoder.stop(); encoder.release()
  }
}
