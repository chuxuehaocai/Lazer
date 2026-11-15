package dev.naominet.lazer

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import android.text.TextUtils
import kotlin.math.ceil
import kotlin.math.min
import kotlin.math.roundToInt

/** RemoteViews' restricted context cannot load custom TextView fonts. Render
 * only the text, using the same font assets Flutter already bundles. The host
 * tints the alpha mask for light/dark mode; the root retains its spoken label.
 */
internal object WidgetTypography {
    private var regular: Typeface? = null
    private var semibold: Typeface? = null

    // Called exclusively by the widget provider's serial worker.
    fun render(context: Context, text: String, widthDp: Float,
               sizeSp: Float, bold: Boolean, maxLines: Int): Bitmap {
        val typeface = if (bold) {
            semibold ?: load(context, "Semibold").also { semibold = it }
        } else {
            regular ?: load(context, "Regular").also { regular = it }
        }
        val width = widthDp.coerceAtLeast(1f)
        val scale = min(context.resources.displayMetrics.density, 768f / width)
        val pixels = (width * scale).roundToInt().coerceIn(1, 768)
        val paint = TextPaint(Paint.ANTI_ALIAS_FLAG or Paint.SUBPIXEL_TEXT_FLAG).apply {
            this.typeface = typeface
            color = Color.WHITE
            textSize = sizeSp * scale * context.resources.configuration.fontScale.coerceIn(0.85f, 1.3f)
            textLocale = context.resources.configuration.locales[0]
        }
        val layout = StaticLayout.Builder.obtain(text, 0, text.length, paint, pixels)
            .setAlignment(Layout.Alignment.ALIGN_NORMAL)
            .setIncludePad(true)
            .setMaxLines(maxLines)
            .setEllipsize(TextUtils.TruncateAt.END)
            .setBreakStrategy(Layout.BREAK_STRATEGY_SIMPLE)
            .build()
        // At most two lines of 14 sp text, with bounded raster dimensions.
        val height = min(layout.height, ceil(48f * scale).toInt()).coerceAtLeast(1)
        return Bitmap.createBitmap(pixels, height, Bitmap.Config.ARGB_8888).also {
            layout.draw(Canvas(it))
        }
    }

    private fun load(context: Context, weight: String) = Typeface.createFromAsset(
        context.assets, "flutter_assets/assets/fonts/MiSans-$weight.ttf")
}
