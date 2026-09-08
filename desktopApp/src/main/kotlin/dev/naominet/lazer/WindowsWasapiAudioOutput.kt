package dev.naominet.lazer

import com.sun.jna.Function
import com.sun.jna.Memory
import com.sun.jna.Native
import com.sun.jna.Pointer
import com.sun.jna.platform.win32.Guid
import com.sun.jna.platform.win32.Ole32
import com.sun.jna.ptr.IntByReference
import com.sun.jna.ptr.LongByReference
import com.sun.jna.ptr.PointerByReference
import java.io.IOException
import java.util.concurrent.Callable
import java.util.concurrent.ExecutionException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import javax.sound.sampled.AudioFormat
import kotlin.math.max

/**
 * Timer-driven WASAPI renderer. All COM and render-client calls stay on one MTA thread, including
 * every GetBuffer/ReleaseBuffer pair required by Core Audio.
 */
internal class WindowsWasapiAudioOutput(
    private val format: AudioFormat,
) : DesktopPcmAudioOutput {
    private val closed = AtomicBoolean(false)
    private val running = AtomicBoolean(false)
    private val audioThread = AtomicReference<Thread?>()
    private val executor: ExecutorService = Executors.newSingleThreadExecutor { task ->
        Thread(task, "lazer-wasapi-exclusive").apply {
            isDaemon = true
            audioThread.set(this)
        }
    }

    private var comInitialized = false
    private var enumerator: Pointer? = null
    private var device: Pointer? = null
    private var audioClient: Pointer? = null
    private var renderClient: Pointer? = null
    private var bufferFrameCount = 0
    private var frameSize = 0
    private var devicePeriodHundredNanos = 100_000L
    private var bufferDurationHundredNanos = 1_000_000L
    private var submittedFrames = 0L

    init {
        require(isWindowsDesktop()) { "WASAPI 仅可在 Windows 上使用" }
        try {
            onAudioThread { initialize() }
        } catch (error: Throwable) {
            closed.set(true)
            runCatching { onAudioThread { releaseNativeResources() } }
            executor.shutdownNow()
            throw IOException("无法独占当前音频设备，请关闭独占音频或检查系统声音设置", error.unwrapExecution())
        }
    }

    override val isOpen: Boolean
        get() = !closed.get() && audioClient != null && renderClient != null
    override val isRunning: Boolean
        get() = isOpen && running.get()
    override val availableBytes: Int
        get() = if (!isOpen) 0 else onAudioThread {
            (bufferFrameCount - currentPaddingFrames()).coerceAtLeast(0) * frameSize
        }
    override val bufferSizeBytes: Int
        get() = bufferFrameCount * frameSize
    override val longFramePosition: Long
        get() = if (!isOpen) submittedFrames else onAudioThread {
            (submittedFrames - currentPaddingFrames()).coerceAtLeast(0L)
        }
    override val usesSoftwareVolume: Boolean = true

    override fun start() {
        checkOpen()
        onAudioThread {
            if (!running.get()) {
                checkHResult(comCall(audioClientPointer(), IAudioClientStart)) { "启动独占音频失败" }
                running.set(true)
            }
        }
    }

    override fun stop() {
        if (!isOpen) return
        onAudioThread {
            if (running.getAndSet(false)) {
                checkHResult(comCall(audioClientPointer(), IAudioClientStop)) { "暂停独占音频失败" }
            }
        }
    }

    override fun flush() {
        if (!isOpen) return
        onAudioThread {
            if (running.getAndSet(false)) {
                checkHResult(comCall(audioClientPointer(), IAudioClientStop)) { "暂停独占音频失败" }
            }
            checkHResult(comCall(audioClientPointer(), IAudioClientReset)) { "清空独占音频缓冲区失败" }
            submittedFrames = 0L
        }
    }

    override fun write(buffer: ByteArray, offset: Int, length: Int): Int {
        checkOpen()
        require(offset >= 0 && length >= 0 && offset + length <= buffer.size) { "PCM 范围无效" }
        if (length == 0) return 0
        val alignedLength = length - length % frameSize
        if (alignedLength == 0) return 0
        return onAudioThread {
            var bytesWritten = 0
            while (bytesWritten < alignedLength && !closed.get()) {
                val availableFrames = (bufferFrameCount - currentPaddingFrames()).coerceAtLeast(0)
                if (availableFrames == 0) {
                    Thread.sleep(deviceWaitMillis())
                    continue
                }
                val remainingFrames = (alignedLength - bytesWritten) / frameSize
                val framesToWrite = minOf(availableFrames, remainingFrames)
                val nativeBuffer = PointerByReference()
                checkHResult(
                    comCall(renderClientPointer(), IAudioRenderClientGetBuffer, framesToWrite, nativeBuffer),
                ) { "获取独占音频缓冲区失败" }
                try {
                    nativeBuffer.value.write(
                        0,
                        buffer,
                        offset + bytesWritten,
                        framesToWrite * frameSize,
                    )
                } catch (error: Throwable) {
                    // Release an acquired packet even when copying fails.
                    comCall(
                        renderClientPointer(),
                        IAudioRenderClientReleaseBuffer,
                        framesToWrite,
                        AudioClientBufferFlagsSilent,
                    )
                    throw error
                }
                checkHResult(
                    comCall(renderClientPointer(), IAudioRenderClientReleaseBuffer, framesToWrite, 0),
                ) { "提交独占音频缓冲区失败" }
                bytesWritten += framesToWrite * frameSize
                submittedFrames += framesToWrite
            }
            bytesWritten
        }
    }

    /** Exclusive mode bypasses the Windows audio engine, so volume is applied to PCM upstream. */
    override fun setVolume(value: Float) = Unit

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        runCatching { onAudioThread { releaseNativeResources() } }
        executor.shutdownNow()
    }

    private fun initialize() {
        val waveFormat = waveFormatEx(format)
        frameSize = format.frameSize

        checkHResult(Ole32.INSTANCE.CoInitializeEx(Pointer.NULL, Ole32.COINIT_MULTITHREADED).toInt()) {
            "初始化 Windows 音频失败"
        }
        comInitialized = true

        val enumeratorReference = PointerByReference()
        checkHResult(
            Ole32.INSTANCE.CoCreateInstance(
                Guid.GUID(ClsidMmDeviceEnumerator),
                Pointer.NULL,
                ClsctxAll,
                Guid.GUID(IidMmDeviceEnumerator),
                enumeratorReference,
            ).toInt(),
        ) { "找不到 Windows 音频设备管理器" }
        enumerator = enumeratorReference.value

        val deviceReference = PointerByReference()
        checkHResult(
            comCall(
                enumeratorPointer(),
                IMmDeviceEnumeratorGetDefaultAudioEndpoint,
                ERender,
                EMultimedia,
                deviceReference,
            ),
        ) { "找不到默认音频输出设备" }
        device = deviceReference.value

        val clientReference = PointerByReference()
        val audioClientIid = Guid.GUID(IidAudioClient).apply { write() }
        checkHResult(
            comCall(devicePointer(), IMmDeviceActivate, audioClientIid.pointer, ClsctxAll, Pointer.NULL, clientReference),
        ) { "无法打开默认音频输出设备" }
        audioClient = clientReference.value

        checkHResult(
            comCall(
                audioClientPointer(),
                IAudioClientIsFormatSupported,
                AudioClientShareModeExclusive,
                waveFormat,
                Pointer.NULL,
            ),
        ) { "当前设备不支持这首歌的独占音频格式" }

        val defaultPeriod = LongByReference()
        val minimumPeriod = LongByReference()
        checkHResult(
            comCall(audioClientPointer(), IAudioClientGetDevicePeriod, defaultPeriod, minimumPeriod),
        ) { "无法读取音频设备周期" }
        devicePeriodHundredNanos = max(defaultPeriod.value, minimumPeriod.value).coerceAtLeast(10_000L)
        bufferDurationHundredNanos = (devicePeriodHundredNanos * 10L).coerceAtLeast(500_000L)

        checkHResult(
            comCall(
                audioClientPointer(),
                IAudioClientInitialize,
                AudioClientShareModeExclusive,
                0,
                bufferDurationHundredNanos,
                devicePeriodHundredNanos,
                waveFormat,
                Pointer.NULL,
            ),
        ) { "音频设备正在被占用，无法开启独占音频" }

        val bufferFrames = IntByReference()
        checkHResult(comCall(audioClientPointer(), IAudioClientGetBufferSize, bufferFrames)) {
            "无法读取独占音频缓冲区"
        }
        bufferFrameCount = bufferFrames.value.coerceAtLeast(1)

        val renderReference = PointerByReference()
        val renderClientIid = Guid.GUID(IidAudioRenderClient).apply { write() }
        checkHResult(
            comCall(audioClientPointer(), IAudioClientGetService, renderClientIid.pointer, renderReference),
        ) { "无法创建独占音频渲染器" }
        renderClient = renderReference.value
    }

    private fun releaseNativeResources() {
        if (audioClient != null && running.getAndSet(false)) {
            runCatching { comCall(audioClientPointer(), IAudioClientStop) }
        }
        listOf(renderClient, audioClient, device, enumerator).forEach { pointer ->
            if (pointer != null) runCatching { comCall(pointer, IUnknownRelease) }
        }
        renderClient = null
        audioClient = null
        device = null
        enumerator = null
        if (comInitialized) {
            Ole32.INSTANCE.CoUninitialize()
            comInitialized = false
        }
    }

    private fun currentPaddingFrames(): Int {
        val padding = IntByReference()
        checkHResult(comCall(audioClientPointer(), IAudioClientGetCurrentPadding, padding)) {
            "无法读取独占音频播放进度"
        }
        return padding.value.coerceIn(0, bufferFrameCount)
    }

    private fun deviceWaitMillis(): Long =
        (devicePeriodHundredNanos / 10_000L / 2L).coerceIn(1L, 20L)

    private fun checkOpen() {
        if (!isOpen) throw IOException("独占音频输出已经关闭")
    }

    private fun enumeratorPointer(): Pointer = enumerator ?: throw IOException("音频设备管理器未初始化")
    private fun devicePointer(): Pointer = device ?: throw IOException("默认音频设备未初始化")
    private fun audioClientPointer(): Pointer = audioClient ?: throw IOException("独占音频客户端未初始化")
    private fun renderClientPointer(): Pointer = renderClient ?: throw IOException("独占音频渲染器未初始化")

    private fun <T> onAudioThread(block: () -> T): T {
        if (Thread.currentThread() === audioThread.get()) return block()
        return try {
            executor.submit(Callable { block() }).get()
        } catch (error: ExecutionException) {
            throw error.cause ?: error
        }
    }

    private companion object {
        const val ClsidMmDeviceEnumerator = "{BCDE0395-E52F-467C-8E3D-C4579291692E}"
        const val IidMmDeviceEnumerator = "{A95664D2-9614-4F35-A746-DE8DB63617E6}"
        const val IidAudioClient = "{1CB9AD4C-DBFA-4C32-B178-C2F568A703B2}"
        const val IidAudioRenderClient = "{F294ACFC-3146-4483-A7BF-ADDCA7C260E2}"

        const val ClsctxAll = 23
        const val ERender = 0
        const val EMultimedia = 1
        const val AudioClientShareModeExclusive = 1
        const val AudioClientBufferFlagsSilent = 0x2

        const val IUnknownRelease = 2
        const val IMmDeviceEnumeratorGetDefaultAudioEndpoint = 4
        const val IMmDeviceActivate = 3
        const val IAudioClientInitialize = 3
        const val IAudioClientGetBufferSize = 4
        const val IAudioClientGetCurrentPadding = 6
        const val IAudioClientIsFormatSupported = 7
        const val IAudioClientGetDevicePeriod = 9
        const val IAudioClientStart = 10
        const val IAudioClientStop = 11
        const val IAudioClientReset = 12
        const val IAudioClientGetService = 14
        const val IAudioRenderClientGetBuffer = 3
        const val IAudioRenderClientReleaseBuffer = 4
    }
}

internal fun waveFormatEx(format: AudioFormat): Memory {
    require(format.encoding == AudioFormat.Encoding.PCM_SIGNED) { "独占音频只支持 PCM 音频" }
    require(format.sampleSizeInBits == 16) { "独占音频只支持 16 位 PCM" }
    require(!format.isBigEndian) { "Windows 独占音频只支持小端 PCM" }
    require(format.channels > 0 && format.sampleRate > 0f && format.frameSize > 0) { "PCM 音频格式无效" }
    require(format.frameSize == format.channels * 2) { "PCM 帧大小无效" }

    return Memory(WaveFormatExSize).apply {
        clear()
        setShort(0, WaveFormatPcm.toShort())
        setShort(2, format.channels.toShort())
        setInt(4, format.sampleRate.toInt())
        setInt(8, format.sampleRate.toInt() * format.frameSize)
        setShort(12, format.frameSize.toShort())
        setShort(14, format.sampleSizeInBits.toShort())
        setShort(16, 0)
    }
}

private fun comCall(instance: Pointer, vtableIndex: Int, vararg arguments: Any?): Int {
    val vtable = instance.getPointer(0)
    val address = vtable.getPointer(vtableIndex.toLong() * Native.POINTER_SIZE)
    val function = Function.getFunction(address, Function.ALT_CONVENTION)
    return function.invokeInt(arrayOf(instance, *arguments))
}

private inline fun checkHResult(result: Int, message: () -> String) {
    if (result < 0) throw IOException("${message()}（0x${result.toUInt().toString(16).uppercase()}）")
}

private tailrec fun Throwable.unwrapExecution(): Throwable =
    if (this is ExecutionException && cause != null) cause!!.unwrapExecution() else this

private const val WaveFormatExSize = 18L
private const val WaveFormatPcm = 1
