import AVFoundation
import Foundation

/// Runs a CompiledComposition through AVAssetExportSession to an MP4.
/// Mirrors the 0.13.x VideoEditor.export(...) lifecycle (preset
/// selection, progress timer, cancel hook, temp cleanup) but accepts
/// the new CompiledComposition struct directly.
public class ProjectExporter {

  private var activeExportSession: AVAssetExportSession?
  private var progressTimer: Timer?

  public init() {}

  /// Cancel the in-flight export, if any. Triggers `.cancelled`
  /// status on the next exportAsynchronously poll.
  public func cancel() {
    activeExportSession?.cancelExport()
  }

  public func export(
    compiled: CompiledComposition,
    outputURL: URL,
    quality: String,
    onProgress: @escaping (Float) -> Void,
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    let preset: String
    switch quality {
    case "low":    preset = AVAssetExportPresetLowQuality
    case "medium": preset = AVAssetExportPresetMediumQuality
    default:       preset = AVAssetExportPresetHighestQuality
    }

    guard let session = AVAssetExportSession(asset: compiled.composition, presetName: preset) else {
      completion(.failure(NSError(domain: "ExpoMediaEdit", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create export session"])))
      return
    }

    try? FileManager.default.removeItem(at: outputURL)
    session.outputURL = outputURL
    session.outputFileType = .mp4
    session.videoComposition = compiled.videoComposition
    if let am = compiled.audioMix { session.audioMix = am }

    self.activeExportSession = session

    DispatchQueue.main.async { [weak self] in
      self?.progressTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
        guard let s = self?.activeExportSession else { return }
        onProgress(s.progress)
      }
    }

    session.exportAsynchronously { [weak self] in
      DispatchQueue.main.async {
        self?.progressTimer?.invalidate()
        self?.progressTimer = nil
        self?.activeExportSession = nil
      }
      // Best-effort cleanup of intermediate image-as-MP4 temp files.
      compiled.cleanupURLs.forEach { try? FileManager.default.removeItem(at: $0) }

      switch session.status {
      case .completed:
        onProgress(1.0)
        completion(.success(outputURL))
      case .cancelled:
        try? FileManager.default.removeItem(at: outputURL)
        completion(.failure(NSError(domain: "ExpoMediaEdit", code: 2, userInfo: [NSLocalizedDescriptionKey: "Export was cancelled"])))
      case .failed:
        try? FileManager.default.removeItem(at: outputURL)
        let msg = session.error?.localizedDescription ?? "Unknown export error"
        completion(.failure(NSError(domain: "ExpoMediaEdit", code: 3, userInfo: [NSLocalizedDescriptionKey: msg])))
      default:
        try? FileManager.default.removeItem(at: outputURL)
        completion(.failure(NSError(domain: "ExpoMediaEdit", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unexpected export status"])))
      }
    }
  }
}
