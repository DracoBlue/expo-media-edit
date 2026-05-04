package expo.modules.mediaedit

import android.content.Context
import java.io.File

fun createTempFile(context: Context, prefix: String, suffix: String): File {
  val tempDir = File(context.cacheDir, "expo-media-edit")
  tempDir.mkdirs()
  return File(tempDir, "$prefix-${System.currentTimeMillis()}-${(Math.random() * 100000).toInt()}$suffix")
}
