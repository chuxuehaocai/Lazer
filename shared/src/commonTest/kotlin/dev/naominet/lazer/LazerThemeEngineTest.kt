package dev.naominet.lazer

import kotlin.test.Test
import kotlin.test.assertEquals

class LazerThemeEngineTest {
    @Test
    fun defaultsToMaterial3ForMissingOrUnknownValues() {
        assertEquals(LazerThemeEngine.MATERIAL3, parseLazerThemeEngine(null))
        assertEquals(LazerThemeEngine.MATERIAL3, parseLazerThemeEngine(""))
        assertEquals(LazerThemeEngine.MATERIAL3, parseLazerThemeEngine("unknown"))
    }

    @Test
    fun restoresEveryKnownThemeEngine() {
        LazerThemeEngine.entries.forEach { engine ->
            assertEquals(engine, parseLazerThemeEngine(engine.name))
        }
    }
}
