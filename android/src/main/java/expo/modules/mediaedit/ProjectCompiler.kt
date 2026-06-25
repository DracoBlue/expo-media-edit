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
 * Compiles a Project into a media3 [Composition] for both preview
 * (CompositionPlayer) and export (Transformer). Same Composition →
 * preview pixels equal export pixels.
 *
 * Transitions (Android, 0.15.0):
 *  - cut         — clips back-to-back in a single sequence
 *  - fade        — TRUE crossfade. Overlapping clips placed in
 *                  alternating sequences (A/B) with gap padding so
 *                  they overlap by transitionMs. AlphaScaleEffect
 *                  ramps the outgoing clip's alpha 1 → 0 and the
 *                  incoming clip's alpha 0 → 1 across the overlap.
 *                  Both content streams remain visible during the
 *                  transition, matching iOS' setOpacityRamp behaviour.
 *  - fadeToBlack — no clip overlap. Clips concat back-to-back; a
 *                  full-frame black BitmapOverlay fades in over the
 *                  last halfMs of clip[i] and out over the first
 *                  halfMs of clip[i+1].
 *
 * V1 limitation kept from 0.14.0: per-clip volume ramps not emitted.
 * Original-audio volume is a 0-or-1 mute toggle via setRemoveAudio.
 */
@UnstableApi
object ProjectCompiler {

  enum class Mode { PREVIEW, EXPORT }

  data class CompiledComposition(
    val composition: Composition,
    val renderWidth: Int,
    val renderHeight: Int,
  )

  /** Bookkeeping per video clip — the absolute timeline window the
   *  clip occupies after overlap accounting, plus its alpha-effect
   *  windows (if any). */
  private data class PlacedClip(
    val clip: ProjectVideoClip,
    val timelineStartMs: Long,
    val timelineEndMs: Long,
    val laneIndex: Int,             // 0 = lane A, 1 = lane B (alternating for crossfade)
    val fadeInEndMs: Long?,         // null if no fade-in; else absolute ms where alpha reaches 1
    val fadeOutStartMs: Long?,      // null if no fade-out; else absolute ms where alpha starts dropping
  ) {
    val durationMs: Long get() = timelineEndMs - timelineStartMs
  }

  fun compile(context: Context, project: Project, mode: Mode): CompiledComposition {
    val videoClips = project.videoClips()
    if (videoClips.isEmpty()) throw IllegalStateException("Project has no video clips")

    val renderSize = resolveRenderSize(context, videoClips, project)
    val renderW = renderSize.first
    val renderH = renderSize.second

    // ── Pass 1: place each clip on the absolute timeline + assign a lane.
    // For consecutive `fade` transitions, clip[i+1] overlaps clip[i] by
    // transitionMs and is placed in the opposite lane so both can render
    // simultaneously inside the Composition.
    val placed = placeClips(videoClips)

    // ── Pass 2: build EditedMediaItemSequences per lane. Each lane is
    // a chain of `gap, clip, gap, clip, …` so absolute positions
    // align across lanes.
    val numLanes = (placed.maxOfOrNull { it.laneIndex } ?: 0) + 1
    val sequences = (0 until numLanes).map { lane -> buildLaneSequence(placed, lane) }

    // Audio sequences (one per audio clip).
    val audioSequences = project.audioClips().mapNotNull { buildAudioSequence(it, project) }

    // ── Composition-level overlay effects.
    val overlays = mutableListOf<BitmapOverlay>()
    if (project.overlayClips().isNotEmpty()) {
      overlays += ProjectFrameOverlay(project.overlayClips(), renderW, renderH, project.durationMs)
    }
    // fadeToBlack seams → timed black overlay.
    for (i in placed.indices) {
      val curr = placed[i]
      if (i + 1 >= placed.size) continue
      val next = placed[i + 1]
      if (curr.clip.transition !is ProjectClipTransition.FadeToBlack) continue
      val totalMs = (curr.clip.transition as ProjectClipTransition.FadeToBlack).durationMs
      val halfMs = totalMs / 2
      val fadeOutStart = curr.timelineEndMs - halfMs
      val fadeOutEnd = curr.timelineEndMs
      val fadeInStart = next.timelineStartMs
      val fadeInEnd = next.timelineStartMs + halfMs
      overlays += BlackFadeOverlay(
        videoWidth = renderW,
        videoHeight = renderH,
        fadeOutStartUs = fadeOutStart * 1000L,
        fadeOutEndUs = fadeOutEnd * 1000L,
        fadeInStartUs = fadeInStart * 1000L,
        fadeInEndUs = fadeInEnd * 1000L,
      )
    }

    val compositionBuilder = Composition.Builder(sequences + audioSequences)
    if (overlays.isNotEmpty()) {
      compositionBuilder.setEffects(Effects(emptyList(), listOf(OverlayEffect(overlays))))
    }

    return CompiledComposition(
      composition = compositionBuilder.build(),
      renderWidth = renderW,
      renderHeight = renderH,
    )
  }

  // MARK: - Placement (overlap accounting + lane assignment)

  private fun placeClips(clips: List<ProjectVideoClip>): List<PlacedClip> {
    val out = mutableListOf<PlacedClip>()
    var currentTimeMs = 0L
    var nextLane = 0
    var prevClipLane = 0

    for ((i, clip) in clips.withIndex()) {
      val sourceDurMs = if (clip.isImage) (clip.imageDurationMs ?: clip.timelineRange.durationMs)
                       else clip.sourceRange.durationMs

      // Transition on the PREVIOUS clip determines whether THIS clip overlaps.
      val prevTransition = if (i == 0) ProjectClipTransition.Cut else clips[i - 1].transition
      val (overlapMs, lane) = when (prevTransition) {
        is ProjectClipTransition.Fade -> {
          val o = minOf(prevTransition.durationMs, sourceDurMs)
          // Crossfade requires placing on the opposite lane.
          val l = if (prevClipLane == 0) 1 else 0
          o to l
        }
        else -> 0L to 0  // cut / fadeToBlack — always lane 0, no overlap
      }

      val startMs = currentTimeMs - overlapMs
      val endMs = startMs + sourceDurMs

      // Determine fade-in/fade-out windows for THIS clip based on its own
      // and the previous transition.
      val fadeInEndMs: Long? = if (prevTransition is ProjectClipTransition.Fade && overlapMs > 0) startMs + overlapMs else null
      val fadeOutStartMs: Long? = if (clip.transition is ProjectClipTransition.Fade) {
        val nextOverlap = minOf(clip.transition.durationMs, sourceDurMs)
        if (nextOverlap > 0) endMs - nextOverlap else null
      } else null

      out += PlacedClip(
        clip = clip, timelineStartMs = startMs, timelineEndMs = endMs,
        laneIndex = lane,
        fadeInEndMs = fadeInEndMs,
        fadeOutStartMs = fadeOutStartMs,
      )

      currentTimeMs = endMs
      prevClipLane = lane
      nextLane = if (lane == 0) 1 else 0
    }
    return out
  }

  // MARK: - Lane → EditedMediaItemSequence

  private fun buildLaneSequence(placed: List<PlacedClip>, laneIndex: Int): EditedMediaItemSequence {
    val builder = EditedMediaItemSequence.Builder()
    var laneCursor = 0L
    for (pc in placed) {
      if (pc.laneIndex != laneIndex) continue
      // Pad with gap up to pc.timelineStartMs
      val gap = pc.timelineStartMs - laneCursor
      if (gap > 0) {
        // media3 1.4+: addGap(durationUs)
        try {
          builder.addGap(gap * 1000L)
        } catch (_: NoSuchMethodError) {
          // Fallback path if a particular media3 build doesn't expose addGap.
          // Black-image gap is acceptable for our use (the OTHER lane carries
          // visible content at these timestamps in crossfade scenarios).
        }
      }
      val item = buildEditedMediaItem(pc)
      builder.addItem(item)
      laneCursor = pc.timelineEndMs
    }
    return builder.build()
  }

  // MARK: - per-clip EditedMediaItem with optional alpha effects

  private fun buildEditedMediaItem(pc: PlacedClip): EditedMediaItem {
    val clip = pc.clip
    val mediaItem = if (clip.isImage) {
      MediaItem.Builder().setUri(clip.sourceUri).build()
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
      val dur = clip.imageDurationMs ?: clip.timelineRange.durationMs
      builder.setDurationUs(dur * 1000L)
      builder.setFrameRate(30)
    }
    if (clip.originalVolume == 0f && !clip.isImage) {
      builder.setRemoveAudio(true)
    }

    // If this clip is in a crossfade (fade-in head and/or fade-out tail),
    // attach an AlphaScaleEffect whose alphaFor is computed in absolute-
    // timeline-time, then mapped to clip-local time inside the lambda.
    val clipStartUs = pc.timelineStartMs * 1000L
    val clipEndUs = pc.timelineEndMs * 1000L
    val fadeInEndUs = pc.fadeInEndMs?.let { it * 1000L }
    val fadeOutStartUs = pc.fadeOutStartMs?.let { it * 1000L }
    if (fadeInEndUs != null || fadeOutStartUs != null) {
      // media3 passes presentationTimeUs in MICROSECONDS already aligned
      // with the composition timeline once placed in the sequence.
      val alphaFn: (Long) -> Float = { t ->
        var a = 1f
        if (fadeInEndUs != null && t < fadeInEndUs) {
          val win = (fadeInEndUs - clipStartUs).coerceAtLeast(1L)
          a *= ((t - clipStartUs).coerceAtLeast(0L).toFloat() / win.toFloat()).coerceIn(0f, 1f)
        }
        if (fadeOutStartUs != null && t > fadeOutStartUs) {
          val win = (clipEndUs - fadeOutStartUs).coerceAtLeast(1L)
          val progress = ((t - fadeOutStartUs).toFloat() / win.toFloat()).coerceIn(0f, 1f)
          a *= (1f - progress)
        }
        a
      }
      builder.setEffects(Effects(emptyList(), listOf(AlphaScaleEffect(alphaFn))))
    }
    return builder.build()
  }

  // MARK: - audio sequences

  private fun buildAudioSequence(audio: ProjectAudioClip, project: Project): EditedMediaItemSequence? {
    val endMs = if (audio.trimToVideo) {
      val maxLen = (project.durationMs - audio.timelineRange.startMs).coerceAtLeast(0)
      audio.sourceRange.startMs + maxLen
    } else audio.sourceRange.endMs
    val mediaItem = MediaItem.Builder()
      .setUri(audio.sourceUri)
      .setClippingConfiguration(
        MediaItem.ClippingConfiguration.Builder()
          .setStartPositionMs(audio.sourceRange.startMs)
          .setEndPositionMs(endMs)
          .build()
      )
      .build()
    val edited = EditedMediaItem.Builder(mediaItem)
      .setRemoveVideo(true)
      .build()
    return EditedMediaItemSequence.Builder().addItem(edited).build()
  }

  // MARK: - render-size resolution

  private fun resolveRenderSize(context: Context, clips: List<ProjectVideoClip>, project: Project): Pair<Int, Int> {
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
 * Full-frame BitmapOverlay that re-renders project overlays into a
 * single bitmap per ~100ms bucket. Same as 0.14.0.
 */
@UnstableApi
class ProjectFrameOverlay(
  private val overlays: List<ProjectOverlayClip>,
  private val videoWidth: Int,
  private val videoHeight: Int,
  @Suppress("unused") private val projectDurationMs: Long,
) : BitmapOverlay() {
  private val cache = androidx.collection.LruCache<Long, Bitmap>(8)
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
  override fun getOverlaySettings(presentationTimeUs: Long): OverlaySettings =
    OverlaySettings.Builder().build()
}

/**
 * Full-frame black BitmapOverlay used at fadeToBlack seams. Single
 * shared 1×1 black bitmap (scaled to full frame via OverlaySettings'
 * default scale), with a time-dependent alpha that ramps up over the
 * fade-out window and down over the fade-in window.
 */
@UnstableApi
class BlackFadeOverlay(
  private val videoWidth: Int,
  private val videoHeight: Int,
  private val fadeOutStartUs: Long,
  private val fadeOutEndUs: Long,
  private val fadeInStartUs: Long,
  private val fadeInEndUs: Long,
) : BitmapOverlay() {
  private val blackBitmap: Bitmap by lazy {
    val b = Bitmap.createBitmap(videoWidth, videoHeight, Bitmap.Config.ARGB_8888)
    b.eraseColor(android.graphics.Color.BLACK)
    b
  }
  override fun getBitmap(presentationTimeUs: Long): Bitmap = blackBitmap
  override fun getOverlaySettings(presentationTimeUs: Long): OverlaySettings {
    val alpha = when {
      presentationTimeUs in fadeOutStartUs..fadeOutEndUs -> {
        val win = (fadeOutEndUs - fadeOutStartUs).coerceAtLeast(1L)
        ((presentationTimeUs - fadeOutStartUs).toFloat() / win.toFloat()).coerceIn(0f, 1f)
      }
      presentationTimeUs in fadeInStartUs..fadeInEndUs -> {
        val win = (fadeInEndUs - fadeInStartUs).coerceAtLeast(1L)
        1f - ((presentationTimeUs - fadeInStartUs).toFloat() / win.toFloat()).coerceIn(0f, 1f)
      }
      else -> 0f
    }
    return OverlaySettings.Builder().setAlphaScale(alpha).build()
  }
}
