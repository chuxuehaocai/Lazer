package dev.naominet.lazer

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews

/** Home-screen widget showing the device-local all-time play count. */
class PlayCountWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        manager: AppWidgetManager,
        ids: IntArray,
    ) {
        ids.forEach { update(context, manager, it) }
    }

    companion object {
        const val PREFS = "lazer_system_widgets"
        const val PLAY_COUNT = "play_count"

        fun update(context: Context, manager: AppWidgetManager, id: Int) {
            val count = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getInt(PLAY_COUNT, 0)
            val views = RemoteViews(context.packageName, R.layout.play_count_widget).apply {
                setTextViewText(R.id.play_count_value, count.toString())
                val intent = Intent(context, MainActivity::class.java)
                val pending = PendingIntent.getActivity(
                    context,
                    0,
                    intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
                setOnClickPendingIntent(R.id.play_count_root, pending)
            }
            manager.updateAppWidget(id, views)
        }

        fun refresh(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val component = android.content.ComponentName(context, PlayCountWidgetProvider::class.java)
            val ids = manager.getAppWidgetIds(component)
            ids.forEach { update(context, manager, it) }
        }
    }
}
