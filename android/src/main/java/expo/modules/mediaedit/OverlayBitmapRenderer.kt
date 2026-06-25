package expo.modules.mediaedit

import android.graphics.*
import android.text.Layout
import android.text.SpannableString
import android.text.Spanned
import android.text.StaticLayout
import android.text.TextPaint
import android.text.style.ForegroundColorSpan

/**
 * Per-frame overlay rendering onto a Canvas. Logic extracted from
 * the 0.13.x OverlayCompositor.kt#drawOverlays — same Paint setup,
 * same SpannableString karaoke handling, same per-glyph shadow via
 * Paint.setShadowLayer, same 4-copy-style stroke pass before fill.
 * API reshaped to take ProjectOverlayClip + project's frame
 * presentation time.
 *
 * Used by:
 *  - ProjectFrameOverlayEffect (export pipeline via media3
 *    BitmapOverlay subclass that re-renders per frame)
 *  - MediaPreviewView's BitmapOverlay implementation (preview)
 *
 * Centralising the renderer here is what guarantees Preview = Export
 * 1:1 on Android. Per PO decision 2026-06-25, this is the BitmapOverlay
 * route — NEVER use media3's native TextOverlay. Reason: the heutige
 * Canvas-based path is the only way to keep per-glyph Paint.setShadowLayer,
 * Paint.STROKE outlines, italic/monospace Typeface variants and the
 * karaoke ForegroundColorSpan-on-explicit-range fully fidelity-equal
 * to iOS NSAttributedString.
 */
object OverlayBitmapRenderer {

  /**
   * Render `overlays` onto an existing Canvas. Active-window check
   * is done per overlay so a callsite can pass the full overlay list
   * and let the renderer pick which ones to draw at this `frameTimeMs`.
   *
   * Caller is responsible for supplying a Bitmap of (videoWidth ×
   * videoHeight) pixels with ARGB_8888 backing.
   */
  fun drawOverlays(
    canvas: Canvas,
    overlays: List<ProjectOverlayClip>,
    frameTimeMs: Long,
    videoWidth: Int,
    videoHeight: Int,
  ) {
    for (overlay in overlays) {
      val tl = overlay.timelineRange
      if (tl != null && (frameTimeMs < tl.startMs || frameTimeMs > tl.endMs)) continue
      when (overlay) {
        is ProjectOverlayClip.Text -> drawText(canvas, overlay, videoWidth, videoHeight)
        is ProjectOverlayClip.Image -> drawImage(canvas, overlay, videoWidth, videoHeight)
      }
    }
  }

  private fun drawText(canvas: Canvas, opts: ProjectOverlayClip.Text, videoWidth: Int, videoHeight: Int) {
    val scaleFactor = videoHeight / 1080f
    val fontPx = opts.fontSize * scaleFactor

    val baseTypeface = resolveTypeface(opts.fontFamily, opts.fontWeight, opts.fontStyle)
    val spannable = buildSpannable(opts)

    val baseColor = parseColorOrDefault(opts.color, Color.WHITE)
    val fillPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
      color = baseColor
      textSize = fontPx
      typeface = baseTypeface
      style = Paint.Style.FILL
    }
    if (opts.shadowColor != null && opts.shadowRadius > 0f) {
      val sc = parseColorOrDefault(opts.shadowColor, Color.BLACK)
      val sr = (opts.shadowRadius * scaleFactor).coerceAtLeast(0.1f)
      val opacity = opts.shadowOpacity.coerceIn(0f, 1f)
      val tintedColor = Color.argb(
        (Color.alpha(sc) * opacity).toInt(),
        Color.red(sc), Color.green(sc), Color.blue(sc)
      )
      fillPaint.setShadowLayer(sr, 0f, 0f, tintedColor)
    }

    val maxWidth = (videoWidth * 0.9f).toInt()
    val alignment = when (opts.textAlign) {
      "center" -> Layout.Alignment.ALIGN_CENTER
      "right" -> Layout.Alignment.ALIGN_OPPOSITE
      else -> Layout.Alignment.ALIGN_NORMAL
    }
    val layout = StaticLayout.Builder
      .obtain(spannable, 0, spannable.length, fillPaint, maxWidth)
      .setAlignment(alignment)
      .build()
    val padX = opts.paddingX * scaleFactor
    val padY = opts.paddingY * scaleFactor
    val layerWidth = layout.width + padX * 2f
    val layerHeight = layout.height + padY * 2f

    val originX: Float
    val originY: Float
    if (opts.anchor == "topLeft") {
      originX = opts.x * videoWidth
      originY = opts.y * videoHeight
    } else {
      originX = opts.x * videoWidth - layerWidth / 2f
      originY = opts.y * videoHeight - layerHeight / 2f
    }

    canvas.save()
    canvas.translate(originX, originY)
    if (opts.rotation != 0f) canvas.rotate(opts.rotation, layerWidth / 2f, layerHeight / 2f)
    opts.backgroundColor?.let { bgColorStr ->
      val bgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = parseColorOrDefault(bgColorStr, Color.TRANSPARENT)
      }
      val cornerR = opts.cornerRadius * scaleFactor
      if (cornerR > 0f) {
        canvas.drawRoundRect(0f, 0f, layerWidth, layerHeight, cornerR, cornerR, bgPaint)
      } else {
        canvas.drawRect(0f, 0f, layerWidth, layerHeight, bgPaint)
      }
    }
    canvas.translate(padX, padY)
    if (opts.strokeColor != null && opts.strokeWidth > 0f) {
      val strokePaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        color = parseColorOrDefault(opts.strokeColor, Color.BLACK)
        textSize = fontPx
        typeface = baseTypeface
        style = Paint.Style.STROKE
        strokeWidth = opts.strokeWidth * scaleFactor
        strokeJoin = Paint.Join.ROUND
      }
      val strokeLayout = StaticLayout.Builder
        .obtain(spannable, 0, spannable.length, strokePaint, maxWidth)
        .setAlignment(alignment)
        .build()
      strokeLayout.draw(canvas)
    }
    layout.draw(canvas)
    canvas.restore()
  }

  private fun drawImage(canvas: Canvas, opts: ProjectOverlayClip.Image, videoWidth: Int, videoHeight: Int) {
    val filePath = opts.uri.removePrefix("file://")
    val bitmap = BitmapFactory.decodeFile(filePath) ?: return
    val centerX = opts.x * videoWidth
    val centerY = opts.y * videoHeight
    val w = opts.width * videoWidth
    val h = opts.height * videoHeight
    val dst = RectF(centerX - w / 2f, centerY - h / 2f, centerX + w / 2f, centerY + h / 2f)
    val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { alpha = (opts.opacity * 255).toInt() }
    canvas.save()
    if (opts.rotation != 0f) canvas.rotate(opts.rotation, centerX, centerY)
    canvas.drawBitmap(bitmap, null, dst, paint)
    canvas.restore()
    bitmap.recycle()
  }

  // MARK: - helpers (same semantics as 0.13.x)

  private fun parseColorOrDefault(s: String?, default: Int): Int {
    if (s == null) return default
    return try { Color.parseColor(s) } catch (_: Exception) { default }
  }

  private fun resolveTypeface(family: String, weight: String, style: String): Typeface {
    val base = if (family == "monospace") Typeface.MONOSPACE else Typeface.DEFAULT
    val isBold = weight == "bold"
    val isItalic = style == "italic"
    val styleInt = when {
      isBold && isItalic -> Typeface.BOLD_ITALIC
      isBold -> Typeface.BOLD
      isItalic -> Typeface.ITALIC
      else -> Typeface.NORMAL
    }
    return Typeface.create(base, styleInt)
  }

  private fun buildSpannable(opts: ProjectOverlayClip.Text): SpannableString {
    val spannable = SpannableString(opts.content)
    val colorStr = opts.highlightColor ?: return spannable
    val start = opts.highlightStart ?: return spannable
    val length = opts.highlightLength ?: return spannable
    val len = opts.content.length
    if (length <= 0 || start < 0 || start + length > len) return spannable
    val color = parseColorOrDefault(colorStr, Color.YELLOW)
    spannable.setSpan(
      ForegroundColorSpan(color),
      start,
      start + length,
      Spanned.SPAN_EXCLUSIVE_EXCLUSIVE
    )
    return spannable
  }
}
