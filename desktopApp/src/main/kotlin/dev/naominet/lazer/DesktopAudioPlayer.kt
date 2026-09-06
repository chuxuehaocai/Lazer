package dev.naominet.lazer

import fr.delthas.javamp3.Sound
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
import java.util.concurrent.atomic.AtomicReference
import javax.sound.sampled.AudioFormat
import javax.sound.sampled.AudioSystem
import javax.sound.sampled.FloatControl
import javax.sound.sampled.SourceDataLine
import kotlin.math.log10
import kotlin.math.roundToInt

private const val OutputWriteTimeoutNanos = 2_000_000_000L

/**
 * Small desktop streaming player. JavaMP3 decodes the growing cached MP3 stream, while PCM is
 * written to the operating system's default output device through [SourceDataLine].
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
        val safeFromProgress = playableSeekProgress(fromProgress, durationMillis)
        PlaybackDebugLog.event(
            "audio-play",
            "token=$token track=$trackId requested=$fromProgress from=$safeFromProgress duration=$durationMillis playing=$playWhenReady",
        )
        playbackJob = scope.launch {
            runCatching {
                stream(
                    url = url,
                    trackId = trackId,
                    cacheVariant = cacheVariant,
                    expectedBytes = expectedBytes,
                    durationMillis = durationMillis,
                    fromProgress = safeFromProgress,
                    token = token,
                )
            }.onFailure { error ->
                if (error !is CancellationException && token == generation.get()) {
                    PlaybackDebugLog.event(
                        "audio-failure",
                        "token=$token track=$trackId from=$safeFromProgress error=${error.playbackDebugSummary()}",
                    )
                    releaseActiveResources()
                    onError(token, error)
                }
            }
        }
        return token
    }

    fun pause() {
        paused = true
        PlaybackDebugLog.event("audio-pause", "token=${generation.get()}")
        runCatching { activeLine?.stop() }
    }

    fun resume() {
        paused = false
        PlaybackDebugLog.event("audio-resume", "token=${generation.get()}")
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
        // Sound is itself a lazy PCM InputStream: construction reads only enough MPEG data for
        // metadata and subsequent reads decode incrementally as the cache file grows.
        val decodedInput = Sound(cacheInput)
        activeInput = decodedInput
        val decodedFormat = decodedInput.audioFormat

        var line: SourceDataLine? = null
        var outputWatchdog: Job? = null
        try {
            // A PCM position must land on a complete sample frame. Dropping an arbitrary byte
            // count swaps sample bytes/channels after many seek positions and produces loud
            // static until the pipeline is rebuilt.
            val targetBytes = decodedSeekByteCount(
                durationMillis = durationMillis,
                progress = fromProgress,
                frameRate = decodedFormat.frameRate,
                frameSize = decodedFormat.frameSize,
            )
            if (!skipFully(decodedInput, targetBytes, token)) {
                throw IOException("跳转位置超出了音频内容")
            }
            if (!scope.isActive || token != generation.get()) return

            line = openOutputLine(decodedFormat)

            val buffer = ByteArray(16 * 1024)
            var lastProgressUpdate = 0L
            var consecutiveZeroReads = 0
            var endOfStream = false
            var outputRecoveries = 0
            val outputTimeline = OutputPlaybackTimeline(
                frameSize = decodedFormat.frameSize,
                frameRate = decodedFormat.frameRate,
            )
            val seekFadeIn = PcmSeekFadeIn(decodedFormat).takeIf { fromProgress > 0f }
            val writeInProgress = AtomicReference<SourceDataLine?>(null)
            val writeStartedAtNanos = AtomicLong(0L)

            fun playedMillis(): Long {
                val currentFrames = line?.longFramePosition ?: 0L
                return outputTimeline.playedMillis(currentFrames)
            }

            // SourceDataLine.write is a blocking Java call. Some Windows audio drivers neither
            // return zero nor throw when their endpoint stops responding, so the normal retry
            // branch would never run. Closing that exact stalled line unblocks write and lets the
            // existing bounded output-line recovery reopen it.
            outputWatchdog = scope.launch {
                while (isActive && token == generation.get()) {
                    delay(100)
                    val output = writeInProgress.get() ?: continue
                    val startedAt = writeStartedAtNanos.get()
                    if (
                        startedAt > 0L &&
                        System.nanoTime() - startedAt >= OutputWriteTimeoutNanos &&
                        writeInProgress.compareAndSet(output, null)
                    ) {
                        PlaybackDebugLog.event(
                            "audio-output-stall",
                            "token=$token track=$trackId open=${output.isOpen} running=${output.isRunning}",
                        )
                        closeOutputLine(output)
                    }
                }
            }

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
                    if (shouldCompleteAfterEof(durationMillis, fromProgress, playedMillis())) {
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
                        // A streaming decoder can yield empty reads while the cache is growing;
                        // back off briefly, but never spin forever on a truncated source.
                        consecutiveZeroReads += 1
                        if (consecutiveZeroReads >= 40) {
                            if (shouldCompleteAfterEof(durationMillis, fromProgress, playedMillis())) {
                                endOfStream = true
                                break
                            }
                            throw IOException("音频流暂时没有返回数据")
                        }
                        delay(15)
                        continue
                    }
                    else -> {
                        consecutiveZeroReads = 0
                        // Even a frame-aligned seek can begin at a non-zero waveform value. A
                        // short ramp removes that discontinuity without making the seek sound
                        // delayed or changing normal playback from the beginning.
                        seekFadeIn?.apply(buffer, count)
                    }
                }

                var written = 0
                var zeroWrites = 0
                while (written < count && token == generation.get() && scope.isActive) {
                    if (paused) {
                        delay(20)
                        continue
                    }
                    val output = line ?: return
                    var writeError: Throwable? = null
                    writeStartedAtNanos.set(System.nanoTime())
                    writeInProgress.set(output)
                    val chunk = try {
                        output.write(buffer, written, count - written)
                    } catch (error: Throwable) {
                        writeError = error
                        0
                    } finally {
                        writeInProgress.compareAndSet(output, null)
                        writeStartedAtNanos.set(0L)
                    }
                    if (chunk > 0) {
                        written += chunk
                        outputTimeline.onBytesSubmitted(chunk)
                        zeroWrites = 0
                    } else {
                        zeroWrites += 1
                        val shouldReopen = shouldRecoverAudioOutput(
                            writeError = writeError,
                            outputOpen = output.isOpen,
                            consecutiveZeroWrites = zeroWrites,
                        )
                        if (shouldReopen && outputRecoveries < 3) {
                            PlaybackDebugLog.event(
                                "audio-output-recover",
                                "token=$token track=$trackId attempt=${outputRecoveries + 1} open=${output.isOpen} running=${output.isRunning} available=${runCatching { output.available() }.getOrDefault(-1)} written=$written count=$count error=${writeError?.playbackDebugSummary().orEmpty()}",
                            )
                            outputTimeline.onLineReplaced()
                            closeOutputLine(output)
                            if (!scope.isActive || token != generation.get()) return
                            line = openOutputLine(decodedFormat)
                            outputRecoveries += 1
                            zeroWrites = 0
                            continue
                        }
                        if (shouldReopen) {
                            throw IOException("系统音频输出停止响应", writeError)
                        }
                        if (!output.isRunning) runCatching { output.start() }
                        delay(10)
                    }
                }
                if (endOfStream) break

                val now = System.nanoTime()
                if (durationMillis > 0L && now - lastProgressUpdate >= 33_000_000L) {
                    val progress = fromProgress + playedMillis().toFloat() / durationMillis.toFloat()
                    onProgress(token, progress.coerceIn(0f, 0.999f))
                    lastProgressUpdate = now
                }
            }

            if (token == generation.get() && endOfStream) {
                line?.let { drainWithTimeout(it, token, timeoutMs = 2_500) }
                val playedMillis = playedMillis()
                if (!shouldCompleteAfterEof(durationMillis, fromProgress, playedMillis)) {
                    throw IOException("音频连接提前结束，已停止播放以免误切到下一首")
                }
                onProgress(token, 1f)
                onCompleted(token)
            } else if (token == generation.get() && !scope.isActive) {
                // cancelled
            }
        } finally {
            outputWatchdog?.cancel()
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
        return discardDecodedBytes(input, bytes) {
            scope.isActive && token == generation.get()
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

    private fun openOutputLine(format: AudioFormat): SourceDataLine =
        AudioSystem.getSourceDataLine(format).also { opened ->
            activeLine = opened
            opened.open(format)
            applyVolume(opened)
            if (!paused) opened.start()
        }

    private fun closeOutputLine(line: SourceDataLine) {
        if (activeLine === line) activeLine = null
        runCatching { line.stop() }
        runCatching { line.flush() }
        runCatching { line.close() }
    }

    private fun stopCurrent() {
        val priorToken = generation.get()
        generation.incrementAndGet()
        if (priorToken > 0L) PlaybackDebugLog.event("audio-stop", "token=$priorToken")
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
        if (activeInput === input) activeInput = null
        closeOutputLine(line)
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

/**
 * Keeps all user seek entry points inside the decodable tail. Track metadata and decoded MP3
 * duration commonly differ by encoder padding, so the final second is a playback destination,
 * not a safe place from which to construct a fresh decoder.
 */
internal fun playableSeekProgress(progress: Float, durationMillis: Long): Float {
    if (durationMillis <= 0L) return 0f
    val latestSeekMillis = (durationMillis - 1_000L).coerceAtLeast(0L)
    val latestProgress = latestSeekMillis.toDouble() / durationMillis.toDouble()
    return progress.coerceIn(0f, 1f).coerceAtMost(latestProgress.toFloat())
}

/** Converts a playback fraction to a whole PCM frame boundary. */
internal fun decodedSeekByteCount(
    durationMillis: Long,
    progress: Float,
    frameRate: Float,
    frameSize: Int,
): Long {
    if (durationMillis <= 0L || frameRate <= 0f || frameSize <= 0) return 0L
    val frames = (durationMillis / 1_000.0 * frameRate * playableSeekProgress(progress, durationMillis))
        .toLong()
        .coerceAtLeast(0L)
    return frames * frameSize.toLong()
}

/** Applies a click-free ramp to the first few milliseconds after a seek. */
internal class PcmSeekFadeIn(
    private val format: AudioFormat,
    durationMillis: Int = 8,
) {
    private val supported = format.encoding == AudioFormat.Encoding.PCM_SIGNED &&
        format.sampleSizeInBits == 16 &&
        format.frameSize >= 2 &&
        format.frameSize % 2 == 0
    private val totalFrames = if (supported) {
        (format.frameRate * durationMillis / 1_000f).roundToInt().coerceAtLeast(2)
    } else {
        0
    }
    private var processedFrames = 0

    fun apply(buffer: ByteArray, byteCount: Int) {
        if (!supported || byteCount <= 0 || processedFrames >= totalFrames) return
        val availableFrames = byteCount.coerceAtMost(buffer.size) / format.frameSize
        val framesToFade = minOf(availableFrames, totalFrames - processedFrames)
        for (frameIndex in 0 until framesToFade) {
            val gain = processedFrames.toFloat() / (totalFrames - 1).toFloat()
            val frameOffset = frameIndex * format.frameSize
            for (sampleOffset in 0 until format.frameSize step 2) {
                val offset = frameOffset + sampleOffset
                val first = buffer[offset].toInt() and 0xFF
                val second = buffer[offset + 1].toInt() and 0xFF
                val raw = if (format.isBigEndian) {
                    (first shl 8) or second
                } else {
                    (second shl 8) or first
                }
                val sample = raw.toShort().toInt()
                val faded = (sample * gain).roundToInt().coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
                if (format.isBigEndian) {
                    buffer[offset] = (faded shr 8).toByte()
                    buffer[offset + 1] = faded.toByte()
                } else {
                    buffer[offset] = faded.toByte()
                    buffer[offset + 1] = (faded shr 8).toByte()
                }
            }
            processedFrames += 1
        }
    }
}

/**
 * Advances a decoded stream without calling InputStream.skip(). JavaMP3's Sound.skip() can lose
 * MPEG reservoir state and make the first frame after a seek crash in Decoder.samples_II.
 */
internal suspend fun discardDecodedBytes(
    input: java.io.InputStream,
    byteCount: Long,
    shouldContinue: () -> Boolean,
): Boolean {
    var remaining = byteCount.coerceAtLeast(0L)
    val discard = ByteArray(16 * 1024)
    while (remaining > 0 && shouldContinue()) {
        val count = input.read(
            discard,
            0,
            minOf(discard.size.toLong(), remaining).toInt(),
        )
        if (count < 0) return false
        if (count == 0) {
            delay(10)
            continue
        }
        remaining -= count
    }
    return remaining == 0L
}

/** Maintains one logical playback clock while the operating-system output line is replaced. */
internal class OutputPlaybackTimeline(
    private val frameSize: Int,
    private val frameRate: Float,
) {
    private var submittedFramesBeforeLine = 0L
    private var submittedBytesOnLine = 0L

    init {
        require(frameSize > 0) { "frameSize must be positive" }
        require(frameRate > 0f) { "frameRate must be positive" }
    }

    fun onBytesSubmitted(byteCount: Int) {
        if (byteCount > 0) submittedBytesOnLine += byteCount
    }

    fun onLineReplaced() {
        submittedFramesBeforeLine += submittedBytesOnLine / frameSize
        submittedBytesOnLine = 0L
    }

    fun playedMillis(currentLineFrames: Long): Long =
        ((submittedFramesBeforeLine + currentLineFrames.coerceAtLeast(0L)) /
            frameRate.toDouble() * 1_000.0).toLong()
}

internal fun shouldRecoverAudioOutput(
    writeError: Throwable?,
    outputOpen: Boolean,
    consecutiveZeroWrites: Int,
): Boolean = writeError != null || !outputOpen || consecutiveZeroWrites >= 8
