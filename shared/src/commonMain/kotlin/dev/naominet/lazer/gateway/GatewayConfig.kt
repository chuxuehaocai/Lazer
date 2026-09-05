package dev.naominet.lazer.gateway

/**
 * Connection settings for an API Enhanced Gateway instance.
 *
 * The default points at the Gateway documented by the project. Applications can point this at
 * their own deployment instead, which is recommended for authenticated traffic.
 */
data class GatewayConfig(
    val baseUrl: String = "https://music.naominet.dev",
    val realIp: String? = null,
    val randomChineseIp: Boolean = true,
    val userAgent: String? = null,
    val requestTimeoutMillis: Long = DEFAULT_REQUEST_TIMEOUT_MILLIS,
) {
    init {
        val trimmedBaseUrl = baseUrl.trim()
        require(trimmedBaseUrl.startsWith("http://") || trimmedBaseUrl.startsWith("https://")) {
            "baseUrl must use HTTP or HTTPS."
        }
        require('?' !in trimmedBaseUrl && '#' !in trimmedBaseUrl) {
            "baseUrl must not contain query parameters or fragments."
        }
        require(requestTimeoutMillis > 0) { "requestTimeoutMillis must be greater than zero." }
    }

    internal val normalizedBaseUrl: String
        get() = baseUrl.trim().trimEnd('/')

    internal fun endpointUrl(path: String): String {
        require(path.startsWith('/') && !path.startsWith("//")) {
            "Gateway paths must start with one slash."
        }
        require("//" !in path && "://" !in path && '?' !in path && '#' !in path) {
            "Pass a relative Gateway path without query parameters or fragments."
        }
        return normalizedBaseUrl + path
    }

    public companion object {
        public const val DEFAULT_REQUEST_TIMEOUT_MILLIS: Long = 30_000
    }
}

/** Stores the Gateway session cookie independently from any platform-specific persistence layer. */
interface GatewaySessionStore {
    var cookie: String?
}

/** A simple session store suitable for a screen or application lifetime. */
class InMemoryGatewaySessionStore(
    override var cookie: String? = null,
) : GatewaySessionStore

/** The Gateway returned an HTTP error before a valid API response could be decoded. */
class GatewayHttpException(
    val statusCode: Int,
    val endpoint: String,
    val responseBody: String,
) : IllegalStateException("Gateway request to $endpoint failed with HTTP $statusCode.")

/** The Gateway returned a successful HTTP response that was not valid JSON. */
class GatewayProtocolException(
    val endpoint: String,
    cause: Throwable,
) : IllegalStateException("Gateway request to $endpoint returned malformed JSON.", cause)
