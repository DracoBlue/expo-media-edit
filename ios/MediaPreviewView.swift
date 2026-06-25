import ExpoModulesCore
import AVFoundation
import UIKit

/// Native view backing <MediaPreview /> on iOS. Holds an AVPlayer
/// fed by a CompiledComposition that is rebuilt whenever the
/// `project` prop changes. Time scrubbing is controlled from JS via
/// the `time` prop; playback is controlled via `playing`.
///
/// Overlays are rendered as a CALayer tree wrapped in an
/// AVSynchronizedLayer attached to the playerItem — the layer's
/// timed animations are driven by the player's clock so subtitle /
/// sticker / text overlays appear and disappear in sync with the
/// underlying video. This is the API-correct way to do
/// CoreAnimation overlays in PLAYBACK; `AVVideoCompositionCoreAnimationTool`
/// is offline-only and crashes AVPlayerItem.
///
/// Same OverlayRenderer code produces the layer tree for both the
/// export pipeline (animationTool) and this preview path
/// (AVSynchronizedLayer) — preview pixels == export pixels.
public class MediaPreviewView: ExpoView {

  private let playerLayer = AVPlayerLayer()
  private var player: AVPlayer?
  private var compiled: CompiledComposition?
  private var timeObserver: Any?

  // Overlay layer hierarchy. The synced layer hosts the overlay
  // parent; both get re-positioned in layoutSubviews() so the
  // overlays sit ON the video rect (post-aspect-fit), not the full
  // bounds.
  private var syncedLayer: AVSynchronizedLayer?
  private var overlayParent: CALayer?
  private var overlayRenderSize: CGSize = .zero
  // Observer for AVPlayerLayer.videoRect (which changes as the
  // surface resizes and the asset loads). When it fires we
  // reposition the synced layer to match.
  private var videoRectObserver: NSKeyValueObservation?

  /// External controlled state — assigned from props by the bridge.
  /// `pendingTimeMs` decouples "JS asks for time X" from "player is
  /// ready to accept a seek": when the project prop changes we have
  /// to recompile and re-load before seeking is meaningful.
  private var pendingTimeMs: Double?
  private var pendingPlaying: Bool = false
  private var renderScale: CGFloat = 0.5
  private var lastProjectHash: Int = 0

  // ExpoModulesCore event payloads.
  let onTime = EventDispatcher()
  let onReady = EventDispatcher()
  let onError = EventDispatcher()

  public required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    playerLayer.videoGravity = .resizeAspect
    layer.addSublayer(playerLayer)
    backgroundColor = .black

    // videoRect on AVPlayerLayer reports where the video actually
    // shows (post-letterboxing). It's nil/empty until the asset
    // loads, then settles. We watch it so the synced overlay layer
    // re-positions onto the video rect after load.
    videoRectObserver = playerLayer.observe(\.videoRect, options: [.new]) { [weak self] _, _ in
      DispatchQueue.main.async { self?.layoutOverlayLayer() }
    }
  }

  public override func layoutSubviews() {
    super.layoutSubviews()
    playerLayer.frame = bounds
    layoutOverlayLayer()
  }

  // MARK: - Prop setters (called from the Expo Module's View(...) Prop blocks)

  /// `projectDict` is the raw JS object — same shape the exporter
  /// receives. We parse + compile on every change. Cheap idempotency
  /// check via JSON-hash so re-renders that pass the same project
  /// don't tear down the player.
  public func updateProject(_ projectDict: [String: Any]) {
    let h = hashOf(projectDict)
    if h == lastProjectHash, player != nil { return }
    lastProjectHash = h

    do {
      let project = try ProjectParser.parse(projectDict)
      let cc = try ProjectCompiler.compile(project, mode: .preview(renderScale: renderScale))
      self.compiled = cc
      let playerItem = AVPlayerItem(asset: cc.composition)
      playerItem.videoComposition = cc.videoComposition
      if let mix = cc.audioMix { playerItem.audioMix = mix }
      tearDownPlayer()
      let p = AVPlayer(playerItem: playerItem)
      installTimeObserver(on: p)
      self.player = p
      playerLayer.player = p

      // Rebuild the overlay layer for this composition. Collect every
      // overlay clip from the project's overlay tracks — OverlayRenderer
      // produces a CALayer tree sized against the videoComposition's
      // (preview-scaled) renderSize. Wrap in AVSynchronizedLayer so the
      // sublayers' CAKeyframeAnimations (opacity timing windows) are
      // driven by the player clock.
      var overlays: [ProjectOverlayClip] = []
      for t in project.tracks {
        if case .overlay(_, let items) = t {
          overlays.append(contentsOf: items)
        }
      }
      let renderSize = cc.videoComposition.renderSize
      overlayRenderSize = renderSize
      if let parent = OverlayRenderer.buildOverlayLayer(
        overlays: overlays,
        videoSize: renderSize,
        videoTotalDuration: cc.composition.duration
      ) {
        let synced = AVSynchronizedLayer(playerItem: playerItem)
        synced.addSublayer(parent)
        layer.addSublayer(synced)
        syncedLayer = synced
        overlayParent = parent
        // Disable implicit animations on the synced layer's bounds /
        // position changes so resizes don't tween.
        synced.actions = ["bounds": NSNull(), "position": NSNull(), "transform": NSNull()]
        parent.actions = ["bounds": NSNull(), "position": NSNull(), "transform": NSNull()]
        layoutOverlayLayer()
      }

      onReady(["durationMs": project.durationMs])
      if let t = pendingTimeMs { seek(to: t) }
      if pendingPlaying { p.play() }
    } catch {
      onError(["message": "\(error)"])
    }
  }

  public func updateTime(_ ms: Double) {
    pendingTimeMs = ms
    // Tolerance-check: during normal playback the player advances on
    // its own and the outer view echoes our onTime callback back as
    // the `time` prop on every React re-render. Re-seeking to a time
    // we're already at triggers a pause+seek+resume cycle that stutters
    // playback (PO repro 2026-06-25: "preview unterbricht alle 200ms").
    // Only seek when the requested time differs from the player's
    // current position by more than 150ms — covers natural advance
    // between echoes without blocking real external scrubs.
    if let p = player {
      let currentMs = CMTimeGetSeconds(p.currentTime()) * 1000.0
      if currentMs.isFinite && abs(currentMs - ms) < 150 { return }
    }
    seek(to: ms)
  }

  public func updatePlaying(_ playing: Bool) {
    pendingPlaying = playing
    guard let p = player else { return }
    if playing { p.play() } else { p.pause() }
  }

  public func updateRenderScale(_ scale: Double) {
    let s = CGFloat(max(0.1, min(1.0, scale)))
    if abs(s - renderScale) < 0.01 { return }
    renderScale = s
    // Force recompile on next project update by invalidating the hash.
    lastProjectHash = 0
  }

  // MARK: - Player lifecycle

  private func seek(to ms: Double) {
    guard let p = player else { return }
    let t = CMTime(value: CMTimeValue(ms), timescale: 1000)
    p.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
  }

  private func installTimeObserver(on p: AVPlayer) {
    let interval = CMTime(value: 1, timescale: 30)
    timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
      guard let self = self else { return }
      self.onTime(["ms": CMTimeGetSeconds(t) * 1000.0])
    }
  }

  private func tearDownPlayer() {
    if let obs = timeObserver, let p = player {
      p.removeTimeObserver(obs)
    }
    timeObserver = nil
    player?.pause()
    player = nil
    playerLayer.player = nil
    syncedLayer?.removeFromSuperlayer()
    syncedLayer = nil
    overlayParent = nil
  }

  // MARK: - Overlay layout

  /// Position the synced overlay layer so its coordinate system maps
  /// 1:1 onto the on-screen video rectangle. The overlay parent was
  /// built against `overlayRenderSize` (the videoComposition's
  /// renderSize); we scale it to fit the playerLayer's videoRect.
  private func layoutOverlayLayer() {
    guard let synced = syncedLayer, let parent = overlayParent,
          overlayRenderSize.width > 0, overlayRenderSize.height > 0 else { return }
    let videoRect = playerLayer.videoRect
    if videoRect.isEmpty {
      // Asset hasn't loaded yet — fall back to the full bounds so
      // overlays appear immediately at the right scale, then snap
      // when videoRect becomes available.
      let r = bounds.isEmpty ? CGRect(origin: .zero, size: overlayRenderSize) : bounds
      synced.frame = r
    } else {
      synced.frame = videoRect
    }

    // Parent renders in overlayRenderSize coords. Scale it to fit
    // synced.frame. Translate origin to (0, 0) of synced.
    parent.frame = CGRect(origin: .zero, size: overlayRenderSize)
    let sx = synced.frame.width / overlayRenderSize.width
    let sy = synced.frame.height / overlayRenderSize.height
    // anchorPoint at (0,0) so scaling happens from the top-left;
    // matches the CoreAnimation flipped-Y convention OverlayRenderer
    // already uses for layout.
    parent.anchorPoint = .zero
    parent.position = .zero
    parent.transform = CATransform3DMakeScale(sx, sy, 1)
  }

  deinit {
    videoRectObserver?.invalidate()
    videoRectObserver = nil
    tearDownPlayer()
    // Best-effort cleanup of preview-pass temp files.
    compiled?.cleanupURLs.forEach { try? FileManager.default.removeItem(at: $0) }
  }

  // MARK: - Hashing

  /// Cheap stable hash of the project dict. We rely on JSONEncoder
  /// canonicalisation — fine for "did anything change?" detection.
  /// Not used for security.
  private func hashOf(_ dict: [String: Any]) -> Int {
    guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else { return 0 }
    return data.hashValue
  }
}
