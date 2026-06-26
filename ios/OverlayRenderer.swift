import AVFoundation
import UIKit
import QuartzCore

/// Builds CALayer trees for Project overlays. Logic extracted from
/// the 0.13.x OverlayCompositor.swift (per-glyph NSShadow, 4-copy
/// stroke approximation, Karaoke explicit-range highlight). API
/// reshaped to consume ProjectModel types directly so the same code
/// serves both the exporter and the live preview view.
///
/// TWO output paths, same layer-building code:
///   - `attachOverlays(...)` wraps the layers in
///     AVVideoCompositionCoreAnimationTool — used by ProjectExporter
///     (AVAssetExportSession, offline-render-only). Renders in
///     CoreAnimation video-native bottom-left coords.
///   - `buildOverlayLayer(...)` returns the bare parent CALayer for
///     AVSynchronizedLayer — used by MediaPreviewView (real-time
///     playback, where the animationTool API is forbidden). Renders
///     in UIKit top-left coords.
///
/// Pre-0.15.6 we tried to share a single bottom-left formula and
/// flip the synced parent via `isGeometryFlipped = true`. That worked
/// on paper but produced unexpected layout offsets in practice (PO
/// 2026-06-26 reported "y=1 → middle, y=0 → way above top"). 0.15.6
/// replaces the flip hack with an explicit `coordOrigin` parameter
/// — each caller picks the math that matches its render context.
public enum OverlayCoordOrigin {
  /// CoreAnimation video coordinate system: origin at BOTTOM-LEFT,
  /// y grows upward. Use for AVVideoCompositionCoreAnimationTool.
  case bottomLeft
  /// UIKit / on-screen CALayer coordinate system: origin at TOP-LEFT,
  /// y grows downward. Use for AVSynchronizedLayer / on-screen overlay.
  case topLeft
}

public class OverlayRenderer {

  /// Build the overlay CALayer tree for `overlays` sized against
  /// `videoSize`. Caller decides whether to wrap in
  /// AVVideoCompositionCoreAnimationTool (export, `coordOrigin =
  /// .bottomLeft`) or AVSynchronizedLayer (preview, `coordOrigin =
  /// .topLeft`). `videoTotalDuration` is needed so
  /// `applyTimingAnimation` can compute keyTime fractions when
  /// overlays have a timelineRange.
  ///
  /// Returns nil when there are no overlays — caller can short-circuit
  /// without an empty parent layer.
  public static func buildOverlayLayer(
    overlays: [ProjectOverlayClip],
    videoSize: CGSize,
    videoTotalDuration: CMTime,
    coordOrigin: OverlayCoordOrigin
  ) -> CALayer? {
    guard !overlays.isEmpty else { return nil }
    let parentLayer = CALayer()
    parentLayer.frame = CGRect(origin: .zero, size: videoSize)
    for overlay in overlays {
      switch overlay {
      case .text(let opts):
        let layer = buildTextLayer(opts: opts, videoSize: videoSize, duration: videoTotalDuration, coordOrigin: coordOrigin)
        parentLayer.addSublayer(layer)
      case .image(let opts):
        if let layer = buildImageLayer(opts: opts, videoSize: videoSize, duration: videoTotalDuration, coordOrigin: coordOrigin) {
          parentLayer.addSublayer(layer)
        }
      }
    }
    return parentLayer
  }

  /// Export path: attach overlays as an
  /// AVVideoCompositionCoreAnimationTool on the videoComposition.
  /// This wraps `buildOverlayLayer` with the additional video-layer
  /// container the tool requires. OFFLINE RENDER ONLY — never use
  /// on a videoComposition that gets handed to AVPlayerItem. The
  /// animationTool's parent layer renders in video-native bottom-left
  /// coords, so we always pass `coordOrigin: .bottomLeft`.
  public static func attachOverlays(
    to videoComposition: AVMutableVideoComposition,
    overlays: [ProjectOverlayClip],
    videoTotalDuration: CMTime
  ) {
    guard let overlaysLayer = buildOverlayLayer(
      overlays: overlays,
      videoSize: videoComposition.renderSize,
      videoTotalDuration: videoTotalDuration,
      coordOrigin: .bottomLeft
    ) else { return }

    let videoSize = videoComposition.renderSize
    let parentLayer = CALayer()
    parentLayer.frame = CGRect(origin: .zero, size: videoSize)

    let videoLayer = CALayer()
    videoLayer.frame = CGRect(origin: .zero, size: videoSize)
    parentLayer.addSublayer(videoLayer)

    // The overlays layer's own sublayers were created against the
    // same `videoSize`; we re-parent them into the
    // animationTool's parent layer (sitting above the videoLayer).
    for sublayer in overlaysLayer.sublayers ?? [] {
      parentLayer.addSublayer(sublayer)
    }

    videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
      postProcessingAsVideoLayer: videoLayer,
      in: parentLayer
    )
  }

  // MARK: - Font

  private static func resolveFont(
    fontSize: CGFloat, weight: String, style: String, family: String
  ) -> UIFont {
    let isBold = weight == "bold"
    let isItalic = style == "italic"
    let isMono = family == "monospace"

    let base: UIFont
    if isMono {
      base = UIFont.monospacedSystemFont(ofSize: fontSize, weight: isBold ? .bold : .regular)
    } else if isBold {
      base = UIFont.boldSystemFont(ofSize: fontSize)
    } else {
      base = UIFont.systemFont(ofSize: fontSize)
    }
    if !isItalic { return base }
    if let desc = base.fontDescriptor.withSymbolicTraits(
      base.fontDescriptor.symbolicTraits.union(.traitItalic)
    ) {
      return UIFont(descriptor: desc, size: fontSize)
    }
    return base
  }

  // MARK: - Text attributes

  private static func textAttributes(
    font: UIFont, color: UIColor, opts: ProjectTextOverlayClip
  ) -> [NSAttributedString.Key: Any] {
    var attrs: [NSAttributedString.Key: Any] = [
      .font: font, .foregroundColor: color,
    ]
    if let strokeStr = opts.strokeColor,
       let strokeColor = UIColor(hexString: strokeStr),
       opts.strokeWidth > 0 {
      // NSAttributedString.strokeWidth is in PERCENT of font size;
      // negative draws fill + stroke.
      let pxStroke = opts.strokeWidth
      let percent = -(pxStroke / Double(font.pointSize)) * 100.0
      attrs[.strokeColor] = strokeColor
      attrs[.strokeWidth] = percent
    }
    if let shadowStr = opts.shadowColor,
       let shadowColor = UIColor(hexString: shadowStr),
       opts.shadowRadius > 0 {
      let nsShadow = NSShadow()
      let scale = font.pointSize / CGFloat(opts.fontSize)
      nsShadow.shadowBlurRadius = CGFloat(opts.shadowRadius) * scale
      nsShadow.shadowOffset = .zero
      let opacity = max(0, min(1, opts.shadowOpacity))
      nsShadow.shadowColor = shadowColor.withAlphaComponent(CGFloat(opacity))
      attrs[.shadow] = nsShadow
    }
    return attrs
  }

  // MARK: - Layers

  /// Compute the layer's frame.origin.y given an `anchor` and the
  /// rendered layer height. `coordOrigin` selects which side of the
  /// parent the y axis grows from.
  ///
  /// `y` is a fraction 0..1 of the video height where 0 = TOP of the
  /// VIDEO and 1 = BOTTOM of the video. This semantic is invariant
  /// across both coord origins — only the layer-frame conversion
  /// differs.
  private static func computeYPos(
    y: Double, layerHeight: CGFloat,
    videoHeight: CGFloat, anchor: String,
    coordOrigin: OverlayCoordOrigin
  ) -> CGFloat {
    switch coordOrigin {
    case .bottomLeft:
      // CoreAnimation video coord. frame.origin.y is the BOTTOM-LEFT
      // corner of the layer, measured upward from the parent's
      // BOTTOM. y=0 (top of video) → layer near top → origin.y near
      // videoHeight. y=1 (bottom of video) → layer near bottom →
      // origin.y near 0.
      if anchor == "topLeft" {
        return videoHeight - CGFloat(y) * videoHeight - layerHeight
      } else {
        return videoHeight - (CGFloat(y) * videoHeight) - layerHeight / 2
      }
    case .topLeft:
      // UIKit on-screen coord. frame.origin.y is the TOP-LEFT corner
      // of the layer, measured DOWNWARD from the parent's TOP. y=0
      // (top of video) → layer near top → origin.y near 0. y=1
      // (bottom of video) → layer near bottom → origin.y near
      // videoHeight.
      if anchor == "topLeft" {
        return CGFloat(y) * videoHeight
      } else {
        return CGFloat(y) * videoHeight - layerHeight / 2
      }
    }
  }

  private static func buildTextLayer(
    opts: ProjectTextOverlayClip,
    videoSize: CGSize,
    duration: CMTime,
    coordOrigin: OverlayCoordOrigin
  ) -> CALayer {
    let fontSize = CGFloat(opts.fontSize) * videoSize.height / 1080.0
    let maxWidth = videoSize.width * 0.9
    let scale = videoSize.height / 1080.0
    let padH: CGFloat = CGFloat(opts.paddingX) * scale
    let padV: CGFloat = CGFloat(opts.paddingY) * scale

    let uiFont = resolveFont(
      fontSize: fontSize, weight: opts.fontWeight,
      style: opts.fontStyle, family: opts.fontFamily
    )
    let fgColor = UIColor(hexString: opts.color) ?? .white

    let attributed = NSMutableAttributedString(
      string: opts.content,
      attributes: textAttributes(font: uiFont, color: fgColor, opts: opts)
    )
    if let hlColorStr = opts.highlightColor,
       let hlColor = UIColor(hexString: hlColorStr),
       let start = opts.highlightStart,
       let length = opts.highlightLength,
       length > 0, start >= 0,
       start + length <= (opts.content as NSString).length {
      attributed.addAttribute(
        .foregroundColor, value: hlColor,
        range: NSRange(location: start, length: length)
      )
    }

    let measured = attributed.boundingRect(
      with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      context: nil
    )
    let layerWidth = ceil(measured.width) + padH * 2
    let layerHeight = ceil(measured.height) + padV * 2

    let xPos: CGFloat
    if opts.anchor == "topLeft" {
      xPos = CGFloat(opts.x) * videoSize.width
    } else {
      xPos = CGFloat(opts.x) * videoSize.width - layerWidth / 2
    }
    let yPos = computeYPos(
      y: opts.y, layerHeight: layerHeight,
      videoHeight: videoSize.height, anchor: opts.anchor,
      coordOrigin: coordOrigin
    )

    let alignment: CATextLayerAlignmentMode
    switch opts.textAlign {
    case "left":  alignment = .left
    case "right": alignment = .right
    default:      alignment = .center
    }

    let textLayer = CATextLayer()
    textLayer.string = attributed
    textLayer.alignmentMode = alignment
    textLayer.isWrapped = true
    textLayer.contentsScale = UIScreen.main.scale
    textLayer.frame = CGRect(x: xPos, y: yPos, width: layerWidth, height: layerHeight)

    if let bgColorStr = opts.backgroundColor,
       let bgColor = UIColor(hexString: bgColorStr) {
      textLayer.backgroundColor = bgColor.cgColor
    }
    if opts.cornerRadius > 0 {
      textLayer.cornerRadius = CGFloat(opts.cornerRadius) * scale
      textLayer.masksToBounds = true
    }

    applyTimingAnimation(to: textLayer, timelineRange: opts.timelineRange, duration: duration)

    if opts.rotation != 0 {
      let radians = CGFloat(opts.rotation) * .pi / 180
      let container = CALayer()
      container.frame = textLayer.frame
      textLayer.frame = CGRect(origin: .zero, size: textLayer.frame.size)
      container.addSublayer(textLayer)
      container.transform = CATransform3DMakeRotation(radians, 0, 0, 1)
      applyTimingAnimation(to: container, timelineRange: opts.timelineRange, duration: duration)
      return container
    }

    return textLayer
  }

  private static func buildImageLayer(
    opts: ProjectImageOverlayClip,
    videoSize: CGSize,
    duration: CMTime,
    coordOrigin: OverlayCoordOrigin
  ) -> CALayer? {
    guard !opts.uri.contains("../") else { return nil }
    let filePath = opts.uri.hasPrefix("file://")
      ? opts.uri.replacingOccurrences(of: "file://", with: "")
      : opts.uri
    guard let image = UIImage(contentsOfFile: filePath) else { return nil }

    let layerWidth = CGFloat(opts.width) * videoSize.width
    let layerHeight = CGFloat(opts.height) * videoSize.height
    let xPos = CGFloat(opts.x) * videoSize.width
    // Image overlays use anchor=topLeft semantics in OverlayRenderer
    // (legacy convention from 0.13.x). x/y mark the top-left of the
    // image; layerWidth/Height extend down-right.
    let yPos = computeYPos(
      y: opts.y, layerHeight: layerHeight,
      videoHeight: videoSize.height, anchor: "topLeft",
      coordOrigin: coordOrigin
    )

    let imageLayer = CALayer()
    imageLayer.contents = image.cgImage
    imageLayer.contentsGravity = .resizeAspect
    imageLayer.opacity = Float(opts.opacity)
    imageLayer.frame = CGRect(x: xPos, y: yPos, width: layerWidth, height: layerHeight)

    applyTimingAnimation(to: imageLayer, timelineRange: opts.timelineRange, duration: duration)

    if opts.rotation != 0 {
      let radians = CGFloat(opts.rotation) * .pi / 180
      let container = CALayer()
      container.frame = imageLayer.frame
      imageLayer.frame = CGRect(origin: .zero, size: imageLayer.frame.size)
      container.addSublayer(imageLayer)
      container.transform = CATransform3DMakeRotation(radians, 0, 0, 1)
      applyTimingAnimation(to: container, timelineRange: opts.timelineRange, duration: duration)
      return container
    }

    return imageLayer
  }

  private static func applyTimingAnimation(
    to layer: CALayer,
    timelineRange: ProjectTimeRange?,
    duration: CMTime
  ) {
    guard let range = timelineRange else { return }
    let totalDuration = CMTimeGetSeconds(duration)
    guard totalDuration > 0 else { return }
    let start = range.startMs / 1000.0
    let end = range.endMs / 1000.0

    let animation = CAKeyframeAnimation(keyPath: "opacity")
    animation.duration = totalDuration
    animation.keyTimes = [
      0,
      NSNumber(value: min(max(0, start / totalDuration), 1)),
      NSNumber(value: min(max(0, end / totalDuration), 1)),
      1,
    ]
    animation.values = [0, layer.opacity, 0, 0]
    animation.calculationMode = .discrete
    animation.isRemovedOnCompletion = false
    animation.fillMode = .both
    animation.beginTime = AVCoreAnimationBeginTimeAtZero
    layer.add(animation, forKey: "timing")
    if start > 0 { layer.opacity = 0 }
  }
}

// Hex parser kept here so OverlayRenderer is self-contained.
// (Identical to the 0.13.x extension that lived in OverlayCompositor.swift.)
extension UIColor {
  convenience init?(hexString: String) {
    var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
    if hex.hasPrefix("#") { hex = String(hex.dropFirst()) }
    var rgba: UInt64 = 0
    guard Scanner(string: hex).scanHexInt64(&rgba) else { return nil }
    let r, g, b, a: CGFloat
    switch hex.count {
    case 6:
      r = CGFloat((rgba >> 16) & 0xFF) / 255
      g = CGFloat((rgba >> 8) & 0xFF) / 255
      b = CGFloat(rgba & 0xFF) / 255
      a = 1.0
    case 8:
      r = CGFloat((rgba >> 24) & 0xFF) / 255
      g = CGFloat((rgba >> 16) & 0xFF) / 255
      b = CGFloat((rgba >> 8) & 0xFF) / 255
      a = CGFloat(rgba & 0xFF) / 255
    default:
      return nil
    }
    self.init(red: r, green: g, blue: b, alpha: a)
  }
}
