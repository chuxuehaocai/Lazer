package dev.naominet.lazer

import androidx.compose.runtime.staticCompositionLocalOf

/**
 * Opacity applied to the app's own surfaces (background, cards, bars) when a custom background
 * wallpaper is active. The wallpaper itself is always drawn fully opaque; this value controls how
 * much of it shows through the UI. 1 = UI fully opaque (wallpaper hidden), 0 = UI fully
 * transparent (wallpaper fully visible). Text and icons are never affected.
 */
val LocalLazerUiAlpha = staticCompositionLocalOf { 1f }
