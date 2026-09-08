import org.jetbrains.compose.desktop.application.dsl.TargetFormat

plugins {
    alias(libs.plugins.kotlinJvm)
    alias(libs.plugins.composeMultiplatform)
    alias(libs.plugins.composeCompiler)
}

dependencies {
    implementation(project(":shared"))

    // Select the Windows native runtime explicitly with -PwindowsArch=arm64|x64.
    // The host architecture remains the default when no property is supplied.
    val osName = System.getProperty("os.name").orEmpty().lowercase()
    val osArch = System.getProperty("os.arch").orEmpty().lowercase()
    val hostWindowsArch = if (osArch.contains("aarch64") || osArch == "arm64") "arm64" else "x64"
    val windowsArch = providers.gradleProperty("windowsArch").orElse(hostWindowsArch).get().lowercase()
    require(windowsArch == "arm64" || windowsArch == "x64") {
        "windowsArch must be arm64 or x64, but was '$windowsArch'"
    }

    if (osName.contains("win")) {
        if (windowsArch == "arm64") {
            implementation(compose.desktop.windows_arm64)
        } else {
            implementation(compose.desktop.windows_x64)
        }
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
    implementation(libs.jna.core)
    implementation(libs.jna.platform)
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
            windows {
                iconFile = project.file("src/main/resources/icon.ico")
            }
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
