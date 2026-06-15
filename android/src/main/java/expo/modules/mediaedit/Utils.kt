package expo.modules.mediaedit

import android.content.Context
import android.net.Uri
import java.io.File

fun createTempFile(context: Context, prefix: String, suffix: String): File {
  val tempDir = File(context.cacheDir, "expo-media-edit")
  tempDir.mkdirs()
  return File(tempDir, "$prefix-${System.currentTimeMillis()}-${(Math.random() * 100000).toInt()}$suffix")
}

/**
 * Native security boundary for read sources crossing the JS↔native bridge.
 * The JS layer enforces the same rules, but it can be bypassed by calling the
 * native module directly, so this is the source of truth.
 */
fun isReadableUriAllowed(uri: String): Boolean {
  if (uri.contains('\u0000')) return false
  if (uri.contains("../")) return false
  return uri.startsWith("file://") || uri.startsWith("https://")
}

/**
 * Resolves an output `file://` URI to a File, but only if its canonical path
 * stays inside one of the app's writable sandbox directories. Returns null
 * otherwise — this defeats absolute-path escapes (e.g. file:///data/data/...)
 * that a plain "../" substring check misses, and prevents arbitrary file
 * overwrite/delete via outputUri.
 */
fun resolveAllowedOutputFile(context: Context, outputUri: String): File? {
  if (outputUri.contains('\u0000') || outputUri.contains("../")) return null
  val parsed = Uri.parse(outputUri)
  if (parsed.scheme != "file") return null
  val path = parsed.path ?: return null

  val target = try { File(path).canonicalPath } catch (e: Exception) { return null }
  val bases = listOfNotNull(
    context.cacheDir,
    context.filesDir,
    context.getExternalFilesDir(null),
    context.externalCacheDir
  )
  val allowed = bases.any { base ->
    val basePath = try { base.canonicalPath } catch (e: Exception) { return@any false }
    target == basePath || target.startsWith(basePath + File.separator)
  }
  return if (allowed) File(target) else null
}
