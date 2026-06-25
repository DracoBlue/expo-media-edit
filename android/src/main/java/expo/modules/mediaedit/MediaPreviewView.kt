package expo.modules.mediaedit

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.LayoutInflater
import android.widget.FrameLayout
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.CompositionPlayer
import androidx.media3.ui.PlayerView
import expo.modules.kotlin.AppContext
import expo.modules.kotlin.viewevent.EventDispatcher
import expo.modules.kotlin.views.ExpoView

/**
 * Native view backing <MediaPreview /> on Android. Holds a media3
 * [CompositionPlayer] fed by the same [ProjectCompiler] output the
 * exporter uses — preview pixels == export pixels.
 *
 * Recompiles when the project JSON changes (cheap hash check);
 * ignores re-renders with the same project. Time scrubbing via the
 * `time` prop; playback via `playing`. Emits onTime (~33ms tick),
 * onReady, onError.
 */
@UnstableApi
class MediaPreviewView(context: Context, appContext: AppContext) : ExpoView(context, appContext) {

  private val playerView: PlayerView
  private var player: CompositionPlayer? = null
  private var lastProjectHash: Int = 0
  private var pendingTimeMs: Long? = null
  private var pendingPlaying: Boolean = false

  private val mainHandler = Handler(Looper.getMainLooper())
  private val timeTick = object : Runnable {
    override fun run() {
      val p = player ?: return
      onTime(mapOf("ms" to p.currentPosition.toDouble()))
      mainHandler.postDelayed(this, 33)
    }
  }

  val onTime by EventDispatcher()
  val onReady by EventDispatcher()
  val onError by EventDispatcher()

  init {
    playerView = PlayerView(context).apply {
      useController = false
      layoutParams = FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
      )
    }
    addView(playerView)
  }

  // MARK: - Prop setters (called from ExpoMediaEditModule's View block)

  @Suppress("UNCHECKED_CAST")
  fun updateProject(projectDict: Map<String, Any?>) {
    val hash = projectDict.hashCode()
    if (hash == lastProjectHash && player != null) return
    lastProjectHash = hash

    try {
      val project = ProjectParser.parse(projectDict)
      val compiled = ProjectCompiler.compile(context, project, ProjectCompiler.Mode.PREVIEW)
      tearDownPlayer()
      val p = CompositionPlayer.Builder(context).build()
      p.addListener(object : Player.Listener {
        override fun onPlaybackStateChanged(playbackState: Int) {
          if (playbackState == Player.STATE_READY) {
            onReady(mapOf("durationMs" to project.durationMs.toDouble()))
            pendingTimeMs?.let { p.seekTo(it) }
            if (pendingPlaying) p.play()
          }
        }
        override fun onPlayerError(error: androidx.media3.common.PlaybackException) {
          onError(mapOf("message" to (error.message ?: "Unknown playback error")))
        }
      })
      p.setComposition(compiled.composition)
      p.prepare()
      playerView.player = p
      player = p
      mainHandler.removeCallbacks(timeTick)
      mainHandler.postDelayed(timeTick, 33)
    } catch (e: Exception) {
      onError(mapOf("message" to "${e.javaClass.simpleName}: ${e.message ?: ""}"))
    }
  }

  fun updateTime(ms: Double) {
    val msLong = ms.toLong()
    pendingTimeMs = msLong
    player?.seekTo(msLong)
  }

  fun updatePlaying(playing: Boolean) {
    pendingPlaying = playing
    val p = player ?: return
    if (playing) p.play() else p.pause()
  }

  fun updateRenderScale(scale: Double) {
    // Preview render scale doesn't apply on Android — CompositionPlayer
    // renders at the source's natural resolution and the surface scales
    // it for display. Field is accepted for API symmetry with iOS.
  }

  // MARK: - lifecycle

  private fun tearDownPlayer() {
    mainHandler.removeCallbacks(timeTick)
    player?.release()
    player = null
    playerView.player = null
  }

  override fun onDetachedFromWindow() {
    super.onDetachedFromWindow()
    tearDownPlayer()
  }
}
