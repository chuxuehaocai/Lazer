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

    var themeEngine: LazerThemeEngine
        get() = parseLazerThemeEngine(DesktopStateFile.get("appearance.theme_engine"))
        set(value) = DesktopStateFile.set("appearance.theme_engine", value.name)

    var lyricFollowDelayMillis: Long
        get() = normalizeLyricFollowDelayMillis(
            DesktopStateFile.get("lyrics.follow_delay_millis")?.toLongOrNull()
                ?: DEFAULT_LYRIC_FOLLOW_DELAY_MILLIS,
        )
        set(value) = DesktopStateFile.set(
            "lyrics.follow_delay_millis",
            normalizeLyricFollowDelayMillis(value).toString(),
        )

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
