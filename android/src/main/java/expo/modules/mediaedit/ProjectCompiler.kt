package expo.modules.mediaedit

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.Uri
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BitmapOverlay
import androidx.media3.effect.OverlayEffect
import androidx.media3.effect.OverlaySettings
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects

/**
 * Compiles a Project into a media3 [Composition] suitable for both
 * playback (via CompositionPlayer in MediaPreviewView) and export
 * (via Transformer in ProjectExporter).
 *
 * Same compiled Composition feeds both pipelines — that's the
 * "Preview = Export 1:1" guarantee on Android.
 *
 * V1 limitations (TODOs documented in 0.14.0 CHANGELOG):
 *  - Inter-clip transitions on Android collapse to cut. Implementing
 *    fade/fadeToBlack between items in media3 requires either multi-
 *    sequence Composition layering with timed alpha overlays, or a
 *    custom GlEffect. Scheduled for 0.14.1.
 *  - Per-clip audio volume ramps not implemented — original-audio
 *    volume is per-clip but constant (0 or 1).
 *  - Image clips inside video tracks are wrapped as MediaItems with
 *    a fixed duration; media3 1.5+ supports this natively via
 *    setImageDurationMs on EditedMediaItem.
 */
@UnstableApi
object ProjectCompiler {

  enum class Mode { PREVIEW, EXPORT }

  data class CompiledComposition(
    val composition: Composition,
    val renderWidth: Int,
    val renderHeight: Int,
  )

  fun compile(context: Context, project: Project, mode: Mode): CompiledComposition {
    val videoClips = project.videoClips()
    if (videoClips.isEmpty()) throw IllegalStateException("Project has no video clips")

    // Resolve render size from first non-image clip; falls back to
    // canvas if everything's an image.
    val renderSize = resolveRenderSize(context, videoClips, project)
    val renderW = renderSize.first
    val renderH = renderSize.second

    // Build a list of EditedMediaItem — one per clip in order.
    val items = videoClips.map { clip -> buildEditedMediaItem(clip) }
    val videoSequence = EditedMediaItemSequence.Builder().apply {
      items.forEach { addItem(it) }
    }.build()

    // Audio tracks (background music / voice-over). Each becomes its
    // own audio-only EditedMediaItemSequence so it mixes against the
    // video sequence's original audio in the Composition.
    val audioSequences = project.audioClips().mapNotNull { audio ->
      buildAudioSequence(audio, project)
    }

    // Build composition-level OverlayEffect from overlay tracks.
    val compositionBuilder = Composition.Builder(listOf(videoSequence) + audioSequences)
    val overlays = project.overlayClips()
    if (overlays.isNotEmpty()) {
      val frameOverlay = ProjectFrameOverlay(overlays, renderW, renderH, project.durationMs)
      val overlayEffect = OverlayEffect(listOf(frameOverlay))
      compositionBuilder.setEffects(Effects(emptyList(), listOf(overlayEffect)))
    }

    return CompiledComposition(
      composition = compositionBuilder.build(),
      renderWidth = renderW,
      renderHeight = renderH,
    )
  }

  // MARK: - per-clip builders

  private fun buildEditedMediaItem(clip: ProjectVideoClip): EditedMediaItem {
    val mediaItem = if (clip.isImage) {
      MediaItem.Builder()
        .setUri(clip.sourceUri)
        .build()
    } else {
      MediaItem.Builder()
        .setUri(clip.sourceUri)
        .setClippingConfiguration(
          MediaItem.ClippingConfiguration.Builder()
            .setStartPositionMs(clip.sourceRange.startMs)
            .setEndPositionMs(clip.sourceRange.endMs)
            .build()
        )
        .build()
    }
    val builder = EditedMediaItem.Builder(mediaItem)
    if (clip.isImage) {
      // media3 1.5+: image MediaItems need an explicit duration.
      val dur = clip.imageDurationMs ?: clip.timelineRange.durationMs
      builder.setDurationUs(dur * 1000L)
      builder.setFrameRate(30)
    }
    if (clip.originalVolume == 0f && !clip.isImage) {
      builder.setRemoveAudio(true)
    }
    return builder.build()
  }

  private fun buildAudioSequence(audio: ProjectAudioClip, project: Project): EditedMediaItemSequence? {
    val mediaItem = MediaItem.Builder()
      .setUri(audio.sourceUri)
      .setClippingConfiguration(
        MediaItem.ClippingConfiguration.Builder()
          .setStartPositionMs(audio.sourceRange.startMs)
          .setEndPositionMs(
            // trimToVideo: cap audio at project duration when set
            if (audio.trimToVideo) {
              audio.sourceRange.startMs + (project.durationMs - audio.timelineRange.startMs)
                .coerceAtLeast(0)
            } else audio.sourceRange.endMs
          )
          .build()
      )
      .build()
    val edited = EditedMediaItem.Builder(mediaItem)
      .setRemoveVideo(true)
      .build()
    return EditedMediaItemSequence.Builder().addItem(edited).build()
  }

  // MARK: - render-size resolution

  private fun resolveRenderSize(
    context: Context, clips: List<ProjectVideoClip>, project: Project,
  ): Pair<Int, Int> {
    for (clip in clips) {
      if (clip.isImage) continue
      val retriever = android.media.MediaMetadataRetriever()
      try {
        retriever.setDataSource(context, Uri.parse(clip.sourceUri))
        var w = retriever.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toInt() ?: 0
        var h = retriever.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toInt() ?: 0
        val rotation = retriever.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toInt() ?: 0
        if (rotation == 90 || rotation == 270) { val t = w; w = h; h = t }
        if (w > 0 && h > 0) return Pair(w, h)
      } catch (_: Exception) {
      } finally {
        try { retriever.release() } catch (_: Exception) {}
      }
    }
    return Pair(project.canvasWidth, project.canvasHeight)
  }
}

/**
 * BitmapOverlay subclass that re-renders all project overlays into a
 * single full-frame bitmap per presentation time. The renderer logic
 * lives in OverlayBitmapRenderer so preview and export hit the SAME
 * code path.
 *
 * Frames are bucketed at 100ms to amortise the cost; most overlays
 * (subtitles, stickers) don't actually need 30fps updates. Karaoke-
 * highlight wandering uses its own clips per word, so each clip is
 * static and the bucket cache hits often.
 */
@UnstableApi
class ProjectFrameOverlay(
  private val overlays: List<ProjectOverlayClip>,
  private val videoWidth: Int,
  private val videoHeight: Int,
  private val projectDurationMs: Long,
) : BitmapOverlay() {

  private val cache = androidx.collection.LruCache<Long, Bitmap>(8)
  private val emptyBitmap by lazy {
    Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888)
  }

  override fun getBitmap(presentationTimeUs: Long): Bitmap {
    val timeMs = presentationTimeUs / 1000L
    val bucket = timeMs / 100L
    cache.get(bucket)?.let { return it }

    val bmp = Bitmap.createBitmap(videoWidth, videoHeight, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bmp)
    OverlayBitmapRenderer.drawOverlays(canvas, overlays, timeMs, videoWidth, videoHeight)
    cache.put(bucket, bmp)
    return bmp
  }

  override fun getOverlaySettings(presentationTimeUs: Long): OverlaySettings {
    // anchor 0,0 + scale 1 → bitmap covers the entire frame.
    return OverlaySettings.Builder().build()
  }
}
