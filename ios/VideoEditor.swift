import AVFoundation
import UIKit

// MARK: - Common option structs

public struct TrimOptions {
  let startMs: Double
  let endMs: Double
}

public struct TextOverlayOptions {
  let content: String
  let x: Double
  let y: Double
  let anchor: String        // "topLeft" | "center"
  let textAlign: String     // "left" | "center" | "right"
  let paddingX: Double      // px at 1080-height reference
  let paddingY: Double      // px at 1080-height reference
  let fontSize: Double
  let color: String
  let fontWeight: String
  let backgroundColor: String?
  let cornerRadius: Double  // px at 1080-height reference, scaled like paddings
  let rotation: Double
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

// MARK: - Playlist types (0.4.0)

public enum TransitionOptions {
  case cut
  case fade(durationMs: Double)
  case fadeToBlack(durationMs: Double)
  case slide(durationMs: Double, direction: String)
}

public struct PlaylistVideoOptions {
  let uri: String
  let trim: TrimOptions?
  let transition: TransitionOptions
}

public struct PlaylistImageOptions {
  let uri: String
  let durationMs: Double
  let transition: TransitionOptions
}

public enum PlaylistItemOptions {
  case video(PlaylistVideoOptions)
  case image(PlaylistImageOptions)

  var isImage: Bool { if case .image = self { return true }; return false }
}

// MARK: - EditJobOptions

public struct EditJobOptions {
  let outputUri: String?
  let trim: TrimOptions?
  let overlays: [OverlayOptions]
  let audio: AudioMixOptions?
  let quality: String
  let playlist: [PlaylistItemOptions]?

  // Convenience init for single-video fast path
  init(inputURL: URL, trim: TrimOptions?, overlays: [OverlayOptions], audio: AudioMixOptions?, quality: String) {
    self.outputUri = nil
    self.trim = trim
    self.overlays = overlays
    self.audio = audio
    self.quality = quality
    self.playlist = [.video(PlaylistVideoOptions(uri: inputURL.absoluteString, trim: trim, transition: .cut))]
  }

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
          // 0.8.0: anchor / textAlign / paddingX / paddingY are required — skip silently if missing.
          guard let anchor = o["anchor"] as? String,
                anchor == "topLeft" || anchor == "center",
                let textAlign = o["textAlign"] as? String,
                textAlign == "left" || textAlign == "center" || textAlign == "right",
                let paddingX = o["paddingX"] as? Double,
                let paddingY = o["paddingY"] as? Double else { continue }
          parsedOverlays.append(.text(TextOverlayOptions(
            content: content,
            x: o["x"] as? Double ?? 0,
            y: o["y"] as? Double ?? 0,
            anchor: anchor,
            textAlign: textAlign,
            paddingX: paddingX,
            paddingY: paddingY,
            fontSize: o["fontSize"] as? Double ?? 32,
            color: o["color"] as? String ?? "#FFFFFF",
            fontWeight: o["fontWeight"] as? String ?? "normal",
            backgroundColor: o["backgroundColor"] as? String,
            cornerRadius: o["cornerRadius"] as? Double ?? 0,
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
      guard !uri.contains("../") else { audio = nil; playlist = nil; return }
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

    if let playlistArr = dict["playlist"] as? [[String: Any]] {
      var items: [PlaylistItemOptions] = []
      for (i, p) in playlistArr.enumerated() {
        guard let type = p["type"] as? String, let uri = p["uri"] as? String,
              !uri.contains("../"),
              uri.hasPrefix("file://") || uri.hasPrefix("https://") else { continue }
        let transition = EditJobOptions.parseTransition(p["transition"] as? [String: Any], isFirst: i == 0)
        if type == "video" {
          let t: TrimOptions?
          if let td = p["trim"] as? [String: Any],
             let s = td["startMs"] as? Double, let e = td["endMs"] as? Double {
            t = TrimOptions(startMs: s, endMs: e)
          } else { t = nil }
          items.append(.video(PlaylistVideoOptions(uri: uri, trim: t, transition: transition)))
        } else if type == "image" {
          items.append(.image(PlaylistImageOptions(
            uri: uri,
            durationMs: p["durationMs"] as? Double ?? 3000,
            transition: transition
          )))
        }
      }
      playlist = items.isEmpty ? nil : items
    } else {
      playlist = nil
    }
  }

  private static func parseTransition(_ dict: [String: Any]?, isFirst: Bool) -> TransitionOptions {
    guard !isFirst, let d = dict else { return .cut }
    switch d["type"] as? String {
    case "fade":      return .fade(durationMs: d["durationMs"] as? Double ?? 500)
    case "fadeToBlack": return .fadeToBlack(durationMs: d["durationMs"] as? Double ?? 500)
    case "slide":     return .slide(durationMs: d["durationMs"] as? Double ?? 500, direction: d["direction"] as? String ?? "left")
    default:          return .cut
    }
  }
}

// MARK: - Errors

enum MediaEditError: Error {
  case trackError
  case exportFailed(String)
  case compositionError
}

// MARK: - VideoEditor

@objc public class VideoEditor: NSObject {

  // MARK: Single-video (original path)

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

  // MARK: Playlist path (0.4.0)

  public func editPlaylist(
    playlist: [PlaylistItemOptions],
    outputURL: URL,
    job: EditJobOptions,
    onProgress: @escaping (Float) -> Void,
    onSessionReady: @escaping (AVAssetExportSession) -> Void,
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      // Pre-compute render size from first video item so image items are scaled to match
      var preRenderSize = CGSize(width: 1080, height: 1920)
      for item in playlist {
        if case .video(let v) = item, let url = URL(string: v.uri) {
          let asset = AVAsset(url: url)
          if let track = asset.tracks(withMediaType: .video).first {
            let nat = track.naturalSize.applying(track.preferredTransform)
            if abs(nat.width) > 0 && abs(nat.height) > 0 {
              preRenderSize = CGSize(width: abs(nat.width), height: abs(nat.height))
            }
          }
          break
        }
      }

      // Step 1: Resolve all items to AVAsset + duration
      struct Resolved {
        let asset: AVAsset
        let assetRange: CMTimeRange
        let duration: CMTime
        let transition: TransitionOptions
        var tempURL: URL? // for cleanup
      }

      var resolved: [Resolved] = []
      for (i, item) in playlist.enumerated() {
        let progress = Float(i) / Float(playlist.count) * 0.2
        onProgress(progress)

        switch item {
        case .video(let v):
          guard let url = URL(string: v.uri) else { completion(.failure(MediaEditError.trackError)); return }
          let asset = AVAsset(url: url)
          let assetDur = asset.duration
          let range: CMTimeRange
          if let t = v.trim {
            let s = CMTime(value: CMTimeValue(t.startMs), timescale: 1000)
            let e = CMTime(value: CMTimeValue(t.endMs), timescale: 1000)
            range = CMTimeRange(start: s, end: CMTimeMinimum(e, assetDur))
          } else {
            range = CMTimeRange(start: .zero, duration: assetDur)
          }
          resolved.append(Resolved(asset: asset, assetRange: range, duration: range.duration,
                                   transition: v.transition, tempURL: nil))

        case .image(let img):
          guard let url = URL(string: img.uri),
                let image = UIImage(contentsOfFile: url.path) else {
            completion(.failure(MediaEditError.trackError)); return
          }
          let dur = CMTime(value: CMTimeValue(img.durationMs), timescale: 1000)
          guard let (tempAsset, tempURL) = self.imageToAsset(image: image, duration: dur, targetSize: preRenderSize) else {
            completion(.failure(MediaEditError.compositionError)); return
          }
          resolved.append(Resolved(asset: tempAsset, assetRange: CMTimeRange(start: .zero, duration: dur),
                                   duration: dur, transition: img.transition, tempURL: tempURL))
        }
      }

      onProgress(0.2)

      // Step 2: Build AVMutableComposition with transitions
      let composition = AVMutableComposition()
      guard let track1 = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
            let track2 = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
        completion(.failure(MediaEditError.compositionError)); return
      }

      var instructions: [AVMutableVideoCompositionInstruction] = []
      var currentTime = CMTime.zero
      var renderSize = CGSize(width: 1920, height: 1080)
      var prevSrcTransform = CGAffineTransform.identity

      // Aspect-fit transform: applies preferredTransform, then scales and centres the
      // rendered frame inside renderSize so portrait clips don't overflow a landscape
      // composition (and vice versa).
      func fitTransform(_ srcTrack: AVAssetTrack) -> CGAffineTransform {
        let pt = srcTrack.preferredTransform
        let rendered = srcTrack.naturalSize.applying(pt)
        let rW = abs(rendered.width); let rH = abs(rendered.height)
        guard rW > 0, rH > 0 else { return pt }
        if abs(rW - renderSize.width) < 0.5 && abs(rH - renderSize.height) < 0.5 { return pt }
        let scale = min(renderSize.width / rW, renderSize.height / rH)
        let scaledW = rW * scale
        let scaledH = rH * scale
        let dx = (renderSize.width - scaledW) / 2
        let dy = (renderSize.height - scaledH) / 2
        return pt
          .concatenating(CGAffineTransform(scaleX: scale, y: scale))
          .concatenating(CGAffineTransform(translationX: dx, y: dy))
      }

      for (i, item) in resolved.enumerated() {
        guard let srcTrack = item.asset.tracks(withMediaType: .video).first else { continue }
        if i == 0 {
          let nat = srcTrack.naturalSize.applying(srcTrack.preferredTransform)
          renderSize = CGSize(width: abs(nat.width), height: abs(nat.height))
        }
        let srcTx = fitTransform(srcTrack)

        let currTrack = i % 2 == 0 ? track1 : track2
        let prevTrack = i % 2 == 0 ? track2 : track1

        switch item.transition {
        case .cut:
          do { try currTrack.insertTimeRange(item.assetRange, of: srcTrack, at: currentTime) } catch { completion(.failure(error)); return }
          let inst = AVMutableVideoCompositionInstruction()
          inst.timeRange = CMTimeRange(start: currentTime, duration: item.duration)
          let li = AVMutableVideoCompositionLayerInstruction(assetTrack: currTrack)
          li.setTransform(srcTx, at: currentTime)
          inst.layerInstructions = [li]
          instructions.append(inst)
          currentTime = currentTime + item.duration

        case .fade(let durationMs):
          let transMs = min(durationMs, CMTimeGetSeconds(item.duration) * 1000)
          let transDur = CMTime(value: CMTimeValue(transMs), timescale: 1000)
          let insertAt = currentTime - transDur
          do { try currTrack.insertTimeRange(item.assetRange, of: srcTrack, at: insertAt) } catch { completion(.failure(error)); return }

          if let prev = instructions.last {
            prev.timeRange = CMTimeRange(start: prev.timeRange.start, end: insertAt)
          }

          // Overlap instruction: cross-dissolve — both tracks need their transforms
          let overlapRange = CMTimeRange(start: insertAt, end: currentTime)
          let overlapInst = AVMutableVideoCompositionInstruction()
          overlapInst.timeRange = overlapRange
          let prevLI = AVMutableVideoCompositionLayerInstruction(assetTrack: prevTrack)
          prevLI.setTransform(prevSrcTransform, at: insertAt)
          prevLI.setOpacityRamp(fromStartOpacity: 1.0, toEndOpacity: 0.0, timeRange: overlapRange)
          let currLI = AVMutableVideoCompositionLayerInstruction(assetTrack: currTrack)
          currLI.setTransform(srcTx, at: insertAt)
          currLI.setOpacityRamp(fromStartOpacity: 0.0, toEndOpacity: 1.0, timeRange: overlapRange)
          overlapInst.layerInstructions = [currLI, prevLI]
          instructions.append(overlapInst)

          // After-transition instruction
          let afterStart = currentTime
          let itemEnd = insertAt + item.duration
          if itemEnd > afterStart {
            let afterInst = AVMutableVideoCompositionInstruction()
            afterInst.timeRange = CMTimeRange(start: afterStart, end: itemEnd)
            let afterLI = AVMutableVideoCompositionLayerInstruction(assetTrack: currTrack)
            afterLI.setTransform(srcTx, at: afterStart)
            afterInst.layerInstructions = [afterLI]
            instructions.append(afterInst)
          }
          currentTime = insertAt + item.duration

        case .fadeToBlack(let durationMs):
          let halfMs = durationMs / 2
          let halfDur = CMTime(value: CMTimeValue(halfMs), timescale: 1000)

          if let prev = instructions.last, let prevLI = prev.layerInstructions.first as? AVMutableVideoCompositionLayerInstruction {
            let fadeOutStart = prev.timeRange.end - halfDur
            let fadeOutRange = CMTimeRange(start: fadeOutStart, end: prev.timeRange.end)
            prevLI.setOpacityRamp(fromStartOpacity: 1.0, toEndOpacity: 0.0, timeRange: fadeOutRange)
          }

          do { try currTrack.insertTimeRange(item.assetRange, of: srcTrack, at: currentTime) } catch { completion(.failure(error)); return }
          let itemEnd = currentTime + item.duration
          let fadeInEnd = currentTime + halfDur
          let inst = AVMutableVideoCompositionInstruction()
          inst.timeRange = CMTimeRange(start: currentTime, end: itemEnd)
          let li = AVMutableVideoCompositionLayerInstruction(assetTrack: currTrack)
          li.setTransform(srcTx, at: currentTime)
          li.setOpacityRamp(fromStartOpacity: 0.0, toEndOpacity: 1.0, timeRange: CMTimeRange(start: currentTime, end: fadeInEnd))
          inst.layerInstructions = [li]
          instructions.append(inst)
          currentTime = itemEnd

        case .slide(let durationMs, let direction):
          let transMs = min(durationMs, CMTimeGetSeconds(item.duration) * 1000)
          let transDur = CMTime(value: CMTimeValue(transMs), timescale: 1000)
          let insertAt = currentTime - transDur
          do { try currTrack.insertTimeRange(item.assetRange, of: srcTrack, at: insertAt) } catch { completion(.failure(error)); return }

          if let prev = instructions.last {
            prev.timeRange = CMTimeRange(start: prev.timeRange.start, end: insertAt)
          }

          let overlapRange = CMTimeRange(start: insertAt, end: currentTime)
          let w = renderSize.width; let h = renderSize.height

          // Compose slide translations with each item's preferredTransform so rotated
          // videos (e.g. portrait iPhone clips) maintain their orientation during the slide
          let (prevStart, prevEnd, currStart, currEnd): (CGAffineTransform, CGAffineTransform, CGAffineTransform, CGAffineTransform)
          switch direction {
          case "right":
            prevStart = prevSrcTransform
            prevEnd = prevSrcTransform.concatenating(CGAffineTransform(translationX: w, y: 0))
            currStart = srcTx.concatenating(CGAffineTransform(translationX: -w, y: 0))
            currEnd = srcTx
          case "up":
            prevStart = prevSrcTransform
            prevEnd = prevSrcTransform.concatenating(CGAffineTransform(translationX: 0, y: -h))
            currStart = srcTx.concatenating(CGAffineTransform(translationX: 0, y: h))
            currEnd = srcTx
          case "down":
            prevStart = prevSrcTransform
            prevEnd = prevSrcTransform.concatenating(CGAffineTransform(translationX: 0, y: h))
            currStart = srcTx.concatenating(CGAffineTransform(translationX: 0, y: -h))
            currEnd = srcTx
          default: // "left"
            prevStart = prevSrcTransform
            prevEnd = prevSrcTransform.concatenating(CGAffineTransform(translationX: -w, y: 0))
            currStart = srcTx.concatenating(CGAffineTransform(translationX: w, y: 0))
            currEnd = srcTx
          }

          let overlapInst = AVMutableVideoCompositionInstruction()
          overlapInst.timeRange = overlapRange
          let prevLI = AVMutableVideoCompositionLayerInstruction(assetTrack: prevTrack)
          let currLI = AVMutableVideoCompositionLayerInstruction(assetTrack: currTrack)
          prevLI.setTransformRamp(fromStart: prevStart, toEnd: prevEnd, timeRange: overlapRange)
          currLI.setTransformRamp(fromStart: currStart, toEnd: currEnd, timeRange: overlapRange)
          overlapInst.layerInstructions = [currLI, prevLI]
          instructions.append(overlapInst)

          let afterStart = currentTime
          let itemEnd = insertAt + item.duration
          if itemEnd > afterStart {
            let afterInst = AVMutableVideoCompositionInstruction()
            afterInst.timeRange = CMTimeRange(start: afterStart, end: itemEnd)
            let afterLI = AVMutableVideoCompositionLayerInstruction(assetTrack: currTrack)
            afterLI.setTransform(srcTx, at: afterStart)
            afterInst.layerInstructions = [afterLI]
            instructions.append(afterInst)
          }
          currentTime = insertAt + item.duration
        }

        prevSrcTransform = srcTx
      }

      onProgress(0.3)

      // Step 3: Build videoComposition with instructions + overlays
      let videoComposition = AVMutableVideoComposition()
      videoComposition.renderSize = renderSize
      videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
      videoComposition.instructions = instructions

      let videoCompositionWithOverlays = OverlayCompositor.applyOverlays(
        to: videoComposition,
        composition: composition,
        overlays: job.overlays
      )

      // Step 4: Audio mix
      let audioMix = AudioMixer.buildAudioMix(
        composition: composition,
        originalTrack: composition.tracks(withMediaType: .audio).first as? AVMutableCompositionTrack,
        musicOptions: job.audio
      )

      // Step 5: Export
      self.export(
        composition: composition,
        videoComposition: videoCompositionWithOverlays,
        audioMix: audioMix,
        outputURL: outputURL,
        quality: job.quality,
        onSessionReady: onSessionReady,
        completion: { result in
          // Cleanup temp image videos
          resolved.compactMap { $0.tempURL }.forEach { try? FileManager.default.removeItem(at: $0) }
          completion(result)
        }
      )
    }
  }

  // MARK: Image → temp AVAsset

  private func imageToAsset(image: UIImage, duration: CMTime, targetSize: CGSize) -> (AVAsset, URL)? {
    guard targetSize.width > 0, targetSize.height > 0 else { return nil }

    // Scale image to fit targetSize (aspect-fit, centered on black)
    let imgW = image.size.width * image.scale
    let imgH = image.size.height * image.scale
    let fitScale = min(targetSize.width / imgW, targetSize.height / imgH)
    let drawW = imgW * fitScale
    let drawH = imgH * fitScale
    let drawX = (targetSize.width - drawW) / 2
    let drawY = (targetSize.height - drawH) / 2

    let format = UIGraphicsImageRendererFormat()
    format.scale = 1.0  // targetSize is already in physical pixels
    let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
    let scaledImage = renderer.image { ctx in
      UIColor.black.setFill()
      ctx.fill(CGRect(origin: .zero, size: targetSize))
      image.draw(in: CGRect(x: drawX, y: drawY, width: drawW, height: drawH))
    }

    let pixelSize = targetSize

    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("expo-media-edit")
    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    let outputURL = tempDir.appendingPathComponent(UUID().uuidString + "-img.mp4")

    guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else { return nil }
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: Int(pixelSize.width),
      AVVideoHeightKey: Int(pixelSize.height),
    ])
    videoInput.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)
    writer.add(videoInput)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    guard let pixelBuffer = scaledImage.cvPixelBuffer(size: pixelSize) else { return nil }

    // Write a frame every second for the whole duration
    let durationSec = CMTimeGetSeconds(duration)
    var t = 0.0
    while t < durationSec {
      while !adaptor.assetWriterInput.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.001) }
      adaptor.append(pixelBuffer, withPresentationTime: CMTime(seconds: t, preferredTimescale: 600))
      t += 1.0
    }

    videoInput.markAsFinished()
    let sem = DispatchSemaphore(value: 0)
    writer.finishWriting { sem.signal() }
    sem.wait()

    guard writer.status == .completed else { return nil }
    return (AVAsset(url: outputURL), outputURL)
  }

  // MARK: Export

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

// MARK: - UIImage → CVPixelBuffer

extension UIImage {
  func cvPixelBuffer(size: CGSize) -> CVPixelBuffer? {
    let attrs = [kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue!,
                 kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue!] as CFDictionary
    var pb: CVPixelBuffer?
    guard CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height),
                              kCVPixelFormatType_32ARGB, attrs, &pb) == kCVReturnSuccess,
          let buffer = pb else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    guard let ctx = CGContext(
      data: CVPixelBufferGetBaseAddress(buffer),
      width: Int(size.width), height: Int(size.height),
      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
    ), let cg = self.cgImage else {
      CVPixelBufferUnlockBaseAddress(buffer, [])
      return nil
    }
    ctx.draw(cg, in: CGRect(origin: .zero, size: size))
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
  }
}
