package dev.naominet.lazer

import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.ScrollableState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.onPointerEvent
import kotlin.math.abs
import kotlin.math.pow

/**
 * Shared wheel/trackpad inertia used across lyric page and main lists.
 */
@Composable
fun rememberScrollInertiaController(): ScrollInertiaController {
    val controller = remember { ScrollInertiaController() }
    LaunchedEffect(controller) {
        var previousFrameNs = 0L
        while (true) {
            withFrameNanos { now ->
                val dt = if (previousFrameNs == 0L) {
                    1f / 60f
                } else {
                    ((now - previousFrameNs) / 1_000_000_000.0).toFloat().coerceIn(0.001f, 0.05f)
                }
                previousFrameNs = now
                controller.advance(dt)
            }
        }
    }
    return controller
}

class ScrollInertiaController {
    private val motion = WheelInertiaMotion()
    private var target: ScrollableState? = null

    fun impulse(scrollState: ScrollableState, delta: Float) {
        if (target !== scrollState) {
            stop()
            target = scrollState
        }
        scrollState.dispatchRawDelta(motion.impulse(delta))
    }

    internal fun advance(dt: Float) {
        val movement = motion.advance(dt)
        if (movement != 0f) target?.dispatchRawDelta(movement)
    }

    fun stop() {
        motion.stop()
        target = null
    }
}

/** The exact wheel motion model shared by lyrics and every scrollable list. */
internal class WheelInertiaMotion {
    private var velocity = 0f

    fun impulse(delta: Float): Float {
        velocity = (velocity + delta * WheelInertiaDefaults.VelocityMultiplier)
            .coerceIn(-WheelInertiaDefaults.MaximumVelocity, WheelInertiaDefaults.MaximumVelocity)
        return delta * WheelInertiaDefaults.DirectMultiplier
    }

    fun advance(dt: Float): Float {
        if (abs(velocity) <= WheelInertiaDefaults.StopVelocity) {
            velocity = 0f
            return 0f
        }
        val movement = velocity * dt * 60f
        velocity *= WheelInertiaDefaults.DecayPerFrame.pow(dt * 60f)
        if (abs(velocity) < WheelInertiaDefaults.StopVelocity) velocity = 0f
        return movement
    }

    fun stop() {
        velocity = 0f
    }
}

internal object WheelInertiaDefaults {
    const val DirectMultiplier = 36f
    const val VelocityMultiplier = 28f
    const val MaximumVelocity = 110f
    const val StopVelocity = 0.35f
    const val DecayPerFrame = 0.90f
}

@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun Modifier.scrollInertia(
    scrollState: ScrollableState,
    controller: ScrollInertiaController,
    orientation: Orientation = Orientation.Vertical,
    enabled: Boolean = true,
    onUserScroll: (() -> Unit)? = null,
): Modifier {
    if (!enabled) return this
    return this.onPointerEvent(PointerEventType.Scroll) { event ->
        val delta = event.changes.fold(0f) { acc, change ->
            val scroll = change.scrollDelta
            acc + when (orientation) {
                Orientation.Vertical -> scroll.y
                // Keep a normal vertical wheel moving the surrounding page. Horizontal
                // trackpad/shift-wheel input belongs to the nested playlist strip.
                Orientation.Horizontal -> scroll.x
            }
        }
        if (delta != 0f) {
            event.changes.forEach { it.consume() }
            onUserScroll?.invoke()
            controller.impulse(scrollState, delta)
        }
    }
}
