package expo.modules.mediaedit

import android.content.Context
import android.graphics.*
import android.media.*
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import java.io.File
import java.nio.ByteBuffer

class OverlayCompositor(private val context: Context) {

  companion object {
    private const val FRAME_RATE = 30
    private const val I_FRAME_INTERVAL = 1
    private const val MIME_TYPE = MediaFormat.MIMETYPE_VIDEO_AVC
    private const val TIMEOUT_US = 10_000L

    private fun bitrateForQuality(quality: String): Int = when (quality) {
      "low"    -> 1_000_000
      "medium" -> 2_000_000
      else     -> 4_000_000
    }
  }

  fun composite(
    inputFile: File,
    overlays: List<OverlayItem>,
    quality: String = "high",
    progressCallback: (Float) -> Unit = {},
    cancelCheck: () -> Boolean = { false }
  ): File {
    val retriever = MediaMetadataRetriever()
    retriever.setDataSource(inputFile.absolutePath)

    var videoWidth = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toInt() ?: 1080
    var videoHeight = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toInt() ?: 1920
    val durationMs = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLong() ?: 0L
    val rotation = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toInt() ?: 0
    retriever.release()

    // Swap dimensions for 90/270 degree rotated videos
    if (rotation == 90 || rotation == 270) {
      val tmp = videoWidth; videoWidth = videoHeight; videoHeight = tmp
    }

    val outputFile = createTempFile(context, "overlay", ".mp4")

    encodeWithOverlays(
      inputFile = inputFile,
      outputFile = outputFile,
      videoWidth = videoWidth,
      videoHeight = videoHeight,
      durationMs = durationMs,
      rotation = rotation,
      overlays = overlays,
      bitrate = bitrateForQuality(quality),
      progressCallback = progressCallback,
      cancelCheck = cancelCheck
    )

    return outputFile
  }

  private fun encodeWithOverlays(
    inputFile: File,
    outputFile: File,
    videoWidth: Int,
    videoHeight: Int,
    durationMs: Long,
    rotation: Int,
    overlays: List<OverlayItem>,
    bitrate: Int,
    progressCallback: (Float) -> Unit,
    cancelCheck: () -> Boolean
  ) {
    val encoderFormat = MediaFormat.createVideoFormat(MIME_TYPE, videoWidth, videoHeight).apply {
      setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
      setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
      setInteger(MediaFormat.KEY_FRAME_RATE, FRAME_RATE)
      setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, I_FRAME_INTERVAL)
    }

    val encoder = MediaCodec.createEncoderByType(MIME_TYPE)
    encoder.configure(encoderFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
    encoder.start()

    val muxer = MediaMuxer(outputFile.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
    if (rotation != 0) muxer.setOrientationHint(rotation)

    var videoTrackIndex = -1
    var muxerStarted = false

    val audioExtractor = MediaExtractor()
    audioExtractor.setDataSource(inputFile.absolutePath)
    var srcAudioTrackIndex = -1
    var muxerAudioTrackIndex = -1

    for (i in 0 until audioExtractor.trackCount) {
      val fmt = audioExtractor.getTrackFormat(i)
      val mime = fmt.getString(MediaFormat.KEY_MIME) ?: continue
      if (mime.startsWith("audio/")) {
        audioExtractor.selectTrack(i)
        srcAudioTrackIndex = i
        break
      }
    }

    val frameRetriever = MediaMetadataRetriever()
    frameRetriever.setDataSource(inputFile.absolutePath)

    val frameIntervalMs = 1000L / FRAME_RATE
    var frameTimeMs = 0L
    val bufferInfo = MediaCodec.BufferInfo()
    val totalFrames = (durationMs / frameIntervalMs).coerceAtLeast(1)

    try {
      while (frameTimeMs <= durationMs) {
        if (cancelCheck()) throw CancellationException("Cancelled during overlay encoding")

        val bitmap = frameRetriever.getFrameAtTime(
          frameTimeMs * 1000L,
          MediaMetadataRetriever.OPTION_CLOSEST_SYNC
        )

        if (bitmap != null) {
          val mutable = bitmap.copy(Bitmap.Config.ARGB_8888, true)
          bitmap.recycle()
          val canvas = Canvas(mutable)

          if (rotation != 0) {
            val matrix = Matrix()
            matrix.postRotate(rotation.toFloat(), mutable.width / 2f, mutable.height / 2f)
            // rotation already handled by dimension swap + setOrientationHint
          }

          drawOverlays(canvas, overlays, frameTimeMs, mutable.width, mutable.height)

          val scaled = if (mutable.width != videoWidth || mutable.height != videoHeight) {
            Bitmap.createScaledBitmap(mutable, videoWidth, videoHeight, true).also { mutable.recycle() }
          } else {
            mutable
          }

          val inputIndex = encoder.dequeueInputBuffer(TIMEOUT_US)
          if (inputIndex >= 0) {
            val inputBuffer = encoder.getInputBuffer(inputIndex)!!
            val yuvBytes = bitmapToYuv420(scaled, videoWidth, videoHeight)
            inputBuffer.clear()
            inputBuffer.put(yuvBytes)
            encoder.queueInputBuffer(inputIndex, 0, yuvBytes.size, frameTimeMs * 1000L, 0)
          }
          scaled.recycle()
        }

        var outputIndex = encoder.dequeueOutputBuffer(bufferInfo, 0)
        while (outputIndex != MediaCodec.INFO_TRY_AGAIN_LATER) {
          if (outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
            videoTrackIndex = muxer.addTrack(encoder.outputFormat)
            if (!muxerStarted) {
              if (srcAudioTrackIndex >= 0) {
                muxerAudioTrackIndex = muxer.addTrack(audioExtractor.getTrackFormat(srcAudioTrackIndex))
              }
              muxer.start()
              muxerStarted = true
            }
          } else if (outputIndex >= 0) {
            val buffer = encoder.getOutputBuffer(outputIndex)!!
            if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0 && videoTrackIndex >= 0) {
              muxer.writeSampleData(videoTrackIndex, buffer, bufferInfo)
            }
            encoder.releaseOutputBuffer(outputIndex, false)
          }
          outputIndex = encoder.dequeueOutputBuffer(bufferInfo, 0)
        }

        progressCallback(frameTimeMs.toFloat() / durationMs.toFloat())
        frameTimeMs += frameIntervalMs
      }

      frameRetriever.release()

      val eosIndex = encoder.dequeueInputBuffer(TIMEOUT_US)
      if (eosIndex >= 0) {
        encoder.queueInputBuffer(eosIndex, 0, 0, durationMs * 1000L, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
      }

      var done = false
      while (!done) {
        val outputIndex = encoder.dequeueOutputBuffer(bufferInfo, TIMEOUT_US)
        when {
          outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
            if (!muxerStarted) {
              videoTrackIndex = muxer.addTrack(encoder.outputFormat)
              if (srcAudioTrackIndex >= 0) {
                muxerAudioTrackIndex = muxer.addTrack(audioExtractor.getTrackFormat(srcAudioTrackIndex))
              }
              muxer.start()
              muxerStarted = true
            }
          }
          outputIndex >= 0 -> {
            val buffer = encoder.getOutputBuffer(outputIndex)!!
            if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0 && videoTrackIndex >= 0) {
              muxer.writeSampleData(videoTrackIndex, buffer, bufferInfo)
            }
            encoder.releaseOutputBuffer(outputIndex, false)
            if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) done = true
          }
        }
      }

      if (muxerStarted && muxerAudioTrackIndex >= 0) {
        val audioBuffer = ByteBuffer.allocate(512 * 1024)
        val audioInfo = MediaCodec.BufferInfo()
        while (true) {
          audioInfo.size = audioExtractor.readSampleData(audioBuffer, 0)
          if (audioInfo.size < 0) break
          audioInfo.presentationTimeUs = audioExtractor.sampleTime
          audioInfo.flags = audioExtractor.sampleFlags
          audioInfo.offset = 0
          muxer.writeSampleData(muxerAudioTrackIndex, audioBuffer, audioInfo)
          audioExtractor.advance()
        }
      }
    } finally {
      audioExtractor.release()
      encoder.stop()
      encoder.release()
      if (muxerStarted) {
        muxer.stop()
        muxer.release()
      }
    }
  }

  private fun bitmapToYuv420(bitmap: Bitmap, width: Int, height: Int): ByteArray {
    val argb = IntArray(width * height)
    bitmap.getPixels(argb, 0, width, 0, 0, width, height)

    val yuv = ByteArray(width * height * 3 / 2)
    val ySize = width * height
    val uvSize = width * height / 4

    var yIndex = 0
    var uIndex = ySize
    var vIndex = ySize + uvSize

    for (row in 0 until height) {
      for (col in 0 until width) {
        val pixel = argb[row * width + col]
        val r = (pixel shr 16) and 0xFF
        val g = (pixel shr 8) and 0xFF
        val b = pixel and 0xFF
        val y = ((66 * r + 129 * g + 25 * b + 128) shr 8) + 16
        yuv[yIndex++] = y.coerceIn(16, 235).toByte()
        if (row % 2 == 0 && col % 2 == 0) {
          val u = ((-38 * r - 74 * g + 112 * b + 128) shr 8) + 128
          val v = ((112 * r - 94 * g - 18 * b + 128) shr 8) + 128
          yuv[uIndex++] = u.coerceIn(16, 240).toByte()
          yuv[vIndex++] = v.coerceIn(16, 240).toByte()
        }
      }
    }
    return yuv
  }

  internal fun drawOverlays(canvas: Canvas, overlays: List<OverlayItem>, frameTimeMs: Long, videoWidth: Int, videoHeight: Int) {
    for (overlay in overlays) {
      when (overlay) {
        is OverlayItem.Text -> {
          val opts = overlay.opts
          if (frameTimeMs < (opts.startMs ?: 0L) || frameTimeMs > (opts.endMs ?: Long.MAX_VALUE)) continue
          val textPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            try { color = Color.parseColor(opts.color) } catch (_: Exception) { color = Color.WHITE }
            textSize = opts.fontSize * (videoHeight / 1080f)
            typeface = if (opts.fontWeight == "bold") Typeface.DEFAULT_BOLD else Typeface.DEFAULT
          }
          val maxWidth = (videoWidth * 0.9f).toInt()
          val layout = StaticLayout.Builder
            .obtain(opts.content, 0, opts.content.length, textPaint, maxWidth)
            .setAlignment(Layout.Alignment.ALIGN_NORMAL)
            .build()
          val x = opts.x * videoWidth
          val y = opts.y * videoHeight
          canvas.save()
          canvas.translate(x, y)
          if (opts.rotation != 0f) canvas.rotate(opts.rotation, layout.width / 2f, layout.height / 2f)
          opts.backgroundColor?.let { bgColorStr ->
            val bgPaint = Paint().apply {
              try { color = Color.parseColor(bgColorStr) } catch (_: Exception) { color = Color.TRANSPARENT }
            }
            val pad = 8f
            canvas.drawRect(-pad, -pad, layout.width + pad, layout.height + pad, bgPaint)
          }
          layout.draw(canvas)
          canvas.restore()
        }
        is OverlayItem.Image -> {
          val opts = overlay.opts
          if (frameTimeMs < (opts.startMs ?: 0L) || frameTimeMs > (opts.endMs ?: Long.MAX_VALUE)) continue
          val filePath = opts.uri.removePrefix("file://")
          val bitmap = BitmapFactory.decodeFile(filePath) ?: continue
          val dst = RectF(opts.x * videoWidth, opts.y * videoHeight, (opts.x + opts.width) * videoWidth, (opts.y + opts.height) * videoHeight)
          canvas.drawBitmap(bitmap, null, dst, Paint().apply { alpha = (opts.opacity * 255).toInt() })
          bitmap.recycle()
        }
      }
    }
  }
}
