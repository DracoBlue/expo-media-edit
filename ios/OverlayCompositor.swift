import AVFoundation
import UIKit
import QuartzCore

public class OverlayCompositor {

  public static func buildVideoComposition(
    composition: AVMutableComposition,
    videoTrack: AVMutableCompositionTrack,
    overlays: [OverlayOptions]
  ) -> AVMutableVideoComposition? {
    let videoComposition = AVMutableVideoComposition(propertiesOf: composition)

    guard !overlays.isEmpty else {
      return videoComposition
    }

    let videoSize = videoComposition.renderSize
    let duration = composition.duration

    // Parent layer (holds video + overlay layers)
    // CALayer coordinate system: origin at bottom-left, Y grows upward
    let parentLayer = CALayer()
    parentLayer.frame = CGRect(origin: .zero, size: videoSize)

    let videoLayer = CALayer()
    videoLayer.frame = CGRect(origin: .zero, size: videoSize)
    parentLayer.addSublayer(videoLayer)

    for overlay in overlays {
      switch overlay {
      case .text(let opts):
        let layer = buildTextLayer(opts: opts, videoSize: videoSize, duration: duration)
        parentLayer.addSublayer(layer)

      case .image(let opts):
        if let layer = buildImageLayer(opts: opts, videoSize: videoSize, duration: duration) {
          parentLayer.addSublayer(layer)
        }
      }
    }

    videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
      postProcessingAsVideoLayer: videoLayer,
      in: parentLayer
    )

    return videoComposition
  }

  // Used by the playlist path: apply overlays to an already-built videoComposition
  public static func applyOverlays(
    to videoComposition: AVMutableVideoComposition,
    composition: AVMutableComposition,
    overlays: [OverlayOptions]
  ) -> AVMutableVideoComposition {
    guard !overlays.isEmpty else { return videoComposition }

    let videoSize = videoComposition.renderSize
    let duration = composition.duration

    let parentLayer = CALayer()
    parentLayer.frame = CGRect(origin: .zero, size: videoSize)

    let videoLayer = CALayer()
    videoLayer.frame = CGRect(origin: .zero, size: videoSize)
    parentLayer.addSublayer(videoLayer)

    for overlay in overlays {
      switch overlay {
      case .text(let opts):
        let layer = buildTextLayer(opts: opts, videoSize: videoSize, duration: duration)
        parentLayer.addSublayer(layer)
      case .image(let opts):
        if let layer = buildImageLayer(opts: opts, videoSize: videoSize, duration: duration) {
          parentLayer.addSublayer(layer)
        }
      }
    }

    videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
      postProcessingAsVideoLayer: videoLayer,
      in: parentLayer
    )

    return videoComposition
  }

  /// Pick a UIFont from (weight, style, family). Italic is approximated
  /// by composing `.italic` symbolic traits onto whichever base font we
  /// picked — the system / monospace / bold variants all support it via
  /// their UIFontDescriptor.
  private static func resolveFont(
    fontSize: CGFloat,
    weight: String,
    style: String,
    family: String
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
    let desc = base.fontDescriptor.withSymbolicTraits(
      base.fontDescriptor.symbolicTraits.union(.traitItalic)
    )
    if let desc = desc {
      return UIFont(descriptor: desc, size: fontSize)
    }
    return base
  }

  /// Build the attribute dict for an NSAttributedString text layer.
  /// Stroke is expressed as a NEGATIVE strokeWidth so Core Text fills
  /// AND strokes the glyphs (positive would draw stroke-only). Stroke
  /// is in percent of font size per Apple docs — convert our 1080-ref
  /// pixel width to that scale.
  private static func textAttributes(
    font: UIFont,
    color: UIColor,
    opts: TextOverlayOptions
  ) -> [NSAttributedString.Key: Any] {
    var attrs: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: color,
    ]
    if let strokeStr = opts.strokeColor,
       let strokeColor = UIColor(hexString: strokeStr),
       opts.strokeWidth > 0 {
      // NSAttributedString.strokeWidth is in PERCENT of font size.
      // Convert from a 1080-ref pixel width: scale was already applied
      // to font size, so we compute percent against the on-screen font.
      let pxStroke = opts.strokeWidth // already in 1080-ref px
      let percent = -(pxStroke / Double(font.pointSize)) * 100.0
      attrs[.strokeColor] = strokeColor
      attrs[.strokeWidth] = percent
    }
    return attrs
  }

  private static func buildTextLayer(
    opts: TextOverlayOptions,
    videoSize: CGSize,
    duration: CMTime
  ) -> CALayer {
    // Scale fontSize consistently with Android (reference: 1080px height)
    let fontSize = CGFloat(opts.fontSize) * videoSize.height / 1080.0
    let maxWidth = videoSize.width * 0.9
    let scale = videoSize.height / 1080.0
    let padH: CGFloat = CGFloat(opts.paddingX) * scale
    let padV: CGFloat = CGFloat(opts.paddingY) * scale

    let uiFont = resolveFont(
      fontSize: fontSize,
      weight: opts.fontWeight,
      style: opts.fontStyle,
      family: opts.fontFamily
    )
    let fgColor = UIColor(hexString: opts.color) ?? .white

    // Build an attributed string that captures color, stroke, and
    // optional per-substring highlight in one shot. Using
    // NSAttributedString throughout unlocks features CATextLayer cannot
    // express via its plain-string path.
    let attributed = NSMutableAttributedString(
      string: opts.content,
      attributes: textAttributes(font: uiFont, color: fgColor, opts: opts)
    )
    if let hlWord = opts.highlightWord, !hlWord.isEmpty,
       let hlColorStr = opts.highlightColor,
       let hlColor = UIColor(hexString: hlColorStr) {
      let range = (opts.content as NSString).range(of: hlWord)
      if range.location != NSNotFound {
        attributed.addAttribute(.foregroundColor, value: hlColor, range: range)
      }
    }

    // Measure using the same attributes so wrapping math stays correct
    // when we add italic / monospace fonts.
    let measured = attributed.boundingRect(
      with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      context: nil
    )
    let layerWidth = ceil(measured.width) + padH * 2
    let layerHeight = ceil(measured.height) + padV * 2

    // CALayer Y is inverted: y=0 is bottom in Core Animation.
    let xPos: CGFloat
    let yPos: CGFloat
    if opts.anchor == "topLeft" {
      xPos = CGFloat(opts.x) * videoSize.width
      yPos = videoSize.height - CGFloat(opts.y) * videoSize.height - layerHeight
    } else {
      xPos = CGFloat(opts.x) * videoSize.width - layerWidth / 2
      yPos = videoSize.height - (CGFloat(opts.y) * videoSize.height) - layerHeight / 2
    }

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

    // 0.11.0 — soft halo. CALayer's shadow draws OUTSIDE the layer
    // bounds, so it bleeds tastefully into the surrounding video.
    // masksToBounds (used by cornerRadius) clips the shadow, so when
    // both are requested we forfeit the corner-radius clipping. The
    // text-stroke happens inside the layer so it's unaffected.
    if let shadowStr = opts.shadowColor,
       let shadow = UIColor(hexString: shadowStr),
       opts.shadowRadius > 0 {
      textLayer.shadowColor = shadow.cgColor
      textLayer.shadowRadius = CGFloat(opts.shadowRadius) * scale
      textLayer.shadowOpacity = Float(max(0, min(1, opts.shadowOpacity)))
      textLayer.shadowOffset = .zero
      if opts.cornerRadius > 0 { textLayer.masksToBounds = false }
    }

    applyTimingAnimation(to: textLayer, startMs: opts.startMs, endMs: opts.endMs, duration: duration)

    // Wrap in a container so rotation is applied around the text center
    if opts.rotation != 0 {
      let radians = CGFloat(opts.rotation) * .pi / 180
      let container = CALayer()
      container.frame = textLayer.frame
      textLayer.frame = CGRect(origin: .zero, size: textLayer.frame.size)
      container.addSublayer(textLayer)
      container.transform = CATransform3DMakeRotation(radians, 0, 0, 1)
      applyTimingAnimation(to: container, startMs: opts.startMs, endMs: opts.endMs, duration: duration)
      return container
    }

    return textLayer
  }

  private static func buildImageLayer(
    opts: ImageOverlayOptions,
    videoSize: CGSize,
    duration: CMTime
  ) -> CALayer? {
    guard !opts.uri.contains("../") else { return nil }
    let filePath = opts.uri.hasPrefix("file://")
      ? opts.uri.replacingOccurrences(of: "file://", with: "")
      : opts.uri
    guard let image = UIImage(contentsOfFile: filePath) else { return nil }

    let layerWidth = CGFloat(opts.width) * videoSize.width
    let layerHeight = CGFloat(opts.height) * videoSize.height
    let xPos = CGFloat(opts.x) * videoSize.width
    let yPos = videoSize.height - (CGFloat(opts.y) * videoSize.height) - layerHeight

    let imageLayer = CALayer()
    imageLayer.contents = image.cgImage
    imageLayer.contentsGravity = .resizeAspect
    imageLayer.opacity = Float(opts.opacity)
    imageLayer.frame = CGRect(x: xPos, y: yPos, width: layerWidth, height: layerHeight)

    applyTimingAnimation(to: imageLayer, startMs: opts.startMs, endMs: opts.endMs, duration: duration)

    return imageLayer
  }

  private static func applyTimingAnimation(
    to layer: CALayer,
    startMs: Double?,
    endMs: Double?,
    duration: CMTime
  ) {
    guard startMs != nil || endMs != nil else { return }

    let totalDuration = CMTimeGetSeconds(duration)
    let start = (startMs ?? 0) / 1000.0
    let end = endMs.map { $0 / 1000.0 } ?? totalDuration

    // Keyframe animation: invisible → visible at startMs, invisible again at endMs
    let animation = CAKeyframeAnimation(keyPath: "opacity")
    animation.duration = totalDuration
    animation.keyTimes = [
      0,
      NSNumber(value: start / totalDuration),
      NSNumber(value: end / totalDuration),
      1
    ]
    // discrete mode: values[i] is held from keyTimes[i] until keyTimes[i+1].
    // After endMs we want the layer hidden, so values[2] must be 0 (not opacity).
    animation.values = [0, layer.opacity, 0, 0]
    animation.calculationMode = .discrete
    animation.isRemovedOnCompletion = false
    animation.fillMode = .both
    // AVVideoCompositionCoreAnimationTool requires this special value so the
    // animation references composition time, not CACurrentMediaTime().
    animation.beginTime = AVCoreAnimationBeginTimeAtZero
    layer.add(animation, forKey: "timing")
    // Start hidden if there's a start offset
    if start > 0 { layer.opacity = 0 }
  }
}

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
