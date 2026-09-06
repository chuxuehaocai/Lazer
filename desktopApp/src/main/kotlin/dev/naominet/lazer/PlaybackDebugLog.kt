package dev.naominet.lazer

import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.time.Instant

/** Bounded playback trace. Stream URLs, account data and credentials are never recorded. */
internal object PlaybackDebugLog {
    private const val MaxLogBytes = 512 * 1024L
    private val lock = Any()
    private val path: Path = Path.of(System.getProperty("user.home"), ".lazer", "logs", "playback.log")

    fun event(name: String, details: String = "") {
        val safeDetails = details.replace('\n', ' ').replace('\r', ' ').take(480)
        runCatching {
            synchronized(lock) {
                Files.createDirectories(path.parent)
                if (Files.exists(path) && Files.size(path) >= MaxLogBytes) {
                    Files.move(
                        path,
                        path.resolveSibling("playback.previous.log"),
                        StandardCopyOption.REPLACE_EXISTING,
                    )
                }
                Files.writeString(
                    path,
                    "${Instant.now()} [${Thread.currentThread().name}] $name $safeDetails\n",
                    StandardOpenOption.CREATE,
                    StandardOpenOption.WRITE,
                    StandardOpenOption.APPEND,
                )
            }
        }
    }
}

internal fun Throwable.playbackDebugSummary(): String {
    val original = this
    val root = generateSequence(this) { it.cause }.last()
    val location = root.stackTrace
        .take(5)
        .joinToString(" <- ") { frame ->
            "${frame.className.substringAfterLast('.')}.${frame.methodName}(${frame.fileName}:${frame.lineNumber})"
        }
    val summary = buildString {
        append(javaClass.simpleName)
        append(':')
        append(message.orEmpty())
        if (root !== original) {
            append(" root=")
            append(root.javaClass.simpleName)
            append(':')
            append(root.message.orEmpty())
        }
        if (location.isNotBlank()) {
            append(" at=")
            append(location)
        }
    }
    return summary.replace('\n', ' ').replace('\r', ' ').take(440)
}
