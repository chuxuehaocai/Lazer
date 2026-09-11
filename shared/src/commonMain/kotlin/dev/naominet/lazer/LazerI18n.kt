package dev.naominet.lazer

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import lazer.shared.generated.resources.Res
import kotlinx.serialization.json.Json

private val TranslationPlaceholder = Regex("""\{(\d+)\}""")

/** Built-in languages. Each maps to an external JSON file under composeResources/files/i18n/. */
enum class LazerLanguage(val code: String, private val displayNameKey: String) {
    SIMPLIFIED_CHINESE("zh-Hans", "language.zh-Hans"),
    TRADITIONAL_CHINESE("zh-Hant", "language.zh-Hant"),
    JAPANESE("ja", "language.ja"),
    ENGLISH("en", "language.en");

    val displayName: String get() = tr(displayNameKey)
}

fun parseLazerLanguage(value: String?): LazerLanguage =
    LazerLanguage.entries.firstOrNull { it.name == value || it.code == value }
        ?: LazerLanguage.SIMPLIFIED_CHINESE

/**
 * Holds the active language and the loaded translation tables. Reading [get] inside a composable
 * observes the [language] state, so the whole UI recomposes when the language changes.
 */
object LazerI18n {
    var language by mutableStateOf(LazerLanguage.SIMPLIFIED_CHINESE)
        private set
    private var translations by mutableStateOf<Map<LazerLanguage, Map<String, String>>>(emptyMap())

    val isLoaded: Boolean
        get() = translations.isNotEmpty()

    fun switchLanguage(value: LazerLanguage) {
        language = value
    }

    fun install(maps: Map<LazerLanguage, Map<String, String>>) {
        validateTranslationMaps(maps)
        translations = maps.mapValues { (_, table) -> table.toMap() }
    }

    operator fun get(key: String): String =
        translations[language]?.get(key)
            ?: translations[LazerLanguage.SIMPLIFIED_CHINESE]?.get(key)
            ?: key
}

/** Resolves a translation key to the current language's text. */
fun tr(key: String): String = LazerI18n[key]

/** Resolves a translation key with positional arguments replacing `{0}`, `{1}`, and so on. */
fun tr(key: String, vararg args: Any): String =
    TranslationPlaceholder.replace(LazerI18n[key]) { match ->
        val index = match.groupValues[1].toInt()
        args.getOrNull(index)?.toString() ?: match.value
    }

/** Loads every built-in language file into memory. Call once on startup from a coroutine. */
suspend fun loadLazerTranslations() {
    val json = Json { ignoreUnknownKeys = true }
    val maps = LazerLanguage.entries.associateWith { language ->
        val bytes = Res.readBytes("files/i18n/${language.code}.json")
        json.decodeFromString<Map<String, String>>(bytes.decodeToString())
    }
    LazerI18n.install(maps)
}

/** Keeps built-in JSON catalogs complete and interpolation-compatible with Simplified Chinese. */
internal fun validateTranslationMaps(maps: Map<LazerLanguage, Map<String, String>>) {
    val fallback = requireNotNull(maps[LazerLanguage.SIMPLIFIED_CHINESE]) {
        "The Simplified Chinese translation catalog is missing."
    }
    require(fallback.isNotEmpty()) { "The Simplified Chinese translation catalog is empty." }

    LazerLanguage.entries.forEach { language ->
        val table = requireNotNull(maps[language]) {
            "The ${language.code} translation catalog is missing."
        }
        val missing = fallback.keys - table.keys
        val extra = table.keys - fallback.keys
        require(missing.isEmpty() && extra.isEmpty()) {
            buildString {
                append("Translation keys differ for ${language.code}.")
                if (missing.isNotEmpty()) append(" Missing: ${missing.sorted().joinToString()}.")
                if (extra.isNotEmpty()) append(" Extra: ${extra.sorted().joinToString()}.")
            }
        }
        val blankKeys = table.filterValues(String::isBlank).keys
        require(blankKeys.isEmpty()) {
            "Blank translations in ${language.code}: ${blankKeys.sorted().joinToString()}."
        }
        fallback.forEach { (key, fallbackValue) ->
            val expected = TranslationPlaceholder.findAll(fallbackValue).map { it.value }.sorted().toList()
            val actual = TranslationPlaceholder.findAll(table.getValue(key)).map { it.value }.sorted().toList()
            require(actual == expected) {
                "Translation placeholders differ for ${language.code}: $key."
            }
        }
    }
}
