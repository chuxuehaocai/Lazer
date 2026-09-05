package dev.naominet.lazer

import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.toComposeImageBitmap
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import org.jetbrains.skia.Image as SkiaImage
import java.awt.image.BufferedImage
import java.io.ByteArrayOutputStream
import java.net.URI
import javax.imageio.ImageIO

/**
 * The deployed Gateway currently emits a web QR URL with the legacy `/login` path. Keep its
 * codekey and chainId, but route the QR through NetEase's current web scan-login entry point.
 */
internal fun normalizeGatewayQrLoginUrl(rawUrl: String): String {
    val uri = runCatching { URI(rawUrl) }.getOrNull() ?: return rawUrl
    val query = uri.rawQuery.orEmpty()
    val hasChainId = query.split('&').any { parameter ->
        parameter.substringBefore('=') == "chainId" && parameter.substringAfter('=', "").isNotBlank()
    }
    if (!uri.host.equals("music.163.com", ignoreCase = true) || uri.path != "/login" || !hasChainId) {
        return rawUrl
    }

    val existingKeys = query.split('&').map { it.substringBefore('=') }.toSet()
    val additions = buildList {
        if ("hdw_device" !in existingKeys) add("hdw_device=web")
        if ("hdw_appid" !in existingKeys) add("hdw_appid=web")
        if ("hitExp" !in existingKeys) add("hitExp=1")
    }
    val normalizedQuery = (listOf(query) + additions).filter(String::isNotBlank).joinToString("&")
    return "${uri.scheme}://${uri.rawAuthority}/st/platform/scanlogin?$normalizedQuery"
}

/** Generates the corrected QR locally so no login identifier is sent to a third-party QR service. */
internal fun generateQrCodeBitmap(content: String, size: Int = 512): ImageBitmap? = runCatching {
    val matrix = QRCodeWriter().encode(
        content,
        BarcodeFormat.QR_CODE,
        size,
        size,
        mapOf(
            EncodeHintType.CHARACTER_SET to "UTF-8",
            EncodeHintType.MARGIN to 2,
            EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M,
        ),
    )
    val image = BufferedImage(size, size, BufferedImage.TYPE_INT_RGB)
    for (y in 0 until size) {
        for (x in 0 until size) {
            image.setRGB(x, y, if (matrix[x, y]) 0xFF000000.toInt() else 0xFFFFFFFF.toInt())
        }
    }
    val output = ByteArrayOutputStream()
    check(ImageIO.write(image, "png", output)) { "PNG encoder unavailable" }
    SkiaImage.makeFromEncoded(output.toByteArray()).toComposeImageBitmap()
}.getOrNull()
