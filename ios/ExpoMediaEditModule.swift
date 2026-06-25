import ExpoModulesCore
import AVFoundation

public class ExpoMediaEditModule: Module {
  private var activeExporter: ProjectExporter?

  public func definition() -> ModuleDefinition {
    Name("ExpoMediaEdit")

    Events("onProgress")

    // MARK: - exportProject(project, outputUri?, opts?)
    //
    // Replaces the 0.13.x editVideo(job). Takes a Project dict (same
    // shape as src/project.ts), compiles it via ProjectCompiler, and
    // runs the result through ProjectExporter to an MP4 on disk.
    AsyncFunction("exportProject") { (projectDict: [String: Any], outputUri: String?, opts: [String: Any]?, promise: Promise) in
      let outputURL: URL
      if let uri = outputUri, !uri.isEmpty {
        guard let url = URL(string: uri), MediaEditSecurity.isOutputURLAllowed(url) else {
          promise.reject("INVALID_OUTPUT", "outputUri must be a file:// path inside the app's sandbox")
          return
        }
        outputURL = url
      } else {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("expo-media-edit")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        outputURL = tempDir.appendingPathComponent(UUID().uuidString + ".mp4")
      }

      let quality = (opts?["quality"] as? String) ?? "high"

      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        guard let self = self else { return }
        let compiled: CompiledComposition
        do {
          let project = try ProjectParser.parse(projectDict)
          compiled = try ProjectCompiler.compile(project, mode: .export)
        } catch {
          promise.reject("COMPILE_FAILED", "\(error)")
          return
        }

        let exporter = ProjectExporter()
        self.activeExporter = exporter
        exporter.export(
          compiled: compiled,
          outputURL: outputURL,
          quality: quality,
          onProgress: { [weak self] p in
            self?.sendEvent("onProgress", ["progress": p])
          },
          completion: { [weak self] result in
            self?.activeExporter = nil
            switch result {
            case .success(let url):
              promise.resolve(url.absoluteString)
            case .failure(let err):
              let nsErr = err as NSError
              let msg = nsErr.localizedDescription
              if msg.contains("cancelled") || msg.contains("Cancelled") {
                promise.reject("CANCELLED", msg)
              } else {
                promise.reject("EXPORT_FAILED", msg)
              }
            }
          }
        )
      }
    }

    AsyncFunction("cancelExport") { (promise: Promise) in
      self.activeExporter?.cancel()
      promise.resolve(nil)
    }

    // MARK: - getVideoInfo / generateThumbnail / extractAudio / cleanTempFiles
    //
    // Unchanged from 0.13.x — these are independent of the composer
    // and operate on individual files.

    AsyncFunction("getVideoInfo") { (uri: String, promise: Promise) in
      guard MediaEditSecurity.isReadableURIAllowed(uri) else {
        promise.reject("INVALID_URI", "uri must be a file:// or https:// URI without path traversal"); return
      }
      guard let url = URL(string: uri) else {
        promise.reject("INVALID_URI", "uri is not a valid URL"); return
      }
      let asset = AVAsset(url: url)
      let track = asset.tracks(withMediaType: .video).first
      let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

      var width = Double(track?.naturalSize.width ?? 0)
      var height = Double(track?.naturalSize.height ?? 0)
      if let t = track {
        let rendered = t.naturalSize.applying(t.preferredTransform)
        width = Double(abs(rendered.width))
        height = Double(abs(rendered.height))
      }

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
        "width": width, "height": height,
        "fps": Double(track?.nominalFrameRate ?? 0),
        "fileSize": fileSize,
      ]
      if let c = codec { result["codec"] = c }
      promise.resolve(result)
    }

    AsyncFunction("generateThumbnail") { (uri: String, timeMs: Double, options: [String: Any]?, promise: Promise) in
      guard MediaEditSecurity.isReadableURIAllowed(uri) else {
        promise.reject("INVALID_URI", "uri must be a file:// or https:// URI without path traversal"); return
      }
      guard let url = URL(string: uri) else {
        promise.reject("INVALID_URI", "uri is not a valid URL"); return
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
      guard MediaEditSecurity.isReadableURIAllowed(uri) else {
        promise.reject("INVALID_URI", "uri must be a file:// or https:// URI without path traversal"); return
      }
      guard let url = URL(string: uri) else {
        promise.reject("INVALID_URI", "uri is not a valid URL"); return
      }
      let asset = AVAsset(url: url)
      guard !asset.tracks(withMediaType: .audio).isEmpty else {
        promise.reject("NO_AUDIO_TRACK", "Source has no audio track"); return
      }
      guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
        promise.reject("EXPORT_INIT_FAILED", "Could not create AVAssetExportSession"); return
      }
      let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("expo-media-edit")
      try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
      let outputURL = tempDir.appendingPathComponent(UUID().uuidString + ".m4a")
      exporter.outputURL = outputURL
      exporter.outputFileType = .m4a
      exporter.exportAsynchronously {
        switch exporter.status {
        case .completed: promise.resolve(outputURL.absoluteString)
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

    // MARK: - <MediaPreview /> view
    //
    // Native view component. Receives `project` JSON, `time`,
    // `playing`, optional `renderScale`. Emits `onTime`, `onReady`,
    // `onError`. Internally builds an AVPlayer fed by the same
    // ProjectCompiler output that the exporter uses → preview pixels
    // == export pixels.
    View(MediaPreviewView.self) {
      Events("onTime", "onReady", "onError")

      Prop("project") { (view: MediaPreviewView, project: [String: Any]) in
        view.updateProject(project)
      }
      Prop("time") { (view: MediaPreviewView, time: Double) in
        view.updateTime(time)
      }
      Prop("playing") { (view: MediaPreviewView, playing: Bool) in
        view.updatePlaying(playing)
      }
      Prop("renderScale") { (view: MediaPreviewView, scale: Double) in
        view.updateRenderScale(scale)
      }
    }
  }
}
