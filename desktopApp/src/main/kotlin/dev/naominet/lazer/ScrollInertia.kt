package dev.naominet.lazer

import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.onPointerEvent
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.pow

/**
 * Shared wheel/trackpad inertia used across lyric page and main lists.
 */
@Composable
fun rememberScrollInertiaController(): ScrollInertiaController {
    val scope = rememberCoroutineScope()
    val controller = remember { ScrollInertiaController() }
    LaunchedEffect(controller) {
        var last = 0L
        while (true) {
            withFrameNanos { now ->
                if (last == 0L) {
                    last = now
                    return@withFrameNanos
                }
                val dt = ((now - last) / 1_000_000_000.0).toFloat().coerceIn(0f, 0.05f)
                last = now
                val listState = controller.target
                val velocity = controller.velocity
                if (listState != null && abs(velocity) > 0.35f) {
                    val step = velocity * dt * 60f
                    scope.launch { listState.scrollBy(step) }
                    controller.velocity = velocity * 0.90f.pow(dt * 60f)
                    if (abs(controller.velocity) < 0.35f) controller.velocity = 0f
                }
            }
        }
    }
    return controller
}

class ScrollInertiaController {
    @Volatile
    var target: LazyListState? = null

    @Volatile
    var velocity: Float = 0f

    fun bind(listState: LazyListState) {
        target = listState
    }

    fun impulse(deltaY: Float) {
        velocity = (velocity + deltaY * 28f).coerceIn(-110f, 110f)
    }

    fun stop() {
        velocity = 0f
    }
}

@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun Modifier.scrollInertia(
    listState: LazyListState,
    controller: ScrollInertiaController,
    enabled: Boolean = true,
    onUserScroll: (() -> Unit)? = null,
): Modifier {
    val scope = rememberCoroutineScope()
    LaunchedEffect(listState) {
        controller.bind(listState)
    }
    if (!enabled) return this
    return this.onPointerEvent(PointerEventType.Scroll) { event ->
        val dy = event.changes.fold(0f) { acc, c -> acc + c.scrollDelta.y }
        if (dy != 0f) {
            event.changes.forEach { it.consume() }
            onUserScroll?.invoke()
            controller.bind(listState)
            controller.impulse(dy)
            scope.launch { listState.scrollBy(dy * 36f) }
        }
    }
}
