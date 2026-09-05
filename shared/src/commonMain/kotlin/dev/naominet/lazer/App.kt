package dev.naominet.lazer

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeContentPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp

/** Shared compact interface used by Android and iOS hosts. */
@Composable
@Preview
fun App() {
    var isDark by remember { mutableStateOf(false) }
    var intent by remember { mutableStateOf("") }
    val suggestions = listOf("安静写作", "傍晚散步", "雨天慢歌")

    LazerTheme(isDark) {
        val colors = MaterialTheme.colorScheme
        Column(
            Modifier
                .fillMaxSize()
                .background(colors.background)
                .safeContentPadding()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp, vertical = 18.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    Modifier.size(38.dp).clip(RoundedCornerShape(12.dp)).background(colors.primaryContainer),
                    contentAlignment = Alignment.Center,
                ) {
                    Text("L", color = colors.onPrimaryContainer, fontWeight = FontWeight.Bold)
                }
                Spacer(Modifier.width(10.dp))
                Column {
                    Text("Lazer", style = MaterialTheme.typography.titleLarge)
                    Text("留一处给音乐", style = MaterialTheme.typography.labelSmall, color = colors.onSurfaceVariant)
                }
                Spacer(Modifier.weight(1f))
                Surface(
                    shape = CircleShape,
                    color = colors.surfaceVariant,
                    modifier = Modifier.clickable { isDark = !isDark },
                ) {
                    Text(
                        if (isDark) "浅色" else "深色",
                        style = MaterialTheme.typography.labelMedium,
                        modifier = Modifier.padding(horizontal = 13.dp, vertical = 9.dp),
                    )
                }
            }

            Spacer(Modifier.height(34.dp))
            Text("把此刻交给音乐。", style = MaterialTheme.typography.displaySmall)
            Spacer(Modifier.height(8.dp))
            Text(
                "不用记歌名，写下天气、心情或正在做的事。",
                style = MaterialTheme.typography.bodyLarge,
                color = colors.onSurfaceVariant,
            )
            Spacer(Modifier.height(22.dp))

            BasicTextField(
                value = intent,
                onValueChange = { intent = it },
                modifier = Modifier.fillMaxWidth().height(52.dp),
                singleLine = true,
                textStyle = MaterialTheme.typography.bodyMedium.copy(color = colors.onSurface),
                cursorBrush = SolidColor(colors.primary),
                decorationBox = { field ->
                    Row(
                        Modifier.fillMaxSize().clip(RoundedCornerShape(16.dp)).background(colors.surface).padding(horizontal = 16.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
                            if (intent.isEmpty()) {
                                Text("说一句你现在想听的", style = MaterialTheme.typography.bodyMedium, color = colors.onSurfaceVariant)
                            }
                            field()
                        }
                        Text("查找", style = MaterialTheme.typography.labelMedium, color = colors.primary)
                    }
                },
            )

            Spacer(Modifier.height(12.dp))
            Row(
                Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                suggestions.forEach { suggestion ->
                    Surface(
                        shape = RoundedCornerShape(11.dp),
                        color = colors.secondaryContainer,
                        modifier = Modifier.clickable { intent = suggestion },
                    ) {
                        Text(suggestion, style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(horizontal = 12.dp, vertical = 9.dp))
                    }
                }
            }

            Spacer(Modifier.height(30.dp))
            Text("今天为你整理", style = MaterialTheme.typography.headlineSmall)
            Spacer(Modifier.height(12.dp))
            listOf(
                "晨间的低饱和器乐" to "适合慢慢进入状态",
                "城市散步声景" to "熟悉、松弛、不过分热闹",
                "夜航电台" to "留给独处的一小时",
            ).forEachIndexed { index, (title, subtitle) ->
                Row(
                    Modifier.fillMaxWidth().padding(vertical = 9.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(
                        Modifier.size(52.dp).clip(RoundedCornerShape(15.dp))
                            .background(if (index == 1) colors.tertiaryContainer else colors.primaryContainer),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(title.first().toString(), color = if (index == 1) colors.onTertiaryContainer else colors.onPrimaryContainer)
                    }
                    Spacer(Modifier.width(13.dp))
                    Column(Modifier.weight(1f)) {
                        Text(title, style = MaterialTheme.typography.titleMedium)
                        Text(subtitle, style = MaterialTheme.typography.bodySmall, color = colors.onSurfaceVariant)
                    }
                    Text("播放", style = MaterialTheme.typography.labelMedium, color = colors.primary)
                }
            }
        }
    }
}
