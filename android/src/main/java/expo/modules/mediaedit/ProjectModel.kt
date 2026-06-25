package expo.modules.mediaedit

/**
 * Kotlin mirror of the TypeScript Project schema in src/project.ts.
 * Both the compiler and the preview view parse the raw JS map once
 * at the bridge boundary and then operate on these structs.
 */

data class ProjectTimeRange(val startMs: Long, val endMs: Long) {
  val durationMs: Long get() = endMs - startMs
  val startUs: Long get() = startMs * 1000L
  val endUs: Long get() = endMs * 1000L
}

sealed class ProjectClipTransition {
  object Cut : ProjectClipTransition()
  data class Fade(val durationMs: Long) : ProjectClipTransition()
  data class FadeToBlack(val durationMs: Long) : ProjectClipTransition()
}

data class ProjectVideoClip(
  val id: String,
  val sourceUri: String,
  val sourceRange: ProjectTimeRange,
  val timelineRange: ProjectTimeRange,
  val transition: ProjectClipTransition,
  val originalVolume: Float,
  val isImage: Boolean,
  val imageDurationMs: Long?,
)

data class ProjectAudioClip(
  val id: String,
  val sourceUri: String,
  val sourceRange: ProjectTimeRange,
  val timelineRange: ProjectTimeRange,
  val volume: Float,
  val trimToVideo: Boolean,
)

sealed class ProjectOverlayClip {
  abstract val id: String
  abstract val timelineRange: ProjectTimeRange?

  data class Text(
    override val id: String,
    val content: String,
    val x: Float,
    val y: Float,
    val anchor: String,
    val textAlign: String,
    val paddingX: Float,
    val paddingY: Float,
    val fontSize: Float,
    val color: String,
    val fontWeight: String,
    val fontStyle: String,
    val fontFamily: String,
    val backgroundColor: String?,
    val cornerRadius: Float,
    val strokeColor: String?,
    val strokeWidth: Float,
    val shadowColor: String?,
    val shadowRadius: Float,
    val shadowOpacity: Float,
    val highlightColor: String?,
    val highlightStart: Int?,
    val highlightLength: Int?,
    val rotation: Float,
    override val timelineRange: ProjectTimeRange?,
  ) : ProjectOverlayClip()

  data class Image(
    override val id: String,
    val uri: String,
    val x: Float,
    val y: Float,
    val width: Float,
    val height: Float,
    val opacity: Float,
    val rotation: Float,
    override val timelineRange: ProjectTimeRange?,
  ) : ProjectOverlayClip()
}

sealed class ProjectTrack {
  abstract val id: String
  data class Video(override val id: String, val clips: List<ProjectVideoClip>) : ProjectTrack()
  data class Audio(override val id: String, val clips: List<ProjectAudioClip>) : ProjectTrack()
  data class Overlay(override val id: String, val items: List<ProjectOverlayClip>) : ProjectTrack()
}

data class Project(
  val id: String,
  val schemaVersion: Int,
  val canvasWidth: Int,
  val canvasHeight: Int,
  val fps: Int,
  val durationMs: Long,
  val tracks: List<ProjectTrack>,
) {
  fun videoClips(): List<ProjectVideoClip> =
    tracks.flatMap { if (it is ProjectTrack.Video) it.clips else emptyList() }
  fun audioClips(): List<ProjectAudioClip> =
    tracks.flatMap { if (it is ProjectTrack.Audio) it.clips else emptyList() }
  fun overlayClips(): List<ProjectOverlayClip> =
    tracks.flatMap { if (it is ProjectTrack.Overlay) it.items else emptyList() }
}

class ProjectParseException(msg: String) : Exception(msg)

object ProjectParser {

  @Suppress("UNCHECKED_CAST")
  fun parse(map: Map<String, Any?>): Project {
    val id = map["id"] as? String ?: throw ProjectParseException("missing id")
    val schemaVersion = (map["schemaVersion"] as? Number)?.toInt() ?: 1
    if (schemaVersion != 1) throw ProjectParseException("unsupported schemaVersion $schemaVersion")

    val canvas = map["canvasSize"] as? Map<String, Any?>
      ?: throw ProjectParseException("missing canvasSize")
    val canvasW = (canvas["width"] as? Number)?.toInt() ?: throw ProjectParseException("invalid canvasSize.width")
    val canvasH = (canvas["height"] as? Number)?.toInt() ?: throw ProjectParseException("invalid canvasSize.height")

    val fps = (map["fps"] as? Number)?.toInt() ?: 30
    val durationMs = (map["durationMs"] as? Number)?.toLong() ?: 0L

    val tracks = (map["tracks"] as? List<Map<String, Any?>>)?.map { parseTrack(it) } ?: emptyList()

    return Project(
      id = id, schemaVersion = schemaVersion,
      canvasWidth = canvasW, canvasHeight = canvasH,
      fps = fps, durationMs = durationMs, tracks = tracks
    )
  }

  @Suppress("UNCHECKED_CAST")
  private fun parseTrack(m: Map<String, Any?>): ProjectTrack {
    val kind = m["kind"] as? String ?: throw ProjectParseException("track missing kind")
    val id = m["id"] as? String ?: throw ProjectParseException("track missing id")
    return when (kind) {
      "video" -> ProjectTrack.Video(id, (m["clips"] as? List<Map<String, Any?>>)?.map { parseVideoClip(it) } ?: emptyList())
      "audio" -> ProjectTrack.Audio(id, (m["clips"] as? List<Map<String, Any?>>)?.map { parseAudioClip(it) } ?: emptyList())
      "overlay" -> ProjectTrack.Overlay(id, (m["items"] as? List<Map<String, Any?>>)?.map { parseOverlay(it) } ?: emptyList())
      else -> throw ProjectParseException("unknown track kind $kind")
    }
  }

  @Suppress("UNCHECKED_CAST")
  private fun parseVideoClip(m: Map<String, Any?>): ProjectVideoClip {
    val id = m["id"] as? String ?: "v-${System.nanoTime()}"
    val kind = m["kind"] as? String
    val isImage = kind == "image"
    val sourceUri = m["sourceUri"] as? String ?: ""
    val imageDurationMs = (m["durationMs"] as? Number)?.toLong()
    val srcRange = parseTimeRange(m["sourceRange"]) ?: ProjectTimeRange(0, imageDurationMs ?: 0)
    val tlRange = parseTimeRange(m["timelineRange"])
      ?: throw ProjectParseException("video clip $id missing timelineRange")
    val transition = parseTransition(m["transition"] as? Map<String, Any?>)
    val originalVolume = (m["originalVolume"] as? Number)?.toFloat() ?: 1f
    return ProjectVideoClip(
      id, sourceUri, srcRange, tlRange, transition, originalVolume,
      isImage = isImage, imageDurationMs = imageDurationMs
    )
  }

  @Suppress("UNCHECKED_CAST")
  private fun parseAudioClip(m: Map<String, Any?>): ProjectAudioClip {
    val id = m["id"] as? String ?: "a-${System.nanoTime()}"
    val sourceUri = m["sourceUri"] as? String ?: throw ProjectParseException("audio clip $id missing sourceUri")
    val srcRange = parseTimeRange(m["sourceRange"])
      ?: throw ProjectParseException("audio clip $id missing sourceRange")
    val tlRange = parseTimeRange(m["timelineRange"])
      ?: throw ProjectParseException("audio clip $id missing timelineRange")
    return ProjectAudioClip(
      id, sourceUri, srcRange, tlRange,
      volume = (m["volume"] as? Number)?.toFloat() ?: 1f,
      trimToVideo = m["trimToVideo"] as? Boolean ?: false
    )
  }

  private fun parseOverlay(m: Map<String, Any?>): ProjectOverlayClip {
    val kind = m["kind"] as? String ?: throw ProjectParseException("overlay missing kind")
    val id = m["id"] as? String ?: "o-${System.nanoTime()}"
    val tl = parseTimeRange(m["timelineRange"])
    return when (kind) {
      "text" -> ProjectOverlayClip.Text(
        id = id,
        content = m["content"] as? String ?: "",
        x = (m["x"] as? Number)?.toFloat() ?: 0f,
        y = (m["y"] as? Number)?.toFloat() ?: 0f,
        anchor = m["anchor"] as? String ?: "center",
        textAlign = m["textAlign"] as? String ?: "center",
        paddingX = (m["paddingX"] as? Number)?.toFloat() ?: 12f,
        paddingY = (m["paddingY"] as? Number)?.toFloat() ?: 8f,
        fontSize = (m["fontSize"] as? Number)?.toFloat() ?: 32f,
        color = m["color"] as? String ?: "#FFFFFF",
        fontWeight = m["fontWeight"] as? String ?: "normal",
        fontStyle = m["fontStyle"] as? String ?: "normal",
        fontFamily = m["fontFamily"] as? String ?: "system",
        backgroundColor = m["backgroundColor"] as? String,
        cornerRadius = (m["cornerRadius"] as? Number)?.toFloat() ?: 0f,
        strokeColor = m["strokeColor"] as? String,
        strokeWidth = (m["strokeWidth"] as? Number)?.toFloat() ?: 0f,
        shadowColor = m["shadowColor"] as? String,
        shadowRadius = (m["shadowRadius"] as? Number)?.toFloat() ?: 0f,
        shadowOpacity = (m["shadowOpacity"] as? Number)?.toFloat() ?: 1f,
        highlightColor = m["highlightColor"] as? String,
        highlightStart = (m["highlightStart"] as? Number)?.toInt(),
        highlightLength = (m["highlightLength"] as? Number)?.toInt(),
        rotation = (m["rotation"] as? Number)?.toFloat() ?: 0f,
        timelineRange = tl,
      )
      "image" -> ProjectOverlayClip.Image(
        id = id,
        uri = m["uri"] as? String ?: "",
        x = (m["x"] as? Number)?.toFloat() ?: 0f,
        y = (m["y"] as? Number)?.toFloat() ?: 0f,
        width = (m["width"] as? Number)?.toFloat() ?: 0.2f,
        height = (m["height"] as? Number)?.toFloat() ?: 0.2f,
        opacity = (m["opacity"] as? Number)?.toFloat() ?: 1f,
        rotation = (m["rotation"] as? Number)?.toFloat() ?: 0f,
        timelineRange = tl,
      )
      else -> throw ProjectParseException("unknown overlay kind $kind")
    }
  }

  @Suppress("UNCHECKED_CAST")
  private fun parseTimeRange(raw: Any?): ProjectTimeRange? {
    val m = raw as? Map<String, Any?> ?: return null
    val s = (m["startMs"] as? Number)?.toLong() ?: return null
    val e = (m["endMs"] as? Number)?.toLong() ?: return null
    return ProjectTimeRange(s, e)
  }

  @Suppress("UNCHECKED_CAST")
  private fun parseTransition(m: Map<String, Any?>?): ProjectClipTransition {
    if (m == null) return ProjectClipTransition.Cut
    return when (m["type"] as? String) {
      "fade" -> ProjectClipTransition.Fade((m["durationMs"] as? Number)?.toLong() ?: 500L)
      "fadeToBlack" -> ProjectClipTransition.FadeToBlack((m["durationMs"] as? Number)?.toLong() ?: 500L)
      else -> ProjectClipTransition.Cut
    }
  }
}
