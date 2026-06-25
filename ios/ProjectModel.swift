import Foundation
import AVFoundation

/// Swift-side mirror of TypeScript Project (src/project.ts). All
/// fields are pure data — nothing here owns AV objects. Both the
/// compiler and the preview view parse a project dictionary once at
/// the bridge boundary and then operate on these structs.

public struct ProjectTimeRange {
  public let startMs: Double
  public let endMs: Double
  public var startTime: CMTime { CMTime(value: CMTimeValue(startMs), timescale: 1000) }
  public var endTime: CMTime { CMTime(value: CMTimeValue(endMs), timescale: 1000) }
  public var duration: CMTime { endTime - startTime }
  public var durationMs: Double { endMs - startMs }
}

public enum ProjectClipTransition {
  case cut
  case fade(durationMs: Double)
  case fadeToBlack(durationMs: Double)
}

public struct ProjectVideoClip {
  public let id: String
  public let sourceUri: String
  public let sourceRange: ProjectTimeRange
  public let timelineRange: ProjectTimeRange
  public let transition: ProjectClipTransition
  public let originalVolume: Double
  /// `kind == "image"` when the source is a still image that needs to
  /// be expanded into a time-bounded AVAsset. Default false.
  public let isImage: Bool
  public let imageDurationMs: Double?
}

public struct ProjectAudioClip {
  public let id: String
  public let sourceUri: String
  public let sourceRange: ProjectTimeRange
  public let timelineRange: ProjectTimeRange
  public let volume: Double
  public let trimToVideo: Bool
}

public enum ProjectOverlayClip {
  case text(ProjectTextOverlayClip)
  case image(ProjectImageOverlayClip)
}

public struct ProjectTextOverlayClip {
  public let id: String
  public let content: String
  public let x: Double
  public let y: Double
  public let anchor: String       // "topLeft" | "center"
  public let textAlign: String    // "left" | "center" | "right"
  public let paddingX: Double
  public let paddingY: Double
  public let fontSize: Double
  public let color: String
  public let fontWeight: String
  public let fontStyle: String
  public let fontFamily: String
  public let backgroundColor: String?
  public let cornerRadius: Double
  public let strokeColor: String?
  public let strokeWidth: Double
  public let shadowColor: String?
  public let shadowRadius: Double
  public let shadowOpacity: Double
  public let highlightColor: String?
  public let highlightStart: Int?
  public let highlightLength: Int?
  public let rotation: Double
  public let timelineRange: ProjectTimeRange?
}

public struct ProjectImageOverlayClip {
  public let id: String
  public let uri: String
  public let x: Double
  public let y: Double
  public let width: Double
  public let height: Double
  public let opacity: Double
  public let rotation: Double
  public let timelineRange: ProjectTimeRange?
}

public enum ProjectTrack {
  case video(id: String, clips: [ProjectVideoClip])
  case audio(id: String, clips: [ProjectAudioClip])
  case overlay(id: String, items: [ProjectOverlayClip])
}

public struct Project {
  public let id: String
  public let schemaVersion: Int
  public let canvasSize: CGSize
  public let fps: Int
  public let durationMs: Double
  public let tracks: [ProjectTrack]
}

// MARK: - Parsing from the JS bridge dict

public enum ProjectParseError: Error {
  case invalid(String)
}

public struct ProjectParser {

  public static func parse(_ dict: [String: Any]) throws -> Project {
    guard let id = dict["id"] as? String else { throw ProjectParseError.invalid("missing id") }
    let schemaVersion = (dict["schemaVersion"] as? Int) ?? (dict["schemaVersion"] as? Double).map { Int($0) } ?? 1
    guard schemaVersion == 1 else { throw ProjectParseError.invalid("unsupported schemaVersion \(schemaVersion)") }
    guard let canvasDict = dict["canvasSize"] as? [String: Any],
          let w = (canvasDict["width"] as? Double) ?? (canvasDict["width"] as? Int).map(Double.init),
          let h = (canvasDict["height"] as? Double) ?? (canvasDict["height"] as? Int).map(Double.init) else {
      throw ProjectParseError.invalid("invalid canvasSize")
    }
    let fps = (dict["fps"] as? Int) ?? (dict["fps"] as? Double).map { Int($0) } ?? 30
    let durationMs = (dict["durationMs"] as? Double) ?? 0
    let trackArr = (dict["tracks"] as? [[String: Any]]) ?? []
    let tracks = try trackArr.map { try parseTrack($0) }
    return Project(
      id: id, schemaVersion: schemaVersion,
      canvasSize: CGSize(width: w, height: h),
      fps: fps, durationMs: durationMs, tracks: tracks
    )
  }

  private static func parseTrack(_ d: [String: Any]) throws -> ProjectTrack {
    guard let kind = d["kind"] as? String, let id = d["id"] as? String else {
      throw ProjectParseError.invalid("track missing kind/id")
    }
    switch kind {
    case "video":
      let clipDicts = (d["clips"] as? [[String: Any]]) ?? []
      let clips = try clipDicts.map { try parseVideoClip($0) }
      return .video(id: id, clips: clips)
    case "audio":
      let clipDicts = (d["clips"] as? [[String: Any]]) ?? []
      let clips = try clipDicts.map { try parseAudioClip($0) }
      return .audio(id: id, clips: clips)
    case "overlay":
      let itemDicts = (d["items"] as? [[String: Any]]) ?? []
      let items = try itemDicts.map { try parseOverlay($0) }
      return .overlay(id: id, items: items)
    default:
      throw ProjectParseError.invalid("unknown track kind \(kind)")
    }
  }

  private static func parseVideoClip(_ d: [String: Any]) throws -> ProjectVideoClip {
    let id = (d["id"] as? String) ?? UUID().uuidString
    let kind = d["kind"] as? String   // "image" marks an image-clip inside a video track
    let isImage = kind == "image"
    let sourceUri = (d["sourceUri"] as? String) ?? ""
    guard !sourceUri.isEmpty || isImage else { throw ProjectParseError.invalid("video clip \(id) missing sourceUri") }
    let imageDurationMs = d["durationMs"] as? Double
    let sourceRange = parseTimeRange(d["sourceRange"]) ?? ProjectTimeRange(startMs: 0, endMs: imageDurationMs ?? 0)
    guard let timelineRange = parseTimeRange(d["timelineRange"]) else {
      throw ProjectParseError.invalid("video clip \(id) missing timelineRange")
    }
    let transition = parseTransition(d["transition"] as? [String: Any])
    let originalVolume = (d["originalVolume"] as? Double) ?? 1.0
    let resolvedSourceUri = isImage ? (d["sourceUri"] as? String ?? "") : sourceUri
    return ProjectVideoClip(
      id: id, sourceUri: resolvedSourceUri,
      sourceRange: sourceRange, timelineRange: timelineRange,
      transition: transition, originalVolume: originalVolume,
      isImage: isImage, imageDurationMs: imageDurationMs
    )
  }

  private static func parseAudioClip(_ d: [String: Any]) throws -> ProjectAudioClip {
    let id = (d["id"] as? String) ?? UUID().uuidString
    guard let sourceUri = d["sourceUri"] as? String, !sourceUri.isEmpty else {
      throw ProjectParseError.invalid("audio clip \(id) missing sourceUri")
    }
    guard let sourceRange = parseTimeRange(d["sourceRange"]),
          let timelineRange = parseTimeRange(d["timelineRange"]) else {
      throw ProjectParseError.invalid("audio clip \(id) missing ranges")
    }
    let volume = (d["volume"] as? Double) ?? 1.0
    let trimToVideo = (d["trimToVideo"] as? Bool) ?? false
    return ProjectAudioClip(
      id: id, sourceUri: sourceUri,
      sourceRange: sourceRange, timelineRange: timelineRange,
      volume: volume, trimToVideo: trimToVideo
    )
  }

  private static func parseOverlay(_ d: [String: Any]) throws -> ProjectOverlayClip {
    guard let kind = d["kind"] as? String else { throw ProjectParseError.invalid("overlay missing kind") }
    let id = (d["id"] as? String) ?? UUID().uuidString
    let timelineRange = parseTimeRange(d["timelineRange"])
    if kind == "text" {
      return .text(ProjectTextOverlayClip(
        id: id,
        content: (d["content"] as? String) ?? "",
        x: (d["x"] as? Double) ?? 0,
        y: (d["y"] as? Double) ?? 0,
        anchor: (d["anchor"] as? String) ?? "center",
        textAlign: (d["textAlign"] as? String) ?? "center",
        paddingX: (d["paddingX"] as? Double) ?? 12,
        paddingY: (d["paddingY"] as? Double) ?? 8,
        fontSize: (d["fontSize"] as? Double) ?? 32,
        color: (d["color"] as? String) ?? "#FFFFFF",
        fontWeight: (d["fontWeight"] as? String) ?? "normal",
        fontStyle: (d["fontStyle"] as? String) ?? "normal",
        fontFamily: (d["fontFamily"] as? String) ?? "system",
        backgroundColor: d["backgroundColor"] as? String,
        cornerRadius: (d["cornerRadius"] as? Double) ?? 0,
        strokeColor: d["strokeColor"] as? String,
        strokeWidth: (d["strokeWidth"] as? Double) ?? 0,
        shadowColor: d["shadowColor"] as? String,
        shadowRadius: (d["shadowRadius"] as? Double) ?? 0,
        shadowOpacity: (d["shadowOpacity"] as? Double) ?? 1.0,
        highlightColor: d["highlightColor"] as? String,
        highlightStart: (d["highlightStart"] as? Double).map { Int($0) } ?? (d["highlightStart"] as? Int),
        highlightLength: (d["highlightLength"] as? Double).map { Int($0) } ?? (d["highlightLength"] as? Int),
        rotation: (d["rotation"] as? Double) ?? 0,
        timelineRange: timelineRange
      ))
    } else if kind == "image" {
      return .image(ProjectImageOverlayClip(
        id: id,
        uri: (d["uri"] as? String) ?? "",
        x: (d["x"] as? Double) ?? 0,
        y: (d["y"] as? Double) ?? 0,
        width: (d["width"] as? Double) ?? 0.2,
        height: (d["height"] as? Double) ?? 0.2,
        opacity: (d["opacity"] as? Double) ?? 1.0,
        rotation: (d["rotation"] as? Double) ?? 0,
        timelineRange: timelineRange
      ))
    } else {
      throw ProjectParseError.invalid("unknown overlay kind \(kind)")
    }
  }

  private static func parseTimeRange(_ raw: Any?) -> ProjectTimeRange? {
    guard let d = raw as? [String: Any],
          let s = d["startMs"] as? Double,
          let e = d["endMs"] as? Double else { return nil }
    return ProjectTimeRange(startMs: s, endMs: e)
  }

  private static func parseTransition(_ d: [String: Any]?) -> ProjectClipTransition {
    guard let d = d, let type = d["type"] as? String else { return .cut }
    switch type {
    case "fade": return .fade(durationMs: (d["durationMs"] as? Double) ?? 500)
    case "fadeToBlack": return .fadeToBlack(durationMs: (d["durationMs"] as? Double) ?? 500)
    default: return .cut
    }
  }
}
