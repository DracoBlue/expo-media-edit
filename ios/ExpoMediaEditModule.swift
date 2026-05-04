import ExpoModulesCore
import AVFoundation

public class ExpoMediaEditModule: Module {
  private var activeExportSession: AVAssetExportSession?
  private var progressTimer: Timer?

  public func definition() -> ModuleDefinition {
    Name("ExpoMediaEdit")

    Events("onProgress")

    AsyncFunction("editVideo") { (inputUri: String, jobDict: [String: Any], promise: Promise) in
      guard let inputURL = URL(string: inputUri) else {
        promise.reject("INVALID_URI", "inputUri is not a valid URL")
        return
      }

      let outputURL: URL
      if let outputUriStr = jobDict["outputUri"] as? String, let url = URL(string: outputUriStr) {
        outputURL = url
      } else {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("expo-media-edit")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        outputURL = tempDir.appendingPathComponent(UUID().uuidString + ".mp4")
      }

      let job = EditJobOptions(dict: jobDict)
      VideoEditor().edit(
        inputURL: inputURL,
        outputURL: outputURL,
        job: job,
        onSessionReady: { [weak self] session in
          self?.activeExportSession = session
          DispatchQueue.main.async {
            self?.progressTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
              guard let s = self?.activeExportSession else { return }
              self?.sendEvent("onProgress", ["progress": s.progress])
            }
          }
        },
        completion: { [weak self] result in
          DispatchQueue.main.async {
            self?.progressTimer?.invalidate()
            self?.progressTimer = nil
            self?.activeExportSession = nil
          }
          switch result {
          case .success(let url):
            self?.sendEvent("onProgress", ["progress": 1.0])
            promise.resolve(url.absoluteString)
          case .failure(let error):
            if (error as NSError).domain == AVFoundationErrorDomain &&
               (error as NSError).code == AVError.exportFailed.rawValue {
              promise.reject("CANCELLED", "Export was cancelled")
            } else {
              promise.reject("EDIT_FAILED", error.localizedDescription)
            }
          }
        }
      )
    }

    AsyncFunction("cancelEdit") { (promise: Promise) in
      self.activeExportSession?.cancelExport()
      promise.resolve(nil)
    }

    AsyncFunction("getVideoInfo") { (uri: String, promise: Promise) in
      guard let url = URL(string: uri) else {
        promise.reject("INVALID_URI", "uri is not a valid URL")
        return
      }
      let asset = AVAsset(url: url)
      let track = asset.tracks(withMediaType: .video).first
      let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      promise.resolve([
        "durationMs": CMTimeGetSeconds(asset.duration) * 1000.0,
        "width": Double(track?.naturalSize.width ?? 0),
        "height": Double(track?.naturalSize.height ?? 0),
        "fps": Double(track?.nominalFrameRate ?? 0),
        "fileSize": fileSize
      ])
    }

    AsyncFunction("generateThumbnail") { (uri: String, timeMs: Double, options: [String: Any]?, promise: Promise) in
      guard let url = URL(string: uri) else {
        promise.reject("INVALID_URI", "uri is not a valid URL")
        return
      }
      let asset = AVAsset(url: url)
      let generator = AVAssetImageGenerator(asset: asset)
      generator.appliesPreferredTrackTransform = true

      if let w = options?["width"] as? Double, let h = options?["height"] as? Double {
        generator.maximumSize = CGSize(width: w, height: h)
      }

      let time = CMTime(value: CMTimeValue(timeMs), timescale: 1000)
      do {
        let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
        let image = UIImage(cgImage: cgImage)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("expo-media-edit")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let outputURL = tempDir.appendingPathComponent(UUID().uuidString + ".jpg")
        if let data = image.jpegData(compressionQuality: 0.8) {
          try data.write(to: outputURL)
          promise.resolve(outputURL.absoluteString)
        } else {
          promise.reject("THUMBNAIL_FAILED", "Could not encode thumbnail as JPEG")
        }
      } catch {
        promise.reject("THUMBNAIL_FAILED", error.localizedDescription)
      }
    }

    AsyncFunction("cleanTempFiles") { (promise: Promise) in
      let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("expo-media-edit")
      let files = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
      var count = 0
      files?.forEach { url in
        if (try? FileManager.default.removeItem(at: url)) != nil { count += 1 }
      }
      promise.resolve(count)
    }
  }
}
