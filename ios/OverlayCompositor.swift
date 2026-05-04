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

  private static func buildTextLayer(
    opts: TextOverlayOptions,
    videoSize: CGSize,
    duration: CMTime
  ) -> CALayer {
    let fontSize = CGFloat(opts.fontSize)
    let layerWidth = videoSize.width * 0.9
    let layerHeight = fontSize * 2.5

    // CALayer Y is inverted: y=0 is bottom in Core Animation
    let xPos = CGFloat(opts.x) * videoSize.width
    let yPos = videoSize.height - (CGFloat(opts.y) * videoSize.height) - layerHeight

    let textLayer = CATextLayer()
    textLayer.string = opts.content
    textLayer.fontSize = fontSize
    textLayer.foregroundColor = UIColor(hexString: opts.color)?.cgColor ?? UIColor.white.cgColor
    textLayer.alignmentMode = .left
    textLayer.isWrapped = true
    textLayer.contentsScale = UIScreen.main.scale
    textLayer.frame = CGRect(x: xPos, y: yPos, width: layerWidth, height: layerHeight)

    if opts.fontWeight == "bold" {
      textLayer.font = UIFont.boldSystemFont(ofSize: fontSize)
    }

    if let bgColorStr = opts.backgroundColor,
       let bgColor = UIColor(hexString: bgColorStr) {
      textLayer.backgroundColor = bgColor.cgColor
    }

    applyTimingAnimation(to: textLayer, startMs: opts.startMs, endMs: opts.endMs, duration: duration)

    return textLayer
  }

  private static func buildImageLayer(
    opts: ImageOverlayOptions,
    videoSize: CGSize,
    duration: CMTime
  ) -> CALayer? {
    let filePath = opts.uri.replacingOccurrences(of: "file://", with: "")
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
