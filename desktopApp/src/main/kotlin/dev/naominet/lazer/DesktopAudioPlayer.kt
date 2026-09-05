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
import java.net.URI
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
    private val onProgress: (Float) -> Unit,
    private val onCompleted: () -> Unit,
    private val onError: (Throwable) -> Unit,
) : Closeable {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
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
        durationMillis: Long,
        fromProgress: Float = 0f,
        volume: Float = this.volume,
        playWhenReady: Boolean = true,
    ) {
        stopCurrent()
        this.volume = volume.coerceIn(0f, 1f)
        paused = !playWhenReady
        val token = generation.incrementAndGet()
        playbackJob = scope.launch {
            runCatching {
                stream(url, durationMillis, fromProgress.coerceIn(0f, 1f), token)
            }.onFailure { error ->
                if (error !is CancellationException && token == generation.get()) {
                    releaseActiveResources()
                    onError(error)
                }
            }
        }
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
        scope.cancel()
    }

    private suspend fun stream(url: String, durationMillis: Long, fromProgress: Float, token: Long) {
        val connection = URI(url).toURL().openConnection().apply {
            connectTimeout = 15_000
            // Keep reads snappy near EOF so a stalled CDN tail cannot freeze the player for 30s.
            readTimeout = 8_000
            setRequestProperty("User-Agent", "Lazer/1.0")
        }
        val networkInput = connection.getInputStream().buffered(256 * 1024)
        activeInput = networkInput
        val encodedInput = AudioSystem.getAudioInputStream(networkInput)
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
            skipFully(decodedInput, targetBytes, token)
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

                val count = runCatching { decodedInput.read(buffer) }.getOrElse {
                    // Treat read failures near the tail as end-of-track rather than a hard crash.
                    endOfStream = true
                    -1
                }
                when {
                    count < 0 -> {
                        endOfStream = true
                        break
                    }
                    count == 0 -> {
                        // MP3SPI often yields a few empty reads before EOF; don't spin forever.
                        consecutiveZeroReads += 1
                        if (consecutiveZeroReads >= 12) {
                            endOfStream = true
                            break
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
                            // Line stopped accepting audio — finish rather than hang.
                            endOfStream = true
                            break
                        }
                        delay(10)
                    }
                }
                if (endOfStream) break

                val now = System.nanoTime()
                if (durationMillis > 0L && now - lastProgressUpdate >= 33_000_000L) {
                    val playedMillis = active.longFramePosition / decodedFormat.frameRate * 1000.0
                    val progress = fromProgress + playedMillis.toFloat() / durationMillis.toFloat()
                    onProgress(progress.coerceIn(0f, 0.999f))
                    lastProgressUpdate = now
                }
            }

            if (token == generation.get() && endOfStream) {
                line?.let { drainWithTimeout(it, timeoutMs = 2_500) }
                onProgress(1f)
                onCompleted()
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
    private fun drainWithTimeout(line: SourceDataLine, timeoutMs: Long) {
        val drainer = Thread({
            runCatching { line.drain() }
        }, "lazer-audio-drain").apply {
            isDaemon = true
            start()
        }
        try {
            drainer.join(timeoutMs)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        if (drainer.isAlive) {
            runCatching { line.stop() }
            runCatching { line.flush() }
        }
    }

    private suspend fun skipFully(input: java.io.InputStream, bytes: Long, token: Long) {
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
                if (count < 0) break
                if (count == 0) {
                    delay(10)
                    continue
                }
                remaining -= count
            }
        }
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

internal fun needsMp3PlaybackFallback(mediaType: String?, url: String?): Boolean {
    val type = mediaType.orEmpty().lowercase()
    val path = url.orEmpty().substringBefore('?').lowercase()
    return type.isNotBlank() && type !in setOf("mp3", "mpeg") || path.endsWith(".flac")
}
