import ExpoModulesCore
import AVFoundation
import UIKit

/// Native view backing <MediaPreview /> on iOS. Holds an AVPlayer
/// fed by a CompiledComposition that is rebuilt whenever the
/// `project` prop changes. Time scrubbing is controlled from JS via
/// the `time` prop; playback is controlled via `playing`.
///
/// Both the preview here and `exportProject` run through the SAME
/// ProjectCompiler — so what you see during scrub is what lands in
/// the exported MP4.
public class MediaPreviewView: ExpoView {

  private let playerLayer = AVPlayerLayer()
  private var player: AVPlayer?
  private var compiled: CompiledComposition?
  private var timeObserver: Any?

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
  }

  public override func layoutSubviews() {
    super.layoutSubviews()
    playerLayer.frame = bounds
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
      onReady(["durationMs": project.durationMs])
      if let t = pendingTimeMs { seek(to: t) }
      if pendingPlaying { p.play() }
    } catch {
      onError(["message": "\(error)"])
    }
  }

  public func updateTime(_ ms: Double) {
    pendingTimeMs = ms
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
  }

  deinit {
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
