package dev.naominet.lazer

import dev.naominet.lazer.gateway.GatewaySessionStore
import dev.naominet.lazer.gateway.DEFAULT_GATEWAY_BASE_URL
import dev.naominet.lazer.gateway.normalizeGatewayBaseUrl
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.util.Base64
import java.util.Properties

/** Stores the Gateway credential in a private per-user application state file. */
internal class DesktopGatewaySessionStore : GatewaySessionStore {
    override var cookie: String?
        get() = DesktopStateFile.get(SESSION_COOKIE_KEY)?.let { encoded ->
            runCatching { String(Base64.getDecoder().decode(encoded), Charsets.UTF_8) }.getOrNull()
        }?.takeIf(String::isNotBlank)
        set(value) {
            DesktopStateFile.set(
                SESSION_COOKIE_KEY,
                value?.takeIf(String::isNotBlank)?.let {
                    Base64.getEncoder().encodeToString(it.toByteArray(Charsets.UTF_8))
                },
            )
        }

    companion object {
        private const val SESSION_COOKIE_KEY = "gateway.session.cookie"
    }
}

internal object DesktopSettings {
    var isDark: Boolean
        get() = DesktopStateFile.get("appearance.dark")?.toBooleanStrictOrNull() ?: false
        set(value) = DesktopStateFile.set("appearance.dark", value.toString())

    /**
     * Single appearance style. The Acrylic style is Windows-only (it needs the DWM backdrop), so a
     * value persisted on Windows falls back to Material when the app runs elsewhere.
     */
    var style: LazerStyle
        get() {
            val stored = DesktopStateFile.get("appearance.style")?.let(::parseLazerStyle)
                ?: run {
                    val legacyEngine = parseLazerThemeEngine(DesktopStateFile.get("appearance.theme_engine"))
                    val legacyGlass = DesktopStateFile.get("appearance.liquid_glass")?.toBooleanStrictOrNull() ?: false
                    when {
                        legacyGlass -> LazerStyle.LIQUID_GLASS
                        legacyEngine == LazerThemeEngine.MIUIX -> LazerStyle.MIUIX
                        else -> LazerStyle.MATERIAL
                    }
                }
            return if (!isWindowsDesktop() && stored == LazerStyle.LIQUID_GLASS) LazerStyle.MATERIAL else stored
        }
        set(value) = DesktopStateFile.set("appearance.style", value.name)

    var language: LazerLanguage
        get() = parseLazerLanguage(DesktopStateFile.get("appearance.language"))
        set(value) = DesktopStateFile.set("appearance.language", value.name)

    /** Colour source. Migrates the legacy system-monet toggle on first read. */
    var palette: LazerPalette
        get() {
            DesktopStateFile.get("appearance.palette")?.let { return LazerPalette.parse(it) }
            return LazerPalette.Default
        }
        set(value) = DesktopStateFile.set("appearance.palette", value.serialize())

    var backgroundImagePath: String?
        get() = DesktopStateFile.get("appearance.background_image")
        set(value) = DesktopStateFile.set("appearance.background_image", value)

    var backgroundAlpha: Float
        get() = DesktopStateFile.get("appearance.background_alpha")?.toFloatOrNull()?.coerceIn(0f, 1f) ?: 0.82f
        set(value) = DesktopStateFile.set("appearance.background_alpha", value.coerceIn(0f, 1f).toString())

    var lyricFollowDelayMillis: Long
        get() = normalizeLyricFollowDelayMillis(
            DesktopStateFile.get("lyrics.follow_delay_millis")?.toLongOrNull()
                ?: DEFAULT_LYRIC_FOLLOW_DELAY_MILLIS,
        )
        set(value) = DesktopStateFile.set(
            "lyrics.follow_delay_millis",
            normalizeLyricFollowDelayMillis(value).toString(),
        )

    var lyricAnimationSpeed: LyricAnimationSpeed
        get() = parseLyricAnimationSpeed(DesktopStateFile.get("lyrics.animation_speed"))
        set(value) = DesktopStateFile.set("lyrics.animation_speed", value.name)

    var wordLyricsEnabled: Boolean
        get() = DesktopStateFile.get("lyrics.word_animation_enabled")?.toBooleanStrictOrNull() ?: true
        set(value) = DesktopStateFile.set("lyrics.word_animation_enabled", value.toString())

    var lyricGlowEnabled: Boolean
        get() = DesktopStateFile.get("lyrics.glow_enabled")?.toBooleanStrictOrNull() ?: true
        set(value) = DesktopStateFile.set("lyrics.glow_enabled", value.toString())

    var lyricFontSizeSp: Int
        get() = normalizeLyricFontSizeSp(
            DesktopStateFile.get("lyrics.font_size_sp")?.toIntOrNull()
                ?: DEFAULT_DESKTOP_LYRIC_FONT_SIZE_SP,
        )
        set(value) = DesktopStateFile.set(
            "lyrics.font_size_sp",
            normalizeLyricFontSizeSp(value).toString(),
        )

    var showFullLyrics: Boolean
        get() = DesktopStateFile.get("lyrics.show_full_lines")?.toBooleanStrictOrNull() ?: false
        set(value) = DesktopStateFile.set("lyrics.show_full_lines", value.toString())

    var exclusiveAudio: Boolean
        get() = DesktopStateFile.get("playback.exclusive_audio")?.toBooleanStrictOrNull() ?: false
        set(value) = DesktopStateFile.set("playback.exclusive_audio", value.toString())

    var gatewayBaseUrl: String
        get() = normalizeGatewayBaseUrl(
            DesktopStateFile.get("gateway.base_url") ?: DEFAULT_GATEWAY_BASE_URL,
        ) ?: DEFAULT_GATEWAY_BASE_URL
        set(value) = DesktopStateFile.set(
            "gateway.base_url",
            normalizeGatewayBaseUrl(value) ?: DEFAULT_GATEWAY_BASE_URL,
        )
}

private object DesktopStateFile {
    private val statePath: Path by lazy {
        Path.of(System.getProperty("user.home"), ".lazer", "state.properties")
    }

    @Synchronized
    fun get(key: String): String? = runCatching {
        if (!Files.exists(statePath)) return@runCatching null
        Properties().apply { Files.newInputStream(statePath).use(::load) }.getProperty(key)
    }.getOrNull()

    @Synchronized
    fun set(key: String, value: String?) {
        runCatching {
            Files.createDirectories(statePath.parent)
            val properties = Properties().apply {
                if (Files.exists(statePath)) Files.newInputStream(statePath).use(::load)
            }
            if (value == null) properties.remove(key) else properties.setProperty(key, value)

            val temporary = statePath.resolveSibling("${statePath.fileName}.tmp")
            Files.newOutputStream(temporary).use { properties.store(it, "Lazer local state") }
            runCatching {
                Files.move(
                    temporary,
                    statePath,
                    StandardCopyOption.REPLACE_EXISTING,
                    StandardCopyOption.ATOMIC_MOVE,
                )
            }.getOrElse {
                Files.move(temporary, statePath, StandardCopyOption.REPLACE_EXISTING)
            }
        }
    }
}
