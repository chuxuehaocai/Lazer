import org.jetbrains.compose.desktop.application.dsl.TargetFormat

plugins {
    alias(libs.plugins.kotlinJvm)
    alias(libs.plugins.composeMultiplatform)
    alias(libs.plugins.composeCompiler)
}

dependencies {
    implementation(project(":shared"))

    // Windows ARM64: explicit artifact. currentOs/host detection is broken on this platform
    // in several JetBrains tools (IDEA ComposeJvm runner, Kotlin/Native HostManager).
    val osName = System.getProperty("os.name").orEmpty().lowercase()
    val osArch = System.getProperty("os.arch").orEmpty().lowercase()
    val isWindowsArm = osName.contains("win") && (osArch.contains("aarch64") || osArch == "arm64")
    if (isWindowsArm) {
        implementation(compose.desktop.windows_arm64)
    } else {
        implementation(compose.desktop.currentOs)
    }

    implementation(compose.material3)
    implementation(compose.materialIconsExtended)
    implementation(libs.kotlinx.coroutinesSwing)
    implementation(libs.compose.uiToolingPreview)
    implementation(libs.zxing.core)
    implementation(libs.coil.compose)
    implementation(libs.coil.network.ktor3)
    implementation(libs.ktor.client.cio)
    implementation(libs.javamp3)
    implementation(libs.nucleus.media.control)
    testImplementation(libs.junit)
}

compose.desktop {
    application {
        mainClass = "dev.naominet.lazer.MainKt"
        jvmArgs += listOf("--enable-native-access=ALL-UNNAMED")

        nativeDistributions {
            targetFormats(TargetFormat.Dmg, TargetFormat.Msi, TargetFormat.Deb)
            packageName = "dev.naominet.lazer"
            packageVersion = "1.0.0"
            macOS {
                bundleID = "dev.naominet.lazer"
                appCategory = "public.app-category.music"
            }
        }
    }
}

/**
 * Plain JavaExec entry point for IntelliJ on Windows ARM64.
 *
 * IDEA's "desktopApp [jvm]" run config uses ComposeJvmRunConfigurationExtension, which
 * eventually hits Kotlin/Native HostManager.getHost() and throws:
 *   Unknown host target: windows aarch64
 *
 * This task is a normal Gradle JavaExec. Point an IDEA Gradle run configuration at
 * `runDesktop` (NOT the Compose-generated `run` gutter action).
 */
tasks.register<JavaExec>("runDesktop") {
    group = "application"
    description = "Run Lazer desktop (IDEA-safe on Windows ARM64)"
    dependsOn(tasks.named("classes"))
    mainClass.set("dev.naominet.lazer.MainKt")
    classpath = sourceSets["main"].runtimeClasspath
    standardInput = System.`in`
    // Skiko on JDK 21+ needs native access; match compose run defaults loosely.
    jvmArgs(
        "--enable-native-access=ALL-UNNAMED",
    )
}
