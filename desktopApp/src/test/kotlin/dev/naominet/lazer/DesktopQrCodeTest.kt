package dev.naominet.lazer

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DesktopQrCodeTest {
    @Test
    fun `legacy Gateway login path is normalized without losing its session chain`() {
        val normalized = normalizeGatewayQrLoginUrl(
            "https://music.163.com/login?codekey=temporary-key&chainId=temporary-chain",
        )

        assertTrue(normalized.startsWith("https://music.163.com/st/platform/scanlogin?"))
        assertTrue(normalized.contains("codekey=temporary-key"))
        assertTrue(normalized.contains("chainId=temporary-chain"))
        assertTrue(normalized.contains("hdw_device=web"))
        assertFalse(normalized.contains("/login?"))
    }

    @Test
    fun `corrected login URL renders as a scannable bitmap`() {
        val bitmap = generateQrCodeBitmap(
            "https://music.163.com/st/platform/scanlogin?codekey=test&chainId=test",
            size = 128,
        )

        assertNotNull(bitmap)
    }
}
