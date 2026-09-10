package dev.naominet.lazer.gateway

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class GatewayProviderSettingsTest {
    @Test
    fun normalizesProviderRootUrls() {
        assertEquals(DEFAULT_GATEWAY_BASE_URL, normalizeGatewayBaseUrl("music.naominet.dev/"))
        assertEquals("http://localhost:3000/api", normalizeGatewayBaseUrl(" HTTP://localhost:3000/api/ "))
        assertEquals("https://[::1]:3000", normalizeGatewayBaseUrl("https://[::1]:3000"))
    }

    @Test
    fun rejectsUnsafeOrIncompleteProviderUrls() {
        assertNull(normalizeGatewayBaseUrl(""))
        assertNull(normalizeGatewayBaseUrl("ftp://music.example.com"))
        assertNull(normalizeGatewayBaseUrl("https://user:password@music.example.com"))
        assertNull(normalizeGatewayBaseUrl("https://music.example.com?token=secret"))
        assertNull(normalizeGatewayBaseUrl("https://music.example.com/#fragment"))
    }
}
