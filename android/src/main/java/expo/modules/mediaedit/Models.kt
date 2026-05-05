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
  val fontSize: Float,
  val color: String,
  val fontWeight: String,
  val backgroundColor: String?,
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
            overlays.add(OverlayItem.Text(TextOverlayItem(
              content = content,
              x = (o["x"] as? Number)?.toFloat() ?: 0f,
              y = (o["y"] as? Number)?.toFloat() ?: 0f,
              fontSize = (o["fontSize"] as? Number)?.toFloat() ?: 32f,
              color = o["color"] as? String ?: "#FFFFFF",
              fontWeight = o["fontWeight"] as? String ?: "normal",
              backgroundColor = o["backgroundColor"] as? String,
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
        if (uri.contains("../")) return@let null
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
