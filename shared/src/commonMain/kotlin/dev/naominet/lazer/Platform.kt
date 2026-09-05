package dev.naominet.lazer

interface Platform {
    val name: String
}

expect fun getPlatform(): Platform