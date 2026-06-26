package expo.modules.mediaedit

import android.content.Context
import android.opengl.GLES20
import androidx.media3.common.VideoFrameProcessingException
import androidx.media3.common.util.GlProgram
import androidx.media3.common.util.GlUtil
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BaseGlShaderProgram
import androidx.media3.effect.GlEffect
import androidx.media3.effect.GlShaderProgram

/**
 * GlEffect that multiplies each output pixel's alpha channel by a
 * time-dependent scalar in [0, 1]. Used by ProjectCompiler to render
 * true crossfades on Android: the outgoing clip's alpha ramps 1 → 0
 * over the transition window while the incoming clip's alpha ramps
 * 0 → 1, played simultaneously in a multi-sequence Composition.
 *
 * The shader is the textbook passthrough fragment with `gl_FragColor.a *=
 * uAlpha`. Vertex shader is a plain quad pass-through.
 *
 * `alphaFor(presentationTimeUs)` is invoked once per frame at draw
 * time. Callers (ProjectCompiler) close over the clip's absolute
 * timeline window inside the closure.
 */
@UnstableApi
class AlphaScaleEffect(
  private val alphaFor: (presentationTimeUs: Long) -> Float,
) : GlEffect {
  override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram {
    return AlphaScaleShaderProgram(useHdr, alphaFor)
  }
}

@UnstableApi
private class AlphaScaleShaderProgram(
  useHdr: Boolean,
  private val alphaFor: (Long) -> Float,
) : BaseGlShaderProgram(useHdr, /* texturePoolCapacity = */ 1) {

  private var glProgram: GlProgram? = null

  override fun configure(inputWidth: Int, inputHeight: Int): Size {
    try {
      val program = GlProgram(VERTEX_SHADER, FRAGMENT_SHADER)
      program.setBufferAttribute(
        "aFramePosition",
        floatArrayOf(
          -1f, -1f, 0f, 1f,
           1f, -1f, 0f, 1f,
          -1f,  1f, 0f, 1f,
           1f,  1f, 0f, 1f,
        ),
        /* size = */ 4,
      )
      program.setBufferAttribute(
        "aTexSamplingCoord",
        floatArrayOf(
          0f, 0f,
          1f, 0f,
          0f, 1f,
          1f, 1f,
        ),
        /* size = */ 2,
      )
      glProgram = program
    } catch (e: GlUtil.GlException) {
      throw VideoFrameProcessingException(e)
    }
    return Size(inputWidth, inputHeight)
  }

  override fun drawFrame(inputTexId: Int, presentationTimeUs: Long) {
    val program = glProgram ?: throw VideoFrameProcessingException("AlphaScale shader not configured")
    try {
      program.use()
      program.setSamplerTexIdUniform("uTexSampler", inputTexId, /* texUnitIndex = */ 0)
      val a = alphaFor(presentationTimeUs).coerceIn(0f, 1f)
      program.setFloatUniform("uAlpha", a)
      program.bindAttributesAndUniforms()
      GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
      GlUtil.checkGlError()
    } catch (e: GlUtil.GlException) {
      throw VideoFrameProcessingException(e, presentationTimeUs)
    }
  }

  override fun release() {
    super.release()
    try { glProgram?.delete() } catch (_: Exception) {}
    glProgram = null
  }

  companion object {
    private const val VERTEX_SHADER = """#version 100
attribute vec4 aFramePosition;
attribute vec2 aTexSamplingCoord;
varying vec2 vTexSamplingCoord;
void main() {
  gl_Position = aFramePosition;
  vTexSamplingCoord = aTexSamplingCoord;
}
"""

    private const val FRAGMENT_SHADER = """#version 100
precision mediump float;
uniform sampler2D uTexSampler;
uniform float uAlpha;
varying vec2 vTexSamplingCoord;
void main() {
  vec4 src = texture2D(uTexSampler, vTexSamplingCoord);
  gl_FragColor = vec4(src.rgb, src.a * uAlpha);
}
"""
  }
}
