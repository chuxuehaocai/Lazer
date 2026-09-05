package dev.naominet.lazer

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.Closeable
import java.io.IOException
import java.util.concurrent.atomic.AtomicLong
import javax.sound.sampled.AudioFormat
import javax.sound.sampled.AudioSystem
import javax.sound.sampled.FloatControl
import javax.sound.sampled.SourceDataLine
import kotlin.math.log10

/**
 * Small desktop streaming player backed by Java Sound. MP3 decoding is supplied by MP3SPI, while
 * PCM is written to the operating system's default output device through [SourceDataLine].
 */
internal class DesktopAudioPlayer(
    private val onProgress: (playbackToken: Long, progress: Float) -> Unit,
    private val onBuffered: (trackId: Long, progress: Float) -> Unit,
    private val onCompleted: (playbackToken: Long) -> Unit,
    private val onError: (playbackToken: Long, error: Throwable) -> Unit,
) : Closeable {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val audioCache = DesktopAudioCache(onProgress = onBuffered)
    private val generation = AtomicLong(0L)
    private var playbackJob: Job? = null

    @Volatile
    private var activeLine: SourceDataLine? = null

    @Volatile
    private var activeInput: Closeable? = null

    @Volatile
    private var paused = false

    @Volatile
    private var volume = 0.72f

    fun play(
        url: String,
        trackId: Long,
        cacheVariant: String,
        expectedBytes: Long?,
        durationMillis: Long,
        fromProgress: Float = 0f,
        volume: Float = this.volume,
        playWhenReady: Boolean = true,
    ): Long {
        stopCurrent()
        this.volume = volume.coerceIn(0f, 1f)
        paused = !playWhenReady
        val token = generation.incrementAndGet()
        playbackJob = scope.launch {
            runCatching {
                stream(
                    url = url,
                    trackId = trackId,
                    cacheVariant = cacheVariant,
                    expectedBytes = expectedBytes,
                    durationMillis = durationMillis,
                    fromProgress = fromProgress.coerceIn(0f, 1f),
                    token = token,
                )
            }.onFailure { error ->
                if (error !is CancellationException && token == generation.get()) {
                    releaseActiveResources()
                    onError(token, error)
                }
            }
        }
        return token
    }

    fun pause() {
        paused = true
        runCatching { activeLine?.stop() }
    }

    fun resume() {
        paused = false
        runCatching { activeLine?.start() }
    }

    fun setVolume(value: Float) {
        volume = value.coerceIn(0f, 1f)
        activeLine?.let(::applyVolume)
    }

    fun stop() {
        stopCurrent()
    }

    override fun close() {
        stopCurrent()
        audioCache.close()
        scope.cancel()
    }

    private suspend fun stream(
        url: String,
        trackId: Long,
        cacheVariant: String,
        expectedBytes: Long?,
        durationMillis: Long,
        fromProgress: Float,
        token: Long,
    ) {
        // A single downloader owns the network connection. Java Sound reads the same growing
        // file, so pausing does not pause caching and a seek can immediately reuse cached bytes.
        val cacheInput = audioCache.open(
            trackId = trackId,
            variantKey = cacheVariant,
            url = url,
            expectedBytes = expectedBytes,
        ).buffered(64 * 1024)
        activeInput = cacheInput
        val encodedInput = AudioSystem.getAudioInputStream(cacheInput)
        activeInput = encodedInput
        val source = encodedInput.format
        val channels = source.channels.takeIf { it > 0 } ?: 2
        val sampleRate = source.sampleRate.takeIf { it > 0f } ?: 44_100f
        val decodedFormat = AudioFormat(
            AudioFormat.Encoding.PCM_SIGNED,
            sampleRate,
            16,
            channels,
            channels * 2,
            sampleRate,
            false,
        )
        val decodedInput = AudioSystem.getAudioInputStream(decodedFormat, encodedInput)
        activeInput = decodedInput

        var line: SourceDataLine? = null
        try {
            val bytesPerSecond = (decodedFormat.frameRate * decodedFormat.frameSize).toDouble()
            val targetBytes = if (durationMillis > 0L && bytesPerSecond > 0.0) {
                (durationMillis / 1000.0 * bytesPerSecond * fromProgress).toLong()
            } else {
                0L
            }
            if (!skipFully(decodedInput, targetBytes, token)) {
                throw IOException("跳转位置超出了音频内容")
            }
            if (!scope.isActive || token != generation.get()) return

            line = AudioSystem.getSourceDataLine(decodedFormat).also { opened ->
                activeLine = opened
                opened.open(decodedFormat)
                applyVolume(opened)
                if (!paused) opened.start()
            }

            val buffer = ByteArray(16 * 1024)
            var lastProgressUpdate = 0L
            var consecutiveZeroReads = 0
            var endOfStream = false

            while (scope.isActive && token == generation.get()) {
                while (paused && scope.isActive && token == generation.get()) delay(40)
                if (!scope.isActive || token != generation.get()) return

                val active = line ?: return
                if (!paused && !active.isRunning) {
                    runCatching { active.start() }
                }

                val count = try {
                    decodedInput.read(buffer)
                } catch (error: IOException) {
                    val playedMillis = active.longFramePosition / decodedFormat.frameRate * 1000.0
                    if (shouldCompleteAfterEof(durationMillis, fromProgress, playedMillis.toLong())) {
                        endOfStream = true
                        -1
                    } else {
                        throw IOException("音频连接中断，已停止播放以免误切到下一首", error)
                    }
                }
                when {
                    count < 0 -> {
                        endOfStream = true
                        break
                    }
                    count == 0 -> {
                        // MP3SPI often yields a few empty reads before EOF; don't spin forever.
                        consecutiveZeroReads += 1
                        if (consecutiveZeroReads >= 40) {
                            val playedMillis = active.longFramePosition / decodedFormat.frameRate * 1000.0
                            if (shouldCompleteAfterEof(durationMillis, fromProgress, playedMillis.toLong())) {
                                endOfStream = true
                                break
                            }
                            throw IOException("音频流暂时没有返回数据")
                        }
                        delay(15)
                        continue
                    }
                    else -> consecutiveZeroReads = 0
                }

                var written = 0
                var zeroWrites = 0
                while (written < count && token == generation.get() && scope.isActive) {
                    if (paused) {
                        delay(20)
                        continue
                    }
                    val chunk = runCatching {
                        active.write(buffer, written, count - written)
                    }.getOrDefault(0)
                    if (chunk > 0) {
                        written += chunk
                        zeroWrites = 0
                    } else {
                        zeroWrites += 1
                        if (!active.isOpen) {
                            endOfStream = true
                            break
                        }
                        if (!active.isRunning) runCatching { active.start() }
                        if (zeroWrites >= 40) {
                            throw IOException("系统音频输出停止响应")
                        }
                        delay(10)
                    }
                }
                if (endOfStream) break

                val now = System.nanoTime()
                if (durationMillis > 0L && now - lastProgressUpdate >= 33_000_000L) {
                    val playedMillis = active.longFramePosition / decodedFormat.frameRate * 1000.0
                    val progress = fromProgress + playedMillis.toFloat() / durationMillis.toFloat()
                    onProgress(token, progress.coerceIn(0f, 0.999f))
                    lastProgressUpdate = now
                }
            }

            if (token == generation.get() && endOfStream) {
                line?.let { drainWithTimeout(it, token, timeoutMs = 2_500) }
                val playedMillis = line?.let {
                    (it.longFramePosition / decodedFormat.frameRate * 1000.0).toLong()
                } ?: 0L
                if (!shouldCompleteAfterEof(durationMillis, fromProgress, playedMillis)) {
                    throw IOException("音频连接提前结束，已停止播放以免误切到下一首")
                }
                onProgress(token, 1f)
                onCompleted(token)
            } else if (token == generation.get() && !scope.isActive) {
                // cancelled
            }
        } finally {
            val finishedLine = line
            val finishedInput = decodedInput
            if (finishedLine != null) release(finishedLine, finishedInput) else {
                if (activeInput === decodedInput) activeInput = null
                runCatching { decodedInput.close() }
            }
        }
    }

    /**
     * [SourceDataLine.drain] can block indefinitely on some Windows drivers when the stream ends.
     * Wait up to [timeoutMs], then force-stop so the next track can start.
     */
    private suspend fun drainWithTimeout(line: SourceDataLine, token: Long, timeoutMs: Long) {
        val deadline = System.nanoTime() + timeoutMs * 1_000_000L
        while (
            scope.isActive &&
            token == generation.get() &&
            line.isOpen &&
            line.available() < line.bufferSize &&
            System.nanoTime() < deadline
        ) {
            delay(12)
        }
        if (line.isOpen && line.available() < line.bufferSize) {
            runCatching { line.stop() }
            runCatching { line.flush() }
        }
    }

    private suspend fun skipFully(input: java.io.InputStream, bytes: Long, token: Long): Boolean {
        var remaining = bytes
        val discard = ByteArray(16 * 1024)
        while (remaining > 0 && scope.isActive && token == generation.get()) {
            val skipped = runCatching { input.skip(remaining) }.getOrDefault(0L)
            if (skipped > 0) {
                remaining -= skipped
            } else {
                val count = runCatching {
                    input.read(discard, 0, minOf(discard.size.toLong(), remaining).toInt())
                }.getOrDefault(-1)
                if (count < 0) return false
                if (count == 0) {
                    delay(10)
                    continue
                }
                remaining -= count
            }
        }
        return remaining == 0L
    }

    private fun applyVolume(line: SourceDataLine) {
        runCatching {
            val control = line.getControl(FloatControl.Type.MASTER_GAIN) as FloatControl
            val gain = if (volume <= 0.0001f) {
                control.minimum
            } else {
                (20f * log10(volume)).coerceIn(control.minimum, control.maximum)
            }
            control.value = gain
        }
    }

    private fun stopCurrent() {
        generation.incrementAndGet()
        playbackJob?.cancel()
        playbackJob = null
        paused = false
        releaseActiveResources()
    }

    private fun releaseActiveResources() {
        val line = activeLine
        val input = activeInput
        activeLine = null
        activeInput = null
        runCatching { line?.stop() }
        runCatching { line?.flush() }
        runCatching { line?.close() }
        runCatching { input?.close() }
    }

    private fun release(line: SourceDataLine, input: Closeable) {
        if (activeLine === line) activeLine = null
        if (activeInput === input) activeInput = null
        runCatching { line.stop() }
        runCatching { line.flush() }
        runCatching { line.close() }
        runCatching { input.close() }
    }
}

/**
 * A decoder EOF only means "next track" when playback is genuinely at the tail. Network errors
 * and truncated CDN responses can otherwise look exactly like EOF and skip a song midway through.
 */
internal fun shouldCompleteAfterEof(
    durationMillis: Long,
    fromProgress: Float,
    playedMillis: Long,
): Boolean {
    if (durationMillis <= 0L) return true
    val startMillis = (durationMillis * fromProgress.coerceIn(0f, 1f).toDouble()).toLong()
    val positionMillis = (startMillis + playedMillis.coerceAtLeast(0L)).coerceAtMost(durationMillis)
    val tailTolerance = maxOf(5_000L, durationMillis / 30L).coerceAtMost(15_000L)
    return durationMillis - positionMillis <= tailTolerance
}

internal fun needsMp3PlaybackFallback(mediaType: String?, url: String?): Boolean {
    val type = mediaType.orEmpty().lowercase()
    val path = url.orEmpty().substringBefore('?').lowercase()
    return type.isNotBlank() && type !in setOf("mp3", "mpeg") || path.endsWith(".flac")
}
