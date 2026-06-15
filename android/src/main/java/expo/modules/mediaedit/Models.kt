package expo.modules.mediaedit

data class TrimOptions(val startMs: Long, val endMs: Long)

// Playlist types (0.4.0)
sealed class TransitionConfig {
  object Cut : TransitionConfig()
  data class Fade(val durationMs: Long) : TransitionConfig()
  data class FadeToBlack(val durationMs: Long) : TransitionConfig()
  data class Slide(val durationMs: Long, val direction: String) : TransitionConfig()
}

sealed class PlaylistItemConfig {
  data class VideoItem(val uri: String, val trim: TrimOptions?, val transition: TransitionConfig) : PlaylistItemConfig()
  data class ImageItem(val uri: String, val durationMs: Long, val transition: TransitionConfig) : PlaylistItemConfig()
}

data class TextOverlayItem(
  val content: String,
  val x: Float,
  val y: Float,
  val anchor: String,        // "topLeft" | "center"
  val textAlign: String,     // "left" | "center" | "right"
  val paddingX: Float,       // px at 1080-height reference
  val paddingY: Float,       // px at 1080-height reference
  val fontSize: Float,
  val color: String,
  val fontWeight: String,
  val fontStyle: String,     // "normal" | "italic" — 0.11.0
  val fontFamily: String,    // "system" | "monospace" — 0.11.0
  val backgroundColor: String?,
  val cornerRadius: Float,  // px at 1080-height reference
  // 0.11.0 — optional outline (color + width required to render)
  val strokeColor: String?,
  val strokeWidth: Float,    // 0 = no stroke
  // 0.11.0 — optional soft halo (color + radius required to render)
  val shadowColor: String?,
  val shadowRadius: Float,   // 0 = no shadow
  val shadowOpacity: Float,  // 0..1
  // 0.11.0 — first-occurrence substring highlight
  val highlightWord: String?,
  val highlightColor: String?,
  val rotation: Float,  // degrees, default 0
  val startMs: Long?,
  val endMs: Long?
)

data class ImageOverlayItem(
  val uri: String,
  val x: Float,
  val y: Float,
  val width: Float,
  val height: Float,
  val opacity: Float,
  val startMs: Long?,
  val endMs: Long?
)

sealed class OverlayItem {
  data class Text(val opts: TextOverlayItem) : OverlayItem()
  data class Image(val opts: ImageOverlayItem) : OverlayItem()
}

data class AudioMixOptions(
  val uri: String,
  val volume: Float,
  val originalVolume: Float,
  val startMs: Long,
  val trimToVideo: Boolean
)

data class EditJob(
  val outputUri: String?,
  val trim: TrimOptions?,
  val overlays: List<OverlayItem>,
  val audio: AudioMixOptions?,
  val quality: String,
  val playlist: List<PlaylistItemConfig>?
) {
  companion object {
    @Suppress("UNCHECKED_CAST")
    fun fromMap(map: Map<String, Any?>): EditJob {
      val outputUri = map["outputUri"] as? String
      val quality = map["quality"] as? String ?: "high"

      val trim = (map["trim"] as? Map<String, Any?>)?.let { t ->
        TrimOptions(
          startMs = (t["startMs"] as? Number)?.toLong() ?: 0L,
          endMs = (t["endMs"] as? Number)?.toLong() ?: 0L
        )
      }

      val playlist = (map["playlist"] as? List<Map<String, Any?>>)?.mapIndexedNotNull { i, p ->
        val uri = p["uri"] as? String ?: return@mapIndexedNotNull null
        if (uri.contains("../") || (!uri.startsWith("file://") && !uri.startsWith("https://"))) return@mapIndexedNotNull null
        val transition = parseTransition(p["transition"] as? Map<String, Any?>, isFirst = i == 0)
        when (p["type"] as? String) {
          "video" -> {
            val t = (p["trim"] as? Map<String, Any?>)?.let { td ->
              TrimOptions((td["startMs"] as? Number)?.toLong() ?: 0L, (td["endMs"] as? Number)?.toLong() ?: 0L)
            }
            PlaylistItemConfig.VideoItem(uri, t, transition)
          }
          "image" -> PlaylistItemConfig.ImageItem(uri, (p["durationMs"] as? Number)?.toLong() ?: 3000L, transition)
          else -> null
        }
      }?.takeIf { it.isNotEmpty() }

      val overlays = mutableListOf<OverlayItem>()
      (map["overlays"] as? List<Map<String, Any?>>)?.forEach { o ->
        when (o["type"] as? String) {
          "text" -> {
            val content = o["content"] as? String ?: return@forEach
            // 0.8.0: anchor / textAlign / paddingX / paddingY are required — skip silently if missing.
            val anchor = o["anchor"] as? String ?: return@forEach
            if (anchor != "topLeft" && anchor != "center") return@forEach
            val textAlign = o["textAlign"] as? String ?: return@forEach
            if (textAlign != "left" && textAlign != "center" && textAlign != "right") return@forEach
            val paddingX = (o["paddingX"] as? Number)?.toFloat() ?: return@forEach
            val paddingY = (o["paddingY"] as? Number)?.toFloat() ?: return@forEach
            overlays.add(OverlayItem.Text(TextOverlayItem(
              content = content,
              x = (o["x"] as? Number)?.toFloat() ?: 0f,
              y = (o["y"] as? Number)?.toFloat() ?: 0f,
              anchor = anchor,
              textAlign = textAlign,
              paddingX = paddingX,
              paddingY = paddingY,
              fontSize = (o["fontSize"] as? Number)?.toFloat() ?: 32f,
              color = o["color"] as? String ?: "#FFFFFF",
              fontWeight = o["fontWeight"] as? String ?: "normal",
              fontStyle = o["fontStyle"] as? String ?: "normal",
              fontFamily = o["fontFamily"] as? String ?: "system",
              backgroundColor = o["backgroundColor"] as? String,
              cornerRadius = (o["cornerRadius"] as? Number)?.toFloat() ?: 0f,
              strokeColor = o["strokeColor"] as? String,
              strokeWidth = (o["strokeWidth"] as? Number)?.toFloat() ?: 0f,
              shadowColor = o["shadowColor"] as? String,
              shadowRadius = (o["shadowRadius"] as? Number)?.toFloat() ?: 0f,
              shadowOpacity = (o["shadowOpacity"] as? Number)?.toFloat() ?: 1f,
              highlightWord = o["highlightWord"] as? String,
              highlightColor = o["highlightColor"] as? String,
              rotation = (o["rotation"] as? Number)?.toFloat() ?: 0f,
              startMs = (o["startMs"] as? Number)?.toLong(),
              endMs = (o["endMs"] as? Number)?.toLong()
            )))
          }
          "image" -> {
            val uri = o["uri"] as? String ?: return@forEach
            if (uri.contains("../") || (!uri.startsWith("file://") && !uri.startsWith("https://"))) return@forEach
            overlays.add(OverlayItem.Image(ImageOverlayItem(
              uri = uri,
              x = (o["x"] as? Number)?.toFloat() ?: 0f,
              y = (o["y"] as? Number)?.toFloat() ?: 0f,
              width = (o["width"] as? Number)?.toFloat() ?: 0.2f,
              height = (o["height"] as? Number)?.toFloat() ?: 0.2f,
              opacity = (o["opacity"] as? Number)?.toFloat() ?: 1f,
              startMs = (o["startMs"] as? Number)?.toLong(),
              endMs = (o["endMs"] as? Number)?.toLong()
            )))
          }
        }
      }

      val audio = (map["audio"] as? Map<String, Any?>)?.let { a ->
        val uri = a["uri"] as? String ?: return@let null
        if (uri.contains("../") || (!uri.startsWith("file://") && !uri.startsWith("https://"))) return@let null
        AudioMixOptions(
          uri = uri,
          volume = (a["volume"] as? Number)?.toFloat() ?: 1f,
          originalVolume = (a["originalVolume"] as? Number)?.toFloat() ?: 0f,
          startMs = (a["startMs"] as? Number)?.toLong() ?: 0L,
          trimToVideo = a["trimToVideo"] as? Boolean ?: true
        )
      }

      return EditJob(outputUri = outputUri, trim = trim, overlays = overlays, audio = audio, quality = quality, playlist = playlist)
    }

    private fun parseTransition(d: Map<String, Any?>?, isFirst: Boolean): TransitionConfig {
      if (isFirst || d == null) return TransitionConfig.Cut
      return when (d["type"] as? String) {
        "fade" -> TransitionConfig.Fade((d["durationMs"] as? Number)?.toLong() ?: 500L)
        "fadeToBlack" -> TransitionConfig.FadeToBlack((d["durationMs"] as? Number)?.toLong() ?: 500L)
        "slide" -> TransitionConfig.Slide((d["durationMs"] as? Number)?.toLong() ?: 500L, d["direction"] as? String ?: "left")
        else -> TransitionConfig.Cut
      }
    }
  }
}
