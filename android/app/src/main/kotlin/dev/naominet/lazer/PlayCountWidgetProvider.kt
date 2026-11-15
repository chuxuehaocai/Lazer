package dev.naominet.lazer

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.BitmapFactory
import android.os.Bundle
import android.os.Build
import android.util.AtomicFile
import android.util.SizeF
import android.view.View
import android.widget.RemoteViews
import java.io.File
import java.util.Locale
import java.util.concurrent.Executors

/** Keeps the original receiver identity so placed widgets migrate in place. */
class PlayCountWidgetProvider : AppWidgetProvider() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_LOCALE_CHANGED) {
            // MiSans text is rasterized, so a system language change must also
            // refresh widgets while the app is closed. Explicit app languages
            // still resolve through the persisted locale in update().
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, PlayCountWidgetProvider::class.java))
            if (ids.isNotEmpty()) onUpdate(context, manager, ids)
            return
        }
        super.onReceive(context, intent)
    }

    override fun onUpdate(
        context: Context,
        manager: AppWidgetManager,
        ids: IntArray,
    ) {
        val pending = goAsync()
        worker.execute {
            try { ids.forEach { update(context, manager, it) } }
            finally { pending.finish() }
        }
    }

    override fun onAppWidgetOptionsChanged(
        context: Context, manager: AppWidgetManager, id: Int, options: Bundle,
    ) {
        onUpdate(context, manager, intArrayOf(id))
    }

    companion object {
        const val PREFS = "lazer_system_widgets"
        private val worker = Executors.newSingleThreadExecutor()
        private const val ARTWORK = "recent-playback.png"

        // Flutter supplies a bounded PNG. Serialize disk work off the UI thread;
        // neither the widget nor its receiver does networking.
        fun publish(context: Context, data: Map<*, *>, done: (Exception?) -> Unit) {
            worker.execute {
                try {
                    val bytes = data["artwork"] as? ByteArray
                    val file = AtomicFile(File(context.filesDir, ARTWORK))
                    var hasArtwork = false
                    if (bytes != null && bytes.size <= 512 * 1024) {
                        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
                        if (bounds.outWidth in 1..256 && bounds.outHeight in 1..256) {
                            val output = file.startWrite()
                            try {
                                output.write(bytes)
                                file.finishWrite(output)
                                hasArtwork = true
                            } catch (error: Exception) {
                                file.failWrite(output)
                                throw error
                            }
                        }
                    }
                    if (!hasArtwork) file.delete()
                    context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                        .putBoolean("has_track", data["hasTrack"] == true)
                        .putString("title", (data["title"] as? String).orEmpty().take(512))
                        .putString("artist", (data["artist"] as? String).orEmpty().take(512))
                        .putString("language", data["language"] as? String ?: "system")
                        .putBoolean("has_artwork", hasArtwork)
                        .remove("play_count")
                        .commit()
                    val manager = AppWidgetManager.getInstance(context)
                    val ids = manager.getAppWidgetIds(ComponentName(context, PlayCountWidgetProvider::class.java))
                    ids.forEach { update(context, manager, it) }
                    done(null)
                } catch (error: Exception) { done(error) }
            }
        }

        private fun update(context: Context, manager: AppWidgetManager, id: Int) {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val language = prefs.getString("language", "system") ?: "system"
            val localized = if (language == "system") context else {
                val config = Configuration(context.resources.configuration)
                config.setLocale(Locale.forLanguageTag(language))
                context.createConfigurationContext(config)
            }
            val hasTrack = prefs.getBoolean("has_track", false)
            val title = if (hasTrack) prefs.getString("title", "").orEmpty()
                .ifBlank { localized.getString(R.string.widget_recent_playback) }
                else localized.getString(R.string.widget_recent_empty)
            val artist = if (hasTrack) prefs.getString("artist", "").orEmpty() else ""
            val artwork = if (prefs.getBoolean("has_artwork", false))
                BitmapFactory.decodeFile(File(context.filesDir, ARTWORK).path) else null
            val textImages = mutableListOf<android.graphics.Bitmap>()
            fun layout(size: SizeF): RemoteViews {
                val compact = size.width < 140 || size.height < 148
                val contentWidth = (size.width - if (compact) 16 else 32).coerceAtLeast(1f)
                // Color resources and text tints resolve in the widget host's
                // day/night configuration, independently of Flutter's theme.
                return RemoteViews(context.packageName,
                    if (compact) R.layout.play_count_widget_compact else R.layout.play_count_widget).apply {
                    setTextViewText(R.id.recent_title, title)
                    setInt(R.id.recent_title, "setMaxLines", if (hasTrack || compact) 1 else 2)
                    setTextViewText(R.id.recent_artist, artist)
                    val titleImage = WidgetTypography.render(localized, title, contentWidth,
                        if (compact) 12f else 14f, true, if (hasTrack || compact) 1 else 2)
                    textImages.add(titleImage)
                    setImageViewBitmap(R.id.recent_title_misans, titleImage)
                    setViewVisibility(R.id.recent_title, View.GONE)
                    setViewVisibility(R.id.recent_title_misans, View.VISIBLE)
                    setViewVisibility(R.id.recent_artist, View.GONE)
                    if (artist.isNotBlank()) {
                        val artistImage = WidgetTypography.render(localized, artist, contentWidth,
                            if (compact) 10f else 12f, false, 1)
                        textImages.add(artistImage)
                        setImageViewBitmap(R.id.recent_artist_misans, artistImage)
                        setViewVisibility(R.id.recent_artist_misans, View.VISIBLE)
                    } else {
                        setViewVisibility(R.id.recent_artist_misans, View.GONE)
                    }
                    setContentDescription(R.id.recent_app_icon, localized.getString(R.string.app_name))
                    setContentDescription(R.id.play_count_root, "$title $artist".trim())
                    setImageViewResource(R.id.recent_cover, android.R.color.transparent)
                    artwork?.let { setImageViewBitmap(R.id.recent_cover, it) }
                    val pending = PendingIntent.getActivity(context, 0,
                        Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP),
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                    setOnClickPendingIntent(R.id.play_count_root, pending)
                }
            }
            val options = manager.getAppWidgetOptions(id)
            val portrait = SizeF(options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 148).toFloat(),
                options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, 148).toFloat())
            val landscape = SizeF(options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH, 148).toFloat(),
                options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 148).toFloat())
            try {
                val views = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    // Render at the host's actual widths so text never stretches.
                    @Suppress("DEPRECATION")
                    val sizes = options.getParcelableArrayList<SizeF>(AppWidgetManager.OPTION_APPWIDGET_SIZES)
                        ?.filter { it.width > 0 && it.height > 0 }?.takeIf { it.isNotEmpty() }
                        ?: listOf(portrait, landscape)
                    RemoteViews(sizes.distinct().take(4).associateWith { layout(it) })
                } else {
                    RemoteViews(layout(landscape), layout(portrait))
                }
                manager.updateAppWidget(id, views)
            } finally {
                artwork?.recycle()
                textImages.forEach { it.recycle() }
            }
        }
    }
}
