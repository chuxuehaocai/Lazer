package dev.naominet.lazer

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.Closeable
import java.io.IOException
import java.io.InputStream
import java.io.RandomAccessFile
import java.net.HttpURLConnection
import java.net.URI
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardOpenOption
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock
import kotlin.math.min

/** Persistent audio cache that can be read while its file is still downloading. */
internal class DesktopAudioCache(
    private val cacheDirectory: Path = Path.of(
        System.getProperty("user.home"),
        ".lazer",
        "cache",
        "audio",
    ),
    private val onProgress: (trackId: Long, fraction: Float) -> Unit,
) : Closeable {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val entries = ConcurrentHashMap<String, AudioCacheEntry>()

    fun open(
        trackId: Long,
        variantKey: String,
        url: String,
        expectedBytes: Long?,
    ): InputStream {
        val fileName = audioCacheFileName(trackId, variantKey)
        val entry = entries.computeIfAbsent(fileName) {
            AudioCacheEntry(
                mediaPath = cacheDirectory.resolve(fileName),
                scope = scope,
                trackId = trackId,
                onProgress = onProgress,
            )
        }
        entry.ensureDownload(url, expectedBytes)
        onProgress(trackId, entry.bufferedFraction())
        return entry.openInputStream()
    }

    override fun close() {
        scope.cancel()
        entries.values.forEach(AudioCacheEntry::wakeReaders)
        entries.clear()
    }
}

private class AudioCacheEntry(
    private val mediaPath: Path,
    private val scope: CoroutineScope,
    private val trackId: Long,
    private val onProgress: (trackId: Long, fraction: Float) -> Unit,
) {
    private val completePath = mediaPath.resolveSibling("${mediaPath.fileName}.complete")
    private val dataLock = ReentrantLock()
    private val dataChanged = dataLock.newCondition()
    private val stateLock = Any()

    @Volatile
    private var downloadedBytes = existingSize()

    @Volatile
    private var expectedBytes = 0L

    @Volatile
    private var complete = hasValidCompletionMarker()

    @Volatile
    private var failure: Throwable? = null

    private var downloadJob: Job? = null

    fun ensureDownload(url: String, requestedExpectedBytes: Long?) {
        synchronized(stateLock) {
            val requestedSize = requestedExpectedBytes?.coerceAtLeast(0L) ?: 0L
            if (requestedSize > 0L) expectedBytes = requestedSize
            if (complete && requestedSize > 0L && downloadedBytes != requestedSize) {
                complete = false
                Files.deleteIfExists(completePath)
            }
            if (complete) {
                onProgress(trackId, 1f)
                return
            }
            if (downloadJob?.isActive == true) return

            Files.createDirectories(mediaPath.parent)
            if (!Files.exists(mediaPath)) Files.createFile(mediaPath)
            downloadedBytes = Files.size(mediaPath)
            if (requestedSize > 0L && downloadedBytes > requestedSize) {
                Files.newOutputStream(
                    mediaPath,
                    StandardOpenOption.WRITE,
                    StandardOpenOption.TRUNCATE_EXISTING,
                ).close()
                downloadedBytes = 0L
            }
            failure = null
            downloadJob = scope.launch { download(url) }
        }
    }

    fun openInputStream(): InputStream = GrowingCacheInputStream(this, mediaPath)

    fun bufferedFraction(): Float = when {
        complete -> 1f
        expectedBytes > 0L -> bufferedFraction(downloadedBytes, expectedBytes)
        else -> 0f
    }

    fun availableFrom(position: Long): Long = (downloadedBytes - position).coerceAtLeast(0L)
    fun isComplete(): Boolean = complete
    fun currentFailure(): Throwable? = failure

    fun awaitMoreData() {
        dataLock.lock()
        try {
            dataChanged.await(100L, TimeUnit.MILLISECONDS)
        } finally {
            dataLock.unlock()
        }
    }

    fun wakeReaders() {
        dataLock.lock()
        try {
            dataChanged.signalAll()
        } finally {
            dataLock.unlock()
        }
    }

    private suspend fun download(url: String) {
        try {
            var start = Files.size(mediaPath)
            if (expectedBytes > 0L && start == expectedBytes) {
                downloadedBytes = start
                Files.writeString(
                    completePath,
                    start.toString(),
                    StandardOpenOption.CREATE,
                    StandardOpenOption.TRUNCATE_EXISTING,
                    StandardOpenOption.WRITE,
                )
                complete = true
                onProgress(trackId, 1f)
                return
            }
            val connection = URI(url).toURL().openConnection().apply {
                connectTimeout = 15_000
                readTimeout = 20_000
                setRequestProperty("User-Agent", "Lazer/1.0")
                setRequestProperty("Accept-Encoding", "identity")
                if (start > 0L) setRequestProperty("Range", "bytes=$start-")
            }

            val append = (connection as? HttpURLConnection)?.let { http ->
                http.requestMethod = "GET"
                http.connect()
                start > 0L && http.responseCode == HttpURLConnection.HTTP_PARTIAL
            } ?: false

            if (start > 0L && !append) {
                start = 0L
                Files.newOutputStream(
                    mediaPath,
                    StandardOpenOption.WRITE,
                    StandardOpenOption.TRUNCATE_EXISTING,
                ).close()
                downloadedBytes = 0L
            }

            val responseBytes = connection.contentLengthLong.coerceAtLeast(0L)
            if (expectedBytes <= 0L && responseBytes > 0L) expectedBytes = start + responseBytes

            val openOptions = if (append) {
                arrayOf(StandardOpenOption.WRITE, StandardOpenOption.APPEND)
            } else {
                arrayOf(StandardOpenOption.WRITE, StandardOpenOption.TRUNCATE_EXISTING)
            }
            connection.getInputStream().buffered(64 * 1024).use { input ->
                Files.newOutputStream(mediaPath, *openOptions).buffered(64 * 1024).use { output ->
                    val buffer = ByteArray(64 * 1024)
                    var lastUpdateNs = 0L
                    while (scope.isActive) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        if (count == 0) continue
                        output.write(buffer, 0, count)
                        output.flush()
                        downloadedBytes += count
                        wakeReaders()

                        val now = System.nanoTime()
                        if (now - lastUpdateNs >= 100_000_000L) {
                            onProgress(trackId, bufferedFraction())
                            lastUpdateNs = now
                        }
                    }
                }
            }

            if (!scope.isActive) return
            val finalSize = Files.size(mediaPath)
            val expected = expectedBytes
            if (expected > 0L && finalSize < expected) {
                throw IOException("音频缓存下载不完整（$finalSize/$expected）")
            }
            downloadedBytes = finalSize
            Files.writeString(
                completePath,
                finalSize.toString(),
                StandardOpenOption.CREATE,
                StandardOpenOption.TRUNCATE_EXISTING,
                StandardOpenOption.WRITE,
            )
            complete = true
            onProgress(trackId, 1f)
        } catch (error: Throwable) {
            if (scope.isActive) failure = error
        } finally {
            wakeReaders()
        }
    }

    private fun existingSize(): Long = runCatching {
        if (Files.isRegularFile(mediaPath)) Files.size(mediaPath) else 0L
    }.getOrDefault(0L)

    private fun hasValidCompletionMarker(): Boolean = runCatching {
        downloadedBytes > 0L &&
            Files.isRegularFile(completePath) &&
            Files.readString(completePath).trim().toLongOrNull() == downloadedBytes
    }.getOrDefault(false)
}

private class GrowingCacheInputStream(
    private val entry: AudioCacheEntry,
    mediaPath: Path,
) : InputStream() {
    private val file = RandomAccessFile(mediaPath.toFile(), "r")
    private var position = 0L

    @Volatile
    private var closed = false

    override fun read(): Int {
        val one = ByteArray(1)
        return if (read(one, 0, 1) < 0) -1 else one[0].toInt() and 0xFF
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        if (length == 0) return 0
        while (true) {
            if (closed) throw IOException("音频缓存读取已关闭")
            val available = entry.availableFrom(position)
            if (available > 0L) {
                val count = min(length.toLong(), available).toInt()
                file.seek(position)
                val read = file.read(buffer, offset, count)
                if (read > 0) {
                    position += read
                    return read
                }
            }
            if (entry.isComplete()) return -1
            entry.currentFailure()?.let { throw IOException("音频缓存下载中断", it) }
            entry.awaitMoreData()
        }
    }

    override fun skip(count: Long): Long {
        if (count <= 0L || closed) return 0L
        val skipped = min(count, entry.availableFrom(position))
        position += skipped
        return skipped
    }

    override fun available(): Int = min(entry.availableFrom(position), Int.MAX_VALUE.toLong()).toInt()

    override fun close() {
        if (closed) return
        closed = true
        file.close()
        entry.wakeReaders()
    }
}

internal fun audioCacheFileName(trackId: Long, variantKey: String): String {
    val safeVariant = variantKey.replace(Regex("[^A-Za-z0-9_-]"), "_").take(96)
        .ifBlank { "default" }
    return "$trackId-$safeVariant.audio"
}

internal fun bufferedFraction(downloadedBytes: Long, expectedBytes: Long): Float {
    if (expectedBytes <= 0L) return 0f
    return (downloadedBytes.coerceAtLeast(0L).toDouble() / expectedBytes.toDouble())
        .toFloat()
        .coerceIn(0f, 1f)
}
