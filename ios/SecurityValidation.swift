import Foundation

/// Native security boundary for URIs crossing the JS↔native bridge.
///
/// The JS layer performs the same syntactic checks, but it can be bypassed by
/// calling the native module directly, so these are enforced here as the source
/// of truth. Output paths are additionally confined to the app's writable
/// sandbox directories after canonicalization, which defeats absolute-path
/// escapes that a plain "../" substring check misses.
enum MediaEditSecurity {

  /// Read sources may be a local file or an https URL. No path traversal, no null bytes.
  static func isReadableURIAllowed(_ uri: String) -> Bool {
    if uri.contains("\0") { return false }
    if uri.contains("../") { return false }
    return uri.hasPrefix("file://") || uri.hasPrefix("https://")
  }

  /// Output must be a file:// URL whose resolved path stays inside one of the
  /// app's writable sandbox directories (temp, caches, documents, app support).
  static func isOutputURLAllowed(_ url: URL) -> Bool {
    guard url.isFileURL else { return false }
    if url.path.contains("\0") { return false }

    let fm = FileManager.default
    let targetPath = url.standardizedFileURL.resolvingSymlinksInPath().path

    var bases: [URL] = [fm.temporaryDirectory]
    for dir in [FileManager.SearchPathDirectory.cachesDirectory,
                .documentDirectory,
                .applicationSupportDirectory] {
      if let u = fm.urls(for: dir, in: .userDomainMask).first {
        bases.append(u)
      }
    }

    for base in bases {
      let basePath = base.standardizedFileURL.resolvingSymlinksInPath().path
      if targetPath == basePath || targetPath.hasPrefix(basePath + "/") {
        return true
      }
    }
    return false
  }
}
