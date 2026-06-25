import AVFoundation
import UIKit

/// Three artefacts that together describe a renderable scene. The
/// same struct feeds both AVPlayerItem (preview) and
/// AVAssetExportSession (export) — that's the entire
/// "Preview = Export 1:1" mechanism.
public struct CompiledComposition {
  public let composition: AVMutableComposition
  public let videoComposition: AVMutableVideoComposition
  public let audioMix: AVAudioMix?
  /// Temporary URLs that backed image-as-MP4 conversions; the caller
  /// should remove them after the consumer (player or exporter) is
  /// done with them. nil entries are safe to ignore.
  public let cleanupURLs: [URL]
}

public enum CompileMode {
  case preview(renderScale: CGFloat)
  case export
}

public enum CompileError: Error {
  case noVideoTracks
  case sourceLoadFailed(String)
  case compositionError(String)
}

/// Compiles a Project into the three AV artefacts that drive both
/// preview playback and export. Logic for clip insertion + transition
/// instructions + audio mixing extracted from the 0.13.x VideoEditor
/// playlist path; slide transition omitted by design (0.14.0 drop).
public class ProjectCompiler {

  public static func compile(_ project: Project, mode: CompileMode) throws -> CompiledComposition {
    let videoTracks = project.tracks.compactMap { (t: ProjectTrack) -> [ProjectVideoClip]? in
      if case .video(_, let clips) = t { return clips }; return nil
    }.flatMap { $0 }

    if videoTracks.isEmpty {
      throw CompileError.noVideoTracks
    }

    let composition = AVMutableComposition()
    var cleanupURLs: [URL] = []

    // Pre-compute render size from first video clip so image clips
    // scale into the same frame.
    let renderSize = try resolveRenderSize(clips: videoTracks)

    // Two alternating tracks for cross-dissolve / fadeToBlack /
    // (former slide) transitions — same shape as the legacy
    // PlaylistCompositor path. Cut-only single-clip cases still
    // use track1 (track2 simply stays empty).
    guard let track1 = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
          let track2 = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
      throw CompileError.compositionError("could not add video tracks")
    }

    var instructions: [AVMutableVideoCompositionInstruction] = []
    var currentTime = CMTime.zero
    var prevSrcTransform = CGAffineTransform.identity

    // Preview-mode renderScale: shrink the videoComposition's
    // renderSize AND multiply every per-clip transform by the same
    // factor so the source maps into the smaller canvas correctly.
    // Without the transform scaling, the source draws at its full
    // pixel size into the smaller canvas → only the top-left
    // quadrant is visible → apparent 2× zoom.
    let previewScale: CGFloat = {
      if case .preview(let s) = mode { return max(0.1, min(1.0, s)) }
      return 1.0
    }()
    let previewScaleTx = CGAffineTransform(scaleX: previewScale, y: previewScale)

    // `fitTransform` returns the transform that maps the source's
    // rendered (post-preferredTransform) rectangle into the FULL
    // renderSize, aspect-fit + centered. The preview-scale multiply
    // happens at the use site (every setTransform call) so the
    // composition reads cleanly: fit → preview-scale.
    func fitTransform(_ srcTrack: AVAssetTrack) -> CGAffineTransform {
      let pt = srcTrack.preferredTransform
      let rendered = srcTrack.naturalSize.applying(pt)
      let rW = abs(rendered.width); let rH = abs(rendered.height)
      guard rW > 0, rH > 0 else { return pt }
      if abs(rW - renderSize.width) < 0.5 && abs(rH - renderSize.height) < 0.5 { return pt }
      let scale = min(renderSize.width / rW, renderSize.height / rH)
      let scaledW = rW * scale; let scaledH = rH * scale
      let dx = (renderSize.width - scaledW) / 2
      let dy = (renderSize.height - scaledH) / 2
      return pt
        .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        .concatenating(CGAffineTransform(translationX: dx, y: dy))
    }

    // Wrap setTransform so every layer instruction picks up the
    // preview-scale uniformly. Calling this — not setTransform
    // directly — is what guarantees the per-clip transforms stay in
    // sync with the (preview-scaled) videoComposition.renderSize.
    func setScaledTransform(_ li: AVMutableVideoCompositionLayerInstruction, _ tx: CGAffineTransform, at time: CMTime) {
      li.setTransform(tx.concatenating(previewScaleTx), at: time)
    }
    func setScaledTransformRamp(_ li: AVMutableVideoCompositionLayerInstruction, from start: CGAffineTransform, to end: CGAffineTransform, timeRange: CMTimeRange) {
      li.setTransformRamp(
        fromStart: start.concatenating(previewScaleTx),
        toEnd: end.concatenating(previewScaleTx),
        timeRange: timeRange
      )
    }

    // Per-clip composition: walk video clips in order, build asset +
    // insert range + emit instruction(s) for the active transition.
    var audioTrack: AVMutableCompositionTrack?

    for (i, clip) in videoTracks.enumerated() {
      let asset: AVAsset
      let assetRange: CMTimeRange
      let isImage: Bool = clip.isImage

      if isImage {
        let imageDur = CMTime(value: CMTimeValue(clip.imageDurationMs ?? clip.timelineRange.durationMs), timescale: 1000)
        guard let url = URL(string: clip.sourceUri),
              let image = UIImage(contentsOfFile: url.path),
              let (tempAsset, tempURL) = imageToAsset(image: image, duration: imageDur, targetSize: renderSize) else {
          throw CompileError.sourceLoadFailed("image clip \(clip.id) could not be loaded")
        }
        asset = tempAsset
        assetRange = CMTimeRange(start: .zero, duration: imageDur)
        cleanupURLs.append(tempURL)
      } else {
        guard let url = URL(string: clip.sourceUri) else {
          throw CompileError.sourceLoadFailed("video clip \(clip.id) has invalid sourceUri")
        }
        asset = AVAsset(url: url)
        let s = clip.sourceRange.startTime
        let e = CMTimeMinimum(clip.sourceRange.endTime, asset.duration)
        assetRange = CMTimeRange(start: s, end: e)
      }

      guard let srcTrack = asset.tracks(withMediaType: .video).first else {
        throw CompileError.sourceLoadFailed("clip \(clip.id) has no video track")
      }

      let srcTx = fitTransform(srcTrack)
      let currTrack = i % 2 == 0 ? track1 : track2
      let prevTrack = i % 2 == 0 ? track2 : track1
      let itemDuration = assetRange.duration

      switch clip.transition {
      case .cut:
        do { try currTrack.insertTimeRange(assetRange, of: srcTrack, at: currentTime) }
        catch { throw CompileError.compositionError("insertTimeRange failed for clip \(clip.id): \(error.localizedDescription)") }
        let inst = AVMutableVideoCompositionInstruction()
        inst.timeRange = CMTimeRange(start: currentTime, duration: itemDuration)
        let li = AVMutableVideoCompositionLayerInstruction(assetTrack: currTrack)
        setScaledTransform(li, srcTx, at: currentTime)
        inst.layerInstructions = [li]
        instructions.append(inst)
        currentTime = currentTime + itemDuration

      case .fade(let durationMs):
        let transMs = min(durationMs, CMTimeGetSeconds(itemDuration) * 1000)
        let transDur = CMTime(value: CMTimeValue(transMs), timescale: 1000)
        let insertAt = currentTime - transDur
        do { try currTrack.insertTimeRange(assetRange, of: srcTrack, at: insertAt) }
        catch { throw CompileError.compositionError("insertTimeRange failed for clip \(clip.id): \(error.localizedDescription)") }

        if let prev = instructions.last {
          prev.timeRange = CMTimeRange(start: prev.timeRange.start, end: insertAt)
        }

        let overlapRange = CMTimeRange(start: insertAt, end: currentTime)
        let overlapInst = AVMutableVideoCompositionInstruction()
        overlapInst.timeRange = overlapRange
        let prevLI = AVMutableVideoCompositionLayerInstruction(assetTrack: prevTrack)
        setScaledTransform(prevLI, prevSrcTransform, at: insertAt)
        prevLI.setOpacityRamp(fromStartOpacity: 1.0, toEndOpacity: 0.0, timeRange: overlapRange)
        let currLI = AVMutableVideoCompositionLayerInstruction(assetTrack: currTrack)
        setScaledTransform(currLI, srcTx, at: insertAt)
        currLI.setOpacityRamp(fromStartOpacity: 0.0, toEndOpacity: 1.0, timeRange: overlapRange)
        overlapInst.layerInstructions = [currLI, prevLI]
        instructions.append(overlapInst)

        let afterStart = currentTime
        let itemEnd = insertAt + itemDuration
        if itemEnd > afterStart {
          let afterInst = AVMutableVideoCompositionInstruction()
          afterInst.timeRange = CMTimeRange(start: afterStart, end: itemEnd)
          let afterLI = AVMutableVideoCompositionLayerInstruction(assetTrack: currTrack)
          setScaledTransform(afterLI, srcTx, at: afterStart)
          afterInst.layerInstructions = [afterLI]
          instructions.append(afterInst)
        }
        currentTime = insertAt + itemDuration

      case .fadeToBlack(let durationMs):
        let halfMs = durationMs / 2
        let halfDur = CMTime(value: CMTimeValue(halfMs), timescale: 1000)

        if let prev = instructions.last,
           let prevLI = prev.layerInstructions.first as? AVMutableVideoCompositionLayerInstruction {
          let fadeOutStart = prev.timeRange.end - halfDur
          let fadeOutRange = CMTimeRange(start: fadeOutStart, end: prev.timeRange.end)
          prevLI.setOpacityRamp(fromStartOpacity: 1.0, toEndOpacity: 0.0, timeRange: fadeOutRange)
        }

        do { try currTrack.insertTimeRange(assetRange, of: srcTrack, at: currentTime) }
        catch { throw CompileError.compositionError("insertTimeRange failed for clip \(clip.id): \(error.localizedDescription)") }
        let itemEnd = currentTime + itemDuration
        let fadeInEnd = currentTime + halfDur
        let inst = AVMutableVideoCompositionInstruction()
        inst.timeRange = CMTimeRange(start: currentTime, end: itemEnd)
        let li = AVMutableVideoCompositionLayerInstruction(assetTrack: currTrack)
        setScaledTransform(li, srcTx, at: currentTime)
        li.setOpacityRamp(fromStartOpacity: 0.0, toEndOpacity: 1.0, timeRange: CMTimeRange(start: currentTime, end: fadeInEnd))
        inst.layerInstructions = [li]
        instructions.append(inst)
        currentTime = itemEnd
      }

      prevSrcTransform = srcTx

      // Mix in the clip's original audio at the corresponding timeline
      // position (skipping image clips and muted clips).
      if !isImage, clip.originalVolume > 0,
         let srcAudio = asset.tracks(withMediaType: .audio).first {
        if audioTrack == nil {
          audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        }
        if let t = audioTrack {
          let insertStart = currentTime - itemDuration
          try? t.insertTimeRange(assetRange, of: srcAudio, at: insertStart)
        }
      }
    }

    // Preview-mode renderScale shrinks the videoComposition's output
    // dimensions; the matching per-clip transforms above were already
    // pre-multiplied by previewScale via setScaledTransform so the
    // source content fits the smaller canvas correctly.
    let finalRenderSize = CGSize(
      width: renderSize.width * previewScale,
      height: renderSize.height * previewScale,
    )
    let videoComposition = AVMutableVideoComposition()
    videoComposition.renderSize = finalRenderSize
    videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(project.fps))
    videoComposition.instructions = instructions

    // Attach overlays from any overlay tracks
    var overlays: [ProjectOverlayClip] = []
    for t in project.tracks {
      if case .overlay(_, let items) = t {
        overlays.append(contentsOf: items)
      }
    }
    // AVVideoCompositionCoreAnimationTool is OFFLINE-RENDER ONLY.
    // Attaching it to an AVMutableVideoComposition that gets handed to
    // AVPlayerItem (preview) throws NSInvalidArgumentException at the
    // moment the player tries to play. Therefore we attach overlays
    // ONLY for the export path. Preview overlays are out of scope for
    // 0.15.x — callers that want overlay-in-preview must render them
    // as RN/UIKit views on top of <MediaPreview>. A future release
    // will switch the preview path to AVSynchronizedLayer-backed
    // overlays so Preview = Export holds without crashing.
    if !overlays.isEmpty, case .export = mode {
      OverlayRenderer.attachOverlays(
        to: videoComposition,
        overlays: overlays,
        videoTotalDuration: composition.duration
      )
    }

    // Build audio mix: per-clip original-volume from the video clips +
    // any audio-track clips (music/voice-over) inserted as additional
    // tracks.
    let audioMix = buildAudioMix(
      project: project,
      composition: composition,
      videoClips: videoTracks,
      videoOriginalTrack: audioTrack
    )

    return CompiledComposition(
      composition: composition,
      videoComposition: videoComposition,
      audioMix: audioMix,
      cleanupURLs: cleanupURLs
    )
  }

  // MARK: - Render-size resolution

  private static func resolveRenderSize(clips: [ProjectVideoClip]) throws -> CGSize {
    // First non-image video clip determines render size; falls back to
    // 1080x1920 portrait if everything is image-only.
    for clip in clips where !clip.isImage {
      guard let url = URL(string: clip.sourceUri) else { continue }
      let asset = AVAsset(url: url)
      if let t = asset.tracks(withMediaType: .video).first {
        let nat = t.naturalSize.applying(t.preferredTransform)
        let w = abs(nat.width); let h = abs(nat.height)
        if w > 0, h > 0 { return CGSize(width: w, height: h) }
      }
    }
    return CGSize(width: 1080, height: 1920)
  }

  // MARK: - Audio mix

  private static func buildAudioMix(
    project: Project,
    composition: AVMutableComposition,
    videoClips: [ProjectVideoClip],
    videoOriginalTrack: AVMutableCompositionTrack?
  ) -> AVAudioMix? {
    var mixParams: [AVMutableAudioMixInputParameters] = []

    // 1. Per-clip volume ramps on the merged original-audio track.
    // (Simplification: we don't currently emit per-clip volume ramps —
    // most clips ship at originalVolume=1; muting via originalVolume=0
    // is already handled by skipping insertion above. Per-clip ramps
    // can be added later as a follow-up.)
    if let t = videoOriginalTrack {
      let p = AVMutableAudioMixInputParameters(track: t)
      p.setVolume(1.0, at: .zero)
      mixParams.append(p)
    }

    // 2. Audio clips (background music / voice-over).
    for track in project.tracks {
      guard case .audio(_, let clips) = track else { continue }
      for clip in clips {
        guard let url = URL(string: clip.sourceUri) else { continue }
        let asset = AVAsset(url: url)
        guard let srcAudio = asset.tracks(withMediaType: .audio).first else { continue }

        let compAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        // Source range from project + optional trim-to-video clamp.
        var srcStart = clip.sourceRange.startTime
        var srcEnd = CMTimeMinimum(clip.sourceRange.endTime, asset.duration)
        var dstStart = clip.timelineRange.startTime
        if clip.trimToVideo {
          let projDur = CMTime(value: CMTimeValue(project.durationMs), timescale: 1000)
          let maxLen = projDur - dstStart
          if maxLen.seconds > 0 {
            srcEnd = CMTimeMinimum(srcEnd, srcStart + maxLen)
          }
        }
        if srcEnd > srcStart {
          let srcRange = CMTimeRange(start: srcStart, end: srcEnd)
          try? compAudioTrack?.insertTimeRange(srcRange, of: srcAudio, at: dstStart)
          if let t = compAudioTrack {
            let p = AVMutableAudioMixInputParameters(track: t)
            p.setVolume(Float(max(0, min(1, clip.volume))), at: .zero)
            mixParams.append(p)
          }
        }
        // Silence unused-warning for explicit-let pattern even if branches above don't touch srcStart.
        _ = srcStart
      }
    }

    if mixParams.isEmpty { return nil }
    let mix = AVMutableAudioMix()
    mix.inputParameters = mixParams
    return mix
  }

  // MARK: - Image → temp AVAsset

  private static func imageToAsset(image: UIImage, duration: CMTime, targetSize: CGSize) -> (AVAsset, URL)? {
    guard targetSize.width > 0, targetSize.height > 0 else { return nil }
    let imgW = image.size.width * image.scale
    let imgH = image.size.height * image.scale
    let fitScale = min(targetSize.width / imgW, targetSize.height / imgH)
    let drawW = imgW * fitScale
    let drawH = imgH * fitScale
    let drawX = (targetSize.width - drawW) / 2
    let drawY = (targetSize.height - drawH) / 2

    let format = UIGraphicsImageRendererFormat()
    format.scale = 1.0
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
}

// UIImage → CVPixelBuffer helper (copied from VideoEditor.swift so we
// can drop that file at 0.14.0 release without losing the helper).
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
