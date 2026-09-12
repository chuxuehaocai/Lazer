package dev.naominet.lazer

import kotlin.test.Test
import kotlin.test.assertEquals

class LiquidGlassTest {
    @Test
    fun blurIntensityIsClampedToItsSupportedRange() {
        assertEquals(0f, normalizeLiquidGlassBlurIntensity(-0.4f))
        assertEquals(0.6f, normalizeLiquidGlassBlurIntensity(0.6f))
        assertEquals(1f, normalizeLiquidGlassBlurIntensity(1.4f))
    }

    @Test
    fun defaultIntensityPreservesTheTunedSurfaceBlur() {
        assertEquals(1f, liquidGlassBlurScale(DEFAULT_LIQUID_GLASS_BLUR_INTENSITY))
        assertEquals(0.1f, liquidGlassBlurScale(0f))
        assertEquals(1.9f, liquidGlassBlurScale(1f))
    }
}
