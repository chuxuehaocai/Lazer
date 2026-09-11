package dev.naominet.lazer

import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class LazerI18nTest {
    @Test
    fun loadsEveryBundledJsonCatalog() = runTest {
        loadLazerTranslations()

        try {
            LazerLanguage.entries.forEach { language ->
                LazerI18n.switchLanguage(language)
                assertTrue(language.displayName != "language.${language.code}")
                assertTrue(tr("settings.title") != "settings.title")
                assertTrue(tr("player.play") != "player.play")
            }
        } finally {
            LazerI18n.switchLanguage(LazerLanguage.SIMPLIFIED_CHINESE)
        }
    }

    @Test
    fun parsesPersistedNamesAndLanguageCodes() {
        assertEquals(LazerLanguage.ENGLISH, parseLazerLanguage("ENGLISH"))
        assertEquals(LazerLanguage.TRADITIONAL_CHINESE, parseLazerLanguage("zh-Hant"))
        assertEquals(LazerLanguage.SIMPLIFIED_CHINESE, parseLazerLanguage("unknown"))
    }

    @Test
    fun switchesLanguagesAndFormatsArguments() {
        val maps = completeMaps(
            simplified = mapOf("hello" to "你好，{0}", "fallback" to "默认"),
            overrides = mapOf(
                LazerLanguage.ENGLISH to mapOf("hello" to "Hello, {0}", "fallback" to "Fallback"),
            ),
        )
        LazerI18n.install(maps)

        try {
            LazerI18n.switchLanguage(LazerLanguage.ENGLISH)
            assertEquals("Hello, Lazer", tr("hello", "Lazer"))
            assertEquals("missing.key", tr("missing.key"))

            assertEquals("Fallback", tr("fallback"))
        } finally {
            LazerI18n.switchLanguage(LazerLanguage.SIMPLIFIED_CHINESE)
        }
    }

    @Test
    fun rejectsCatalogsWithDifferentKeysOrPlaceholders() {
        val missingKey = completeMaps(mapOf("hello" to "你好", "count" to "{0} 首"))
            .toMutableMap()
            .apply { this[LazerLanguage.JAPANESE] = mapOf("hello" to "こんにちは") }
        assertFailsWith<IllegalArgumentException> { validateTranslationMaps(missingKey) }

        val mismatchedPlaceholder = completeMaps(mapOf("hello" to "你好", "count" to "{0} 首"))
            .toMutableMap()
            .apply {
                this[LazerLanguage.ENGLISH] = mapOf("hello" to "Hello", "count" to "{1} tracks")
            }
        val error = assertFailsWith<IllegalArgumentException> {
            validateTranslationMaps(mismatchedPlaceholder)
        }
        assertTrue(error.message.orEmpty().contains("placeholders"))
    }

    private fun completeMaps(
        simplified: Map<String, String>,
        overrides: Map<LazerLanguage, Map<String, String>> = emptyMap(),
    ): Map<LazerLanguage, Map<String, String>> =
        LazerLanguage.entries.associateWith { language -> overrides[language] ?: simplified }
}
