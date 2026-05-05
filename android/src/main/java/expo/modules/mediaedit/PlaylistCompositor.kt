package expo.modules.mediaedit

import android.content.Context
import android.graphics.*
import android.media.*
import android.net.Uri
import java.io.File
import java.nio.ByteBuffer

class PlaylistCompositor(private val context: Context) {

  companion object {
    private const val FRAME_RATE = 30
    private const val I_FRAME_INTERVAL = 1
    private const val MIME_TYPE = MediaFormat.MIMETYPE_VIDEO_AVC
    private const val TIMEOUT_US = 10_000L
  }

  data class SourceItem(
    val type: String,
    val file: File?,
    val bitmap: Bitmap?,
    val durationMs: Long,
    val transition: TransitionConfig,
    val tempFile: File?
  )

  data class Timeline(val startMs: Long, val durationMs: Long)

  fun composite(
    playlist: List<PlaylistItemConfig>,
    overlays: List<OverlayItem>,
    audio: AudioMixOptions?,
    quality: String,
    outputFile: File,
    progressCallback: (Float) -> Unit,
    cancelCheck: () -> Boolean,
    completion: (Result<Uri>) -> Unit
  ) {
    try {
      val tempFiles = mutableListOf<File>()
      val sources = mutableListOf<SourceItem>()

      for ((i, item) in playlist.withIndex()) {
        if (cancelCheck()) throw CancellationException("Cancelled during playlist prep")
        progressCallback(0.05f * i / playlist.size)

        when (item) {
          is PlaylistItemConfig.VideoItem -> {
            val uri = Uri.parse(item.uri)
            val trimmed = if (item.trim != null) {
              VideoTrimmer(context).trim(uri, item.trim).also { tempFiles.add(it) }
            } else {
              VideoTrimmer(context).copyToTemp(uri).also { tempFiles.add(it) }
            }
            val retriever = MediaMetadataRetriever()
            retriever.setDataSource(trimmed.absolutePath)
            val dur = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLong() ?: 0L
            retriever.release()
            sources.add(SourceItem("video", trimmed, null, dur, item.transition, tempFile = trimmed))
          }
          is PlaylistItemConfig.ImageItem -> {
            val path = item.uri.removePrefix("file://")
            val bmp = BitmapFactory.decodeFile(path)
              ?: throw IllegalArgumentException("Cannot decode image: ${item.uri}")
            sources.add(SourceItem("image", null, bmp, item.durationMs, item.transition, null))
          }
        }
      }

      progressCallback(0.05f)

      // Determine output dimensions from first item
      var videoWidth = 1080
      var videoHeight = 1920
      val first = sources.first()
      if (first.type == "video" && first.file != null) {
        val r = MediaMetadataRetriever()
        r.setDataSource(first.file.absolutePath)
        val w = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toInt() ?: videoWidth
        val h = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toInt() ?: videoHeight
        val rot = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toInt() ?: 0
        r.release()
        if (rot == 90 || rot == 270) { videoWidth = h; videoHeight = w } else { videoWidth = w; videoHeight = h }
      } else if (first.type == "image") {
        first.bitmap?.let { videoWidth = it.width; videoHeight = it.height }
      }

      // Build timeline: each item's composition start accounting for overlap from fade/slide transitions
      val timelines = mutableListOf<Timeline>()
      var cursor = 0L
      for ((i, src) in sources.withIndex()) {
        val overlapMs = when (val t = src.transition) {
          is TransitionConfig.Fade -> if (i > 0) t.durationMs else 0L
          is TransitionConfig.Slide -> if (i > 0) t.durationMs else 0L
          else -> 0L
        }
        timelines.add(Timeline(startMs = cursor - overlapMs, durationMs = src.durationMs))
        cursor = cursor - overlapMs + src.durationMs
      }
      val totalDurationMs = cursor

      // Encode
      val bitrate = when (quality) { "low" -> 1_000_000; "medium" -> 2_000_000; else -> 4_000_000 }
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
      var videoTrackIndex = -1
      var muxerStarted = false

      val retrievers = sources.map { src ->
        if (src.type == "video" && src.file != null) {
          MediaMetadataRetriever().also { it.setDataSource(src.file.absolutePath) }
        } else null
      }

      val overlayCompositor = OverlayCompositor(context)
      val frameIntervalMs = 1000L / FRAME_RATE
      var frameTimeMs = 0L
      val bufferInfo = MediaCodec.BufferInfo()

      try {
        while (frameTimeMs <= totalDurationMs) {
          if (cancelCheck()) throw CancellationException("Cancelled during playlist encode")

          val bitmap = buildBlendedFrame(frameTimeMs, sources, timelines, retrievers, videoWidth, videoHeight)

          if (bitmap != null) {
            val canvas = Canvas(bitmap)
            overlayCompositor.drawOverlays(canvas, overlays, frameTimeMs, videoWidth, videoHeight)

            val inputIndex = encoder.dequeueInputBuffer(TIMEOUT_US)
            if (inputIndex >= 0) {
              val buf = encoder.getInputBuffer(inputIndex)!!
              val yuv = bitmapToYuv420(bitmap, videoWidth, videoHeight)
              buf.clear(); buf.put(yuv)
              encoder.queueInputBuffer(inputIndex, 0, yuv.size, frameTimeMs * 1000L, 0)
            }
            bitmap.recycle()
          }

          var outputIndex = encoder.dequeueOutputBuffer(bufferInfo, 0)
          while (outputIndex != MediaCodec.INFO_TRY_AGAIN_LATER) {
            if (outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
              videoTrackIndex = muxer.addTrack(encoder.outputFormat)
              muxer.start(); muxerStarted = true
            } else if (outputIndex >= 0 && videoTrackIndex >= 0) {
              val buf = encoder.getOutputBuffer(outputIndex)!!
              if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                muxer.writeSampleData(videoTrackIndex, buf, bufferInfo)
              }
              encoder.releaseOutputBuffer(outputIndex, false)
            }
            outputIndex = encoder.dequeueOutputBuffer(bufferInfo, 0)
          }

          progressCallback(0.05f + (frameTimeMs.toFloat() / totalDurationMs.toFloat()) * 0.85f)
          frameTimeMs += frameIntervalMs
        }

        // Signal end of stream
        val eosIndex = encoder.dequeueInputBuffer(TIMEOUT_US)
        if (eosIndex >= 0) encoder.queueInputBuffer(eosIndex, 0, 0, totalDurationMs * 1000L, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
        var done = false
        while (!done) {
          when (val idx = encoder.dequeueOutputBuffer(bufferInfo, TIMEOUT_US)) {
            MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
              if (!muxerStarted) { videoTrackIndex = muxer.addTrack(encoder.outputFormat); muxer.start(); muxerStarted = true }
            }
            else -> if (idx >= 0) {
              val buf = encoder.getOutputBuffer(idx)!!
              if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0 && videoTrackIndex >= 0) {
                muxer.writeSampleData(videoTrackIndex, buf, bufferInfo)
              }
              encoder.releaseOutputBuffer(idx, false)
              if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) done = true
            }
          }
        }
      } finally {
        retrievers.forEach { it?.release() }
        sources.forEach { it.bitmap?.recycle() }
        encoder.stop(); encoder.release()
        if (muxerStarted) { muxer.stop(); muxer.release() }
      }

      progressCallback(0.9f)

      // Audio mix
      val finalFile = if (audio != null) {
        AudioMixer(context).mix(outputFile, audio).also { tempFiles.add(it) }
      } else outputFile

      if (finalFile != outputFile) finalFile.copyTo(outputFile, overwrite = true)
      tempFiles.forEach { if (it != outputFile) it.delete() }

      progressCallback(1.0f)
      completion(Result.success(Uri.fromFile(outputFile)))
    } catch (e: CancellationException) {
      outputFile.delete()
      completion(Result.failure(e))
    } catch (e: Exception) {
      outputFile.delete()
      completion(Result.failure(e))
    }
  }

  private fun buildBlendedFrame(
    frameTimeMs: Long,
    sources: List<SourceItem>,
    timelines: List<Timeline>,
    retrievers: List<MediaMetadataRetriever?>,
    videoWidth: Int,
    videoHeight: Int
  ): Bitmap? {
    data class ActiveItem(val srcIndex: Int, val localTimeMs: Long, val alpha: Float, val dx: Float = 0f, val dy: Float = 0f)
    val active = mutableListOf<ActiveItem>()

    for (i in sources.indices) {
      val tl = timelines[i]
      val itemEnd = tl.startMs + tl.durationMs
      if (frameTimeMs < tl.startMs || frameTimeMs >= itemEnd) continue

      val localTime = frameTimeMs - tl.startMs
      var alpha = 1.0f
      var dx = 0f
      var dy = 0f

      // Fade-in / slide-in for this item
      when (val t = sources[i].transition) {
        is TransitionConfig.Fade -> {
          if (i > 0) {
            val prevEnd = timelines[i - 1].startMs + timelines[i - 1].durationMs
            if (frameTimeMs < prevEnd) {
              alpha = ((frameTimeMs - tl.startMs).toFloat() / t.durationMs.toFloat()).coerceIn(0f, 1f)
            }
          }
        }
        is TransitionConfig.Slide -> {
          if (i > 0) {
            val prevEnd = timelines[i - 1].startMs + timelines[i - 1].durationMs
            if (frameTimeMs < prevEnd) {
              val progress = ((frameTimeMs - tl.startMs).toFloat() / t.durationMs.toFloat()).coerceIn(0f, 1f)
              when (t.direction) {
                "right" -> dx = videoWidth * (1f - progress)
                "up"    -> dy = videoHeight * (1f - progress)
                "down"  -> dy = -videoHeight * (1f - progress)
                else    -> dx = -videoWidth * (1f - progress)  // "left" default
              }
            }
          }
        }
        is TransitionConfig.FadeToBlack -> {
          val halfMs = t.durationMs / 2
          if (localTime < halfMs) {
            alpha = (localTime.toFloat() / halfMs.toFloat()).coerceIn(0f, 1f)
          }
        }
        else -> {}
      }

      // Fade-out / slide-out driven by next item's transition
      if (i < sources.size - 1) {
        when (val nt = sources[i + 1].transition) {
          is TransitionConfig.FadeToBlack -> {
            val halfMs = nt.durationMs / 2
            val fadeOutStart = itemEnd - halfMs
            if (frameTimeMs >= fadeOutStart) {
              alpha = (1f - (frameTimeMs - fadeOutStart).toFloat() / halfMs.toFloat()).coerceIn(0f, 1f)
            }
          }
          is TransitionConfig.Fade -> {
            val nextStart = timelines[i + 1].startMs
            if (frameTimeMs >= nextStart) {
              alpha = (1f - (frameTimeMs - nextStart).toFloat() / nt.durationMs.toFloat()).coerceIn(0f, 1f)
            }
          }
          is TransitionConfig.Slide -> {
            val nextStart = timelines[i + 1].startMs
            if (frameTimeMs >= nextStart) {
              val progress = ((frameTimeMs - nextStart).toFloat() / nt.durationMs.toFloat()).coerceIn(0f, 1f)
              when (nt.direction) {
                "right" -> dx = -videoWidth * progress
                "up"    -> dy = videoHeight * progress
                "down"  -> dy = -videoHeight * progress
                else    -> dx = -videoWidth * progress  // "left" default: push out to left
              }
            }
          }
          else -> {}
        }
      }

      active.add(ActiveItem(i, localTime, alpha, dx, dy))
    }

    if (active.isEmpty()) return null

    val result = Bitmap.createBitmap(videoWidth, videoHeight, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(result)
    canvas.drawColor(Color.BLACK)

    for (ai in active) {
      val src = sources[ai.srcIndex]
      val frame = when (src.type) {
        "video" -> retrievers[ai.srcIndex]?.getFrameAtTime(
          ai.localTimeMs * 1000L,
          MediaMetadataRetriever.OPTION_CLOSEST_SYNC
        )?.let { bmp ->
          if (bmp.width != videoWidth || bmp.height != videoHeight)
            Bitmap.createScaledBitmap(bmp, videoWidth, videoHeight, true).also { bmp.recycle() }
          else bmp
        }
        "image" -> src.bitmap?.let { bmp ->
          if (bmp.width != videoWidth || bmp.height != videoHeight)
            Bitmap.createScaledBitmap(bmp, videoWidth, videoHeight, false)
          else bmp
        }
        else -> null
      } ?: continue

      val paint = Paint().apply { alpha = (ai.alpha * 255).toInt().coerceIn(0, 255) }
      canvas.save()
      if (ai.dx != 0f || ai.dy != 0f) canvas.translate(ai.dx, ai.dy)
      canvas.drawBitmap(frame, 0f, 0f, paint)
      canvas.restore()
      if (src.type == "video") frame.recycle()
    }

    return result
  }

  private fun bitmapToYuv420(bitmap: Bitmap, width: Int, height: Int): ByteArray {
    val argb = IntArray(width * height)
    bitmap.getPixels(argb, 0, width, 0, 0, width, height)
    val yuv = ByteArray(width * height * 3 / 2)
    val ySize = width * height
    val uvSize = width * height / 4
    var yIndex = 0; var uIndex = ySize; var vIndex = ySize + uvSize
    for (row in 0 until height) {
      for (col in 0 until width) {
        val px = argb[row * width + col]
        val r = (px shr 16) and 0xFF; val g = (px shr 8) and 0xFF; val b = px and 0xFF
        yuv[yIndex++] = (((66 * r + 129 * g + 25 * b + 128) shr 8) + 16).coerceIn(16, 235).toByte()
        if (row % 2 == 0 && col % 2 == 0) {
          yuv[uIndex++] = (((-38 * r - 74 * g + 112 * b + 128) shr 8) + 128).coerceIn(16, 240).toByte()
          yuv[vIndex++] = (((112 * r - 94 * g - 18 * b + 128) shr 8) + 128).coerceIn(16, 240).toByte()
        }
      }
    }
    return yuv
  }
}
