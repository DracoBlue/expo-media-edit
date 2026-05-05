import AVFoundation
import UIKit

public struct TrimOptions {
  let startMs: Double
  let endMs: Double
}

public struct TextOverlayOptions {
  let content: String
  let x: Double
  let y: Double
  let fontSize: Double
  let color: String
  let fontWeight: String
  let backgroundColor: String?
  let rotation: Double  // degrees, default 0
  let startMs: Double?
  let endMs: Double?
}

public struct ImageOverlayOptions {
  let uri: String
  let x: Double
  let y: Double
  let width: Double
  let height: Double
  let opacity: Double
  let startMs: Double?
  let endMs: Double?
}

public enum OverlayOptions {
  case text(TextOverlayOptions)
  case image(ImageOverlayOptions)
}

public struct AudioMixOptions {
  let uri: String
  let volume: Double
  let originalVolume: Double
  let startMs: Double
  let trimToVideo: Bool
}

public struct EditJobOptions {
  let outputUri: String?
  let trim: TrimOptions?
  let overlays: [OverlayOptions]
  let audio: AudioMixOptions?
  let quality: String

  init(dict: [String: Any]) {
    outputUri = dict["outputUri"] as? String
    quality = dict["quality"] as? String ?? "high"

    if let trimDict = dict["trim"] as? [String: Any],
       let startMs = trimDict["startMs"] as? Double,
       let endMs = trimDict["endMs"] as? Double {
      trim = TrimOptions(startMs: startMs, endMs: endMs)
    } else {
      trim = nil
    }

    var parsedOverlays: [OverlayOptions] = []
    if let overlayList = dict["overlays"] as? [[String: Any]] {
      for o in overlayList {
        guard let type = o["type"] as? String else { continue }
        if type == "text", let content = o["content"] as? String {
          parsedOverlays.append(.text(TextOverlayOptions(
            content: content,
            x: o["x"] as? Double ?? 0,
            y: o["y"] as? Double ?? 0,
            fontSize: o["fontSize"] as? Double ?? 32,
            color: o["color"] as? String ?? "#FFFFFF",
            fontWeight: o["fontWeight"] as? String ?? "normal",
            backgroundColor: o["backgroundColor"] as? String,
            rotation: o["rotation"] as? Double ?? 0,
            startMs: o["startMs"] as? Double,
            endMs: o["endMs"] as? Double
          )))
        } else if type == "image", let uri = o["uri"] as? String {
          guard !uri.contains("../"), uri.hasPrefix("file://") || uri.hasPrefix("https://") else { continue }
          parsedOverlays.append(.image(ImageOverlayOptions(
            uri: uri,
            x: o["x"] as? Double ?? 0,
            y: o["y"] as? Double ?? 0,
            width: o["width"] as? Double ?? 0.2,
            height: o["height"] as? Double ?? 0.2,
            opacity: o["opacity"] as? Double ?? 1.0,
            startMs: o["startMs"] as? Double,
            endMs: o["endMs"] as? Double
          )))
        }
      }
    }
    overlays = parsedOverlays

    if let audioDict = dict["audio"] as? [String: Any], let uri = audioDict["uri"] as? String {
      guard !uri.contains("../") else { audio = nil; return }
      audio = AudioMixOptions(
        uri: uri,
        volume: audioDict["volume"] as? Double ?? 1.0,
        originalVolume: audioDict["originalVolume"] as? Double ?? 0.0,
        startMs: audioDict["startMs"] as? Double ?? 0.0,
        trimToVideo: audioDict["trimToVideo"] as? Bool ?? true
      )
    } else {
      audio = nil
    }
  }
}

enum MediaEditError: Error {
  case trackError
  case exportFailed(String)
  case compositionError
}

@objc public class VideoEditor: NSObject {
  public func edit(
    inputURL: URL,
    outputURL: URL,
    job: EditJobOptions,
    onSessionReady: @escaping (AVAssetExportSession) -> Void,
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    let asset = AVAsset(url: inputURL)
    let composition = AVMutableComposition()

    let timeRange: CMTimeRange
    if let trim = job.trim {
      let start = CMTime(value: CMTimeValue(trim.startMs), timescale: 1000)
      let end = CMTime(value: CMTimeValue(trim.endMs), timescale: 1000)
      timeRange = CMTimeRange(start: start, end: end)
    } else {
      timeRange = CMTimeRange(start: .zero, duration: asset.duration)
    }

    guard let srcVideoTrack = asset.tracks(withMediaType: .video).first,
          let compVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
          ) else {
      completion(.failure(MediaEditError.trackError))
      return
    }

    do {
      try compVideoTrack.insertTimeRange(timeRange, of: srcVideoTrack, at: .zero)
      compVideoTrack.preferredTransform = srcVideoTrack.preferredTransform
    } catch {
      completion(.failure(error))
      return
    }

    var compAudioTrack: AVMutableCompositionTrack?
    if let srcAudioTrack = asset.tracks(withMediaType: .audio).first {
      compAudioTrack = composition.addMutableTrack(
        withMediaType: .audio,
        preferredTrackID: kCMPersistentTrackID_Invalid
      )
      try? compAudioTrack?.insertTimeRange(timeRange, of: srcAudioTrack, at: .zero)
    }

    let videoComposition = OverlayCompositor.buildVideoComposition(
      composition: composition,
      videoTrack: compVideoTrack,
      overlays: job.overlays
    )

    let audioMix = AudioMixer.buildAudioMix(
      composition: composition,
      originalTrack: compAudioTrack,
      musicOptions: job.audio
    )

    export(
      composition: composition,
      videoComposition: videoComposition,
      audioMix: audioMix,
      outputURL: outputURL,
      quality: job.quality,
      onSessionReady: onSessionReady,
      completion: completion
    )
  }

  private func export(
    composition: AVMutableComposition,
    videoComposition: AVMutableVideoComposition?,
    audioMix: AVAudioMix?,
    outputURL: URL,
    quality: String,
    onSessionReady: @escaping (AVAssetExportSession) -> Void,
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    let preset: String
    switch quality {
    case "low":    preset = AVAssetExportPresetLowQuality
    case "medium": preset = AVAssetExportPresetMediumQuality
    default:       preset = AVAssetExportPresetHighestQuality
    }

    guard let exportSession = AVAssetExportSession(asset: composition, presetName: preset) else {
      completion(.failure(MediaEditError.exportFailed("Could not create export session")))
      return
    }

    try? FileManager.default.removeItem(at: outputURL)

    exportSession.outputURL = outputURL
    exportSession.outputFileType = .mp4
    if let vc = videoComposition { exportSession.videoComposition = vc }
    if let am = audioMix { exportSession.audioMix = am }

    onSessionReady(exportSession)

    exportSession.exportAsynchronously {
      switch exportSession.status {
      case .completed:
        completion(.success(outputURL))
      case .cancelled:
        try? FileManager.default.removeItem(at: outputURL)
        completion(.failure(MediaEditError.exportFailed("Export cancelled")))
      case .failed:
        try? FileManager.default.removeItem(at: outputURL)
        completion(.failure(exportSession.error ?? MediaEditError.exportFailed("Unknown export error")))
      default:
        try? FileManager.default.removeItem(at: outputURL)
        completion(.failure(MediaEditError.exportFailed("Unexpected export status")))
      }
    }
  }
}
