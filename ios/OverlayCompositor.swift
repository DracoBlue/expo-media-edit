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

  private static func buildTextLayer(
    opts: TextOverlayOptions,
    videoSize: CGSize,
    duration: CMTime
  ) -> CALayer {
    // Scale fontSize consistently with Android (reference: 1080px height)
    let fontSize = CGFloat(opts.fontSize) * videoSize.height / 1080.0
    let maxWidth = videoSize.width * 0.9
    let isBold = opts.fontWeight == "bold"
    let uiFont: UIFont = isBold
      ? UIFont.boldSystemFont(ofSize: fontSize)
      : UIFont.systemFont(ofSize: fontSize)

    // Measure the rendered text so the layer (and its background) wraps tightly.
    let nsText = opts.content as NSString
    let measured = nsText.boundingRect(
      with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: [.font: uiFont],
      context: nil
    )
    // Scale paddings the same way fontSize is scaled (1080-height reference).
    let scale = videoSize.height / 1080.0
    let padH: CGFloat = CGFloat(opts.paddingX) * scale
    let padV: CGFloat = CGFloat(opts.paddingY) * scale
    let layerWidth = ceil(measured.width) + padH * 2
    let layerHeight = ceil(measured.height) + padV * 2

    // CALayer Y is inverted: y=0 is bottom in Core Animation.
    // Anchor interpretation:
    //   - "topLeft": (x, y) is the top-left corner of the layer.
    //   - "center":  (x, y) is the geometric center of the layer.
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
    textLayer.string = opts.content
    textLayer.fontSize = fontSize
    textLayer.foregroundColor = UIColor(hexString: opts.color)?.cgColor ?? UIColor.white.cgColor
    textLayer.alignmentMode = alignment
    textLayer.isWrapped = true
    textLayer.contentsScale = UIScreen.main.scale
    textLayer.frame = CGRect(x: xPos, y: yPos, width: layerWidth, height: layerHeight)
    // Vertically center text inside the layer by nudging via padding only — CATextLayer
    // draws from the top, so a tight layerHeight already centers because padV is applied
    // both above and below.

    if isBold {
      textLayer.font = uiFont
    }

    if let bgColorStr = opts.backgroundColor,
       let bgColor = UIColor(hexString: bgColorStr) {
      textLayer.backgroundColor = bgColor.cgColor
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
    animation.values = [0, layer.opacity, layer.opacity, 0]
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
