package dev.naominet.lazer

import java.io.Closeable
import javax.sound.sampled.AudioFormat
import javax.sound.sampled.AudioSystem
import javax.sound.sampled.FloatControl
import kotlin.math.log10

/** The small output surface needed by the decoder, independent of shared or exclusive mode. */
internal interface DesktopPcmAudioOutput : Closeable {
    val isOpen: Boolean
    val isRunning: Boolean
    val availableBytes: Int
    val bufferSizeBytes: Int
    val longFramePosition: Long
    val usesSoftwareVolume: Boolean

    fun start()
    fun stop()
    fun flush()
    fun write(buffer: ByteArray, offset: Int, length: Int): Int
    fun setVolume(value: Float)
}

/** Existing Java Sound path used whenever exclusive output is disabled. */
internal class JavaSoundPcmAudioOutput(format: AudioFormat) : DesktopPcmAudioOutput {
    private val line = AudioSystem.getSourceDataLine(format).apply { open(format) }

    override val isOpen: Boolean
        get() = line.isOpen
    override val isRunning: Boolean
        get() = line.isRunning
    override val availableBytes: Int
        get() = line.available()
    override val bufferSizeBytes: Int
        get() = line.bufferSize
    override val longFramePosition: Long
        get() = line.longFramePosition
    override val usesSoftwareVolume: Boolean = false

    override fun start() = line.start()
    override fun stop() = line.stop()
    override fun flush() = line.flush()
    override fun write(buffer: ByteArray, offset: Int, length: Int): Int = line.write(buffer, offset, length)

    override fun setVolume(value: Float) {
        runCatching {
            val control = line.getControl(FloatControl.Type.MASTER_GAIN) as FloatControl
            val normalized = value.coerceIn(0f, 1f)
            val gain = if (normalized <= 0.0001f) {
                control.minimum
            } else {
                (20f * log10(normalized)).coerceIn(control.minimum, control.maximum)
            }
            control.value = gain
        }
    }

    override fun close() = line.close()
}

internal fun isWindowsDesktop(osName: String = System.getProperty("os.name").orEmpty()): Boolean =
    osName.contains("windows", ignoreCase = true)

