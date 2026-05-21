import ExpoModulesCore
import AVFoundation

public class ExpoMediaEditModule: Module {
  private var activeExportSession: AVAssetExportSession?
  private var progressTimer: Timer?

  public func definition() -> ModuleDefinition {
    Name("ExpoMediaEdit")

    Events("onProgress")

    AsyncFunction("editVideo") { (jobDict: [String: Any], promise: Promise) in
      let outputURL: URL
      if let outputUriStr = jobDict["outputUri"] as? String, let url = URL(string: outputUriStr) {
        outputURL = url
      } else {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("expo-media-edit")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        outputURL = tempDir.appendingPathComponent(UUID().uuidString + ".mp4")
      }

      let job = EditJobOptions(dict: jobDict)

      let onProgress: (Float) -> Void = { [weak self] p in
        self?.sendEvent("onProgress", ["progress": p])
      }
      let onSessionReady: (AVAssetExportSession) -> Void = { [weak self] session in
        self?.activeExportSession = session
        DispatchQueue.main.async {
          self?.progressTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let s = self?.activeExportSession else { return }
            self?.sendEvent("onProgress", ["progress": s.progress])
          }
        }
      }
      let completion: (Result<URL, Error>) -> Void = { [weak self] result in
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
            let msg = error.localizedDescription
            if msg.contains("CANCELLED") || msg.contains("cancelled") {
              promise.reject("CANCELLED", "Export was cancelled")
            } else {
              promise.reject("EDIT_FAILED", msg)
            }
          }
        }
      }

      if let playlist = job.playlist, playlist.count > 1 || playlist.first?.isImage == true {
        VideoEditor().editPlaylist(
          playlist: playlist,
          outputURL: outputURL,
          job: job,
          onProgress: onProgress,
          onSessionReady: onSessionReady,
          completion: completion
        )
      } else {
        // Single-video fast path
        guard let firstItem = job.playlist?.first, case .video(let v) = firstItem,
              let inputURL = URL(string: v.uri) else {
          promise.reject("INVALID_INPUT", "No valid video item in playlist")
          return
        }
        let singleJob = EditJobOptions(inputURL: inputURL, trim: v.trim, overlays: job.overlays, audio: job.audio, quality: job.quality)
        VideoEditor().edit(
          inputURL: inputURL,
          outputURL: outputURL,
          job: singleJob,
          onSessionReady: onSessionReady,
          completion: completion
        )
      }
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

      // Apply preferredTransform so width/height reflect the rendered orientation
      // (portrait clips have a 90° transform; natural is 1920×1080, rendered 1080×1920)
      var width = Double(track?.naturalSize.width ?? 0)
      var height = Double(track?.naturalSize.height ?? 0)
      if let t = track {
        let rendered = t.naturalSize.applying(t.preferredTransform)
        width = Double(abs(rendered.width))
        height = Double(abs(rendered.height))
      }

      // Extract codec from format descriptions for parity with Android
      var codec: String? = nil
      if let formatDescs = track?.formatDescriptions as? [CMFormatDescription],
         let first = formatDescs.first {
        let fourCC = CMFormatDescriptionGetMediaSubType(first)
        codec = String(format: "%c%c%c%c",
                       (fourCC >> 24) & 0xff,
                       (fourCC >> 16) & 0xff,
                       (fourCC >> 8) & 0xff,
                       fourCC & 0xff)
      }

      var result: [String: Any] = [
        "durationMs": CMTimeGetSeconds(asset.duration) * 1000.0,
        "width": width,
        "height": height,
        "fps": Double(track?.nominalFrameRate ?? 0),
        "fileSize": fileSize
      ]
      if let c = codec { result["codec"] = c }
      promise.resolve(result)
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

    AsyncFunction("extractAudio") { (uri: String, promise: Promise) in
      guard let url = URL(string: uri) else {
        promise.reject("INVALID_URI", "uri is not a valid URL")
        return
      }
      let asset = AVAsset(url: url)
      guard !asset.tracks(withMediaType: .audio).isEmpty else {
        promise.reject("NO_AUDIO_TRACK", "Source has no audio track")
        return
      }
      guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
        promise.reject("EXPORT_INIT_FAILED", "Could not create AVAssetExportSession")
        return
      }
      let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("expo-media-edit")
      try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
      let outputURL = tempDir.appendingPathComponent(UUID().uuidString + ".m4a")
      exporter.outputURL = outputURL
      exporter.outputFileType = .m4a
      exporter.exportAsynchronously {
        switch exporter.status {
        case .completed:
          promise.resolve(outputURL.absoluteString)
        case .failed, .cancelled:
          promise.reject("EXTRACT_FAILED", exporter.error?.localizedDescription ?? "Audio extraction failed")
        default:
          promise.reject("EXTRACT_FAILED", "Unexpected exporter status: \(exporter.status.rawValue)")
        }
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
