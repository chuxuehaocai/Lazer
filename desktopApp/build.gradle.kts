import org.jetbrains.compose.desktop.application.dsl.TargetFormat
import org.gradle.api.tasks.Copy
import org.gradle.api.tasks.Exec
import org.gradle.language.jvm.tasks.ProcessResources
import org.gradle.api.tasks.testing.Test
import org.jetbrains.compose.desktop.application.tasks.AbstractJPackageTask

val desktopOsName = System.getProperty("os.name").orEmpty().lowercase()
val desktopOsArch = System.getProperty("os.arch").orEmpty().lowercase()
val isWindowsHost = desktopOsName.contains("win")
val isLinuxHost = desktopOsName.contains("linux")
val isMacOSHost = desktopOsName.contains("mac") || desktopOsName.contains("darwin")
val hostWindowsArch = if (desktopOsArch.contains("aarch64") || desktopOsArch == "arm64") "arm64" else "x64"
val windowsArch = providers.gradleProperty("windowsArch").orElse(hostWindowsArch).get().lowercase()
require(windowsArch == "arm64" || windowsArch == "x64") {
    "windowsArch must be arm64 or x64, but was '$windowsArch'"
}
val nativeAudioArch = when {
    desktopOsArch.contains("aarch64") || desktopOsArch == "arm64" -> "arm64"
    desktopOsArch == "x86_64" || desktopOsArch == "amd64" || desktopOsArch == "x64" -> "x64"
    else -> "unsupported"
}
val nativeAudioPlatformId = when {
    isWindowsHost -> "windows-$windowsArch"
    isLinuxHost -> "linux-$nativeAudioArch"
    isMacOSHost -> "macos-$nativeAudioArch"
    else -> "unsupported"
}

plugins {
    alias(libs.plugins.kotlinJvm)
    alias(libs.plugins.composeMultiplatform)
    alias(libs.plugins.composeCompiler)
}

dependencies {
    implementation(project(":shared"))

    // Select the Windows native runtime explicitly with -PwindowsArch=arm64|x64.
    // The host architecture remains the default when no property is supplied.
    if (isWindowsHost) {
        val composeVersion = libs.versions.composeMultiplatform.get()
        if (windowsArch == "arm64") {
            implementation("org.jetbrains.compose.desktop:desktop-jvm-windows-arm64:$composeVersion")
        } else {
            implementation("org.jetbrains.compose.desktop:desktop-jvm-windows-x64:$composeVersion")
        }
    } else {
        implementation(compose.desktop.currentOs)
    }

    implementation(libs.compose.material3)
    implementation(libs.compose.materialIconsExtended)
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

val nativeBridgeBuildDir = layout.buildDirectory.dir("native/windows-taskbar")
val nativeBridgeFile = nativeBridgeBuildDir.map { it.file("Release/lazer-taskbar-bridge.dll") }
val nativeCmakeGenerator = providers.gradleProperty("nativeCmakeGenerator")
    .orElse(if (isWindowsHost) "Visual Studio 17 2022" else "").get()

val configureWindowsTaskbarBridge = tasks.register<Exec>("configureWindowsTaskbarBridge") {
    onlyIf("Windows host") { System.getProperty("os.name").contains("windows", ignoreCase = true) }
    inputs.dir(rootProject.layout.projectDirectory.dir("native/windows-taskbar"))
    outputs.dir(nativeBridgeBuildDir)
    val arguments = mutableListOf(
        "cmake",
        "-S", rootProject.layout.projectDirectory.dir("native/windows-taskbar").asFile.absolutePath,
        "-B", nativeBridgeBuildDir.get().asFile.absolutePath,
    )
    arguments += listOf("-G", nativeCmakeGenerator)
    if (nativeCmakeGenerator.contains("Visual Studio", ignoreCase = true)) arguments += listOf("-A", "x64")
    commandLine(arguments)
}

val buildWindowsTaskbarBridge = tasks.register<Exec>("buildWindowsTaskbarBridge") {
    onlyIf("Windows host") { System.getProperty("os.name").contains("windows", ignoreCase = true) }
    dependsOn(configureWindowsTaskbarBridge)
    inputs.dir(rootProject.layout.projectDirectory.dir("native/windows-taskbar"))
    outputs.file(nativeBridgeFile)
    commandLine("cmake", "--build", nativeBridgeBuildDir.get().asFile.absolutePath, "--config", "Release")
}

// The native FFmpeg engine is opt-in unless a DSD-capable SDK was configured. Linux/macOS use
// pkg-config metadata under FFMPEG_ROOT when supplied; Windows uses the supplied import package.
val nativeAudioBuildDir = layout.buildDirectory.dir("native/lazer-audio/$nativeAudioPlatformId")
val ffmpegRoot = providers.environmentVariable("FFMPEG_ROOT").orElse(providers.gradleProperty("lazerFfmpegRoot"))
val ffmpegLicenseDir = ffmpegRoot.orNull?.let { file("$it/share/lazer-ffmpeg") }
val buildNativeAudio = providers.gradleProperty("lazerNativeAudio")
    .map { it.toBoolean() }
    .orElse(ffmpegRoot.isPresent)
val nativeAudioFile = nativeAudioBuildDir.map {
    it.file(when {
        isWindowsHost -> "Release/lazer-audio.dll"
        isLinuxHost -> "liblazer-audio.so"
        isMacOSHost -> "liblazer-audio.dylib"
        else -> "unsupported"
    })
}

val configureLazerAudio = tasks.register<Exec>("configureLazerAudio") {
    inputs.file(rootProject.layout.projectDirectory.file("native/lazer-audio/CMakeLists.txt"))
    inputs.dir(rootProject.layout.projectDirectory.dir("native/lazer-audio/cmake"))
    inputs.dir(rootProject.layout.projectDirectory.dir("native/lazer-audio/src"))
    inputs.dir(rootProject.layout.projectDirectory.dir("native/lazer-audio/include"))
    outputs.dir(nativeAudioBuildDir)
    val arguments = mutableListOf(
        "cmake",
        "-S", rootProject.layout.projectDirectory.dir("native/lazer-audio").asFile.absolutePath,
        "-B", nativeAudioBuildDir.get().asFile.absolutePath,
        "-DLAZER_FFMPEG_ROOT=${ffmpegRoot.orNull.orEmpty()}",
        // CI's standalone CMake probes use the test-only ALSA null PCM route. Keep it out of any
        // Gradle-built distributable even when both builds share the same CMake cache directory.
        "-DLAZER_AUDIO_BUILD_PROBE=OFF",
        "-DLAZER_AUDIO_TEST_ALLOW_ALSA_NULL=OFF",
    )
    if (nativeCmakeGenerator.isNotBlank()) arguments += listOf("-G", nativeCmakeGenerator)
    if (isWindowsHost && nativeCmakeGenerator.contains("Visual Studio", ignoreCase = true)) {
        arguments += listOf("-A", windowsArch)
    }
    if (!isWindowsHost) arguments += listOf("-DCMAKE_BUILD_TYPE=Release")
    commandLine(arguments)
}

val buildLazerAudio = tasks.register<Exec>("buildLazerAudio") {
    dependsOn(configureLazerAudio)
    inputs.dir(rootProject.layout.projectDirectory.dir("native/lazer-audio/src"))
    outputs.file(nativeAudioFile)
    commandLine("cmake", "--build", nativeAudioBuildDir.get().asFile.absolutePath, "--config", "Release")
}

val prepareJpackageResources = tasks.register<Copy>("prepareJpackageResources") {
    from(layout.projectDirectory.dir("src/main/jpackage"))
    into(layout.buildDirectory.dir("generated/jpackage-resources"))
    if (isWindowsHost) {
        dependsOn(buildWindowsTaskbarBridge)
        from(nativeBridgeFile) { into("common/native/windows-x64") }
    }
    if (buildNativeAudio.get() && (isWindowsHost || isLinuxHost || isMacOSHost)) {
        require(nativeAudioArch != "unsupported") {
            "The native audio engine is not available for architecture '$desktopOsArch'"
        }
        dependsOn(buildLazerAudio)
        from(nativeAudioFile) { into("$nativeAudioPlatformId/native/$nativeAudioPlatformId") }
        from(nativeAudioBuildDir) {
            include("*.dll", "*.so", "*.so.*", "*.dylib", "*.dylib.*")
            exclude(nativeAudioFile.get().asFile.name)
            into("$nativeAudioPlatformId/native/$nativeAudioPlatformId")
        }
        if (isWindowsHost) {
            from(nativeAudioBuildDir.map { it.dir("Release") }) {
                include("*.dll")
                exclude(nativeAudioFile.get().asFile.name)
                into("$nativeAudioPlatformId/native/$nativeAudioPlatformId")
            }
        }
        if (!isWindowsHost) {
            require(ffmpegLicenseDir != null &&
                ffmpegLicenseDir.resolve("COPYING.LGPLv2.1").isFile &&
                ffmpegLicenseDir.resolve("BUILDINFO.txt").isFile) {
                "Bundling the native FFmpeg engine requires COPYING.LGPLv2.1 and BUILDINFO.txt " +
                    "under FFMPEG_ROOT/share/lazer-ffmpeg"
            }
            from(ffmpegLicenseDir!!) {
                include("COPYING.LGPLv2.1", "BUILDINFO.txt")
                into("$nativeAudioPlatformId/legal/ffmpeg")
            }
        }
    }
}

// A runnable Windows JAR embeds the bridge, while ordinary unit tests remain independent of a
// local C++ toolchain. CI enables this property for its Windows JAR artifact.
val embedTaskbarBridgeInJar = providers.gradleProperty("embedTaskbarBridge").isPresent()
if (isWindowsHost && embedTaskbarBridgeInJar) {
    tasks.named<ProcessResources>("processResources") {
        dependsOn(buildWindowsTaskbarBridge)
        from(nativeBridgeFile) { into("native/windows-x64") }
    }
}

// The runnable JAR resolves the optional HiFi engine from the classpath, and Compose's
// packageUberJarForCurrentOS only flattens the runtime classpath (it does not copy
// appResourcesRootDir), so a native-enabled Linux/macOS jar must embed the engine here.
// Windows keeps the bridge behind a dedicated property; the other hosts only build the
// engine when the native flag is present, so they key off that same flag.
if (buildNativeAudio.get() && (isLinuxHost || isMacOSHost)) {
    require(ffmpegLicenseDir != null &&
        ffmpegLicenseDir.resolve("COPYING.LGPLv2.1").isFile &&
        ffmpegLicenseDir.resolve("BUILDINFO.txt").isFile) {
        "Bundling the native FFmpeg engine requires COPYING.LGPLv2.1 and BUILDINFO.txt " +
            "under FFMPEG_ROOT/share/lazer-ffmpeg"
    }
    tasks.named<ProcessResources>("processResources") {
        dependsOn(buildLazerAudio)
        from(nativeAudioFile) { into("native/$nativeAudioPlatformId") }
        from(nativeAudioBuildDir) {
            include("Release/*.dll", "*.dll", "*.so", "*.so.*", "*.dylib", "*.dylib.*")
            exclude(nativeAudioFile.get().asFile.name)
            into("native/$nativeAudioPlatformId")
        }
        from(ffmpegLicenseDir!!) {
            include("COPYING.LGPLv2.1", "BUILDINFO.txt")
            into("legal/ffmpeg")
        }
    }
}

// Gradle's test workers are separate JVMs. Forward the optional native library override
// explicitly so smoke tests load the same library path as the Gradle invocation.
val lazerAudioLibraryForTests = providers.gradleProperty("lazerAudioLibrary")
tasks.withType<Test>().configureEach {
    lazerAudioLibraryForTests.orNull
        ?.takeIf { it.isNotBlank() }
        ?.let { systemProperty("lazer.audio.library", it) }
}

compose.desktop {
    application {
        mainClass = "dev.naominet.lazer.MainKt"
        jvmArgs += listOf("--enable-native-access=ALL-UNNAMED")

        nativeDistributions {
            // Shell links need stable on-disk ICO paths; jpackage places this directory at app/resources.
            appResourcesRootDir.set(layout.buildDirectory.dir("generated/jpackage-resources"))
            targetFormats(TargetFormat.Msi, TargetFormat.Deb, TargetFormat.Rpm)
            // jpackage's --name is both the installer display name and the Linux package name, and
            // Debian requires the lowercase reverse-DNS id, so only Windows drops it.
            packageName = if (isWindowsHost) "Lazer" else "dev.naominet.lazer"
            packageVersion = rootProject.extra["lazerPackageVersion"] as String
            // Runtime-only JDK APIs are not all visible to jdeps through Kotlin bytecode analysis.
            // Retain both the HTTP client used by DesktopAudioCache and the LAN source server.
            modules("java.net.http", "jdk.httpserver")
            buildTypes.release.proguard {
                // Runtime-discovered libraries such as Ktor engines cannot be safely inferred
                // by the shrinker. Keep release app images functionally identical to dev builds.
                isEnabled.set(false)
                configurationFiles.from(project.file("proguard-rules.pro"))
            }
            windows {
                iconFile = project.file("src/main/resources/icon.ico")
            }
            linux {
                iconFile = project.file("src/main/resources/icon.png")
                shortcut = true
                appCategory = "AudioVideo"
                menuGroup = "AudioVideo"
            }
        }
    }
}

// The native ALSA backend links against libasound.so.2. Compose's Linux DSL does not expose
// jpackage's package-dependency option, so add the runtime package requirement to DEB/RPM tasks
// only when the optional native engine is being packaged.
tasks.withType<AbstractJPackageTask>().configureEach {
    if (buildNativeAudio.get()) {
        when (targetFormat) {
            TargetFormat.Deb -> freeArgs.addAll(
                // Keep the alternative dependency as one token in Compose's jpackage args file.
                listOf("--linux-package-deps", "libasound2|libasound2t64"),
            )
            TargetFormat.Rpm -> freeArgs.addAll(
                listOf("--linux-package-deps", "alsa-lib"),
            )
            else -> Unit
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
    if (isWindowsHost) {
        dependsOn(buildWindowsTaskbarBridge)
        jvmArgs("-Dlazer.taskbar.bridge=${nativeBridgeFile.get().asFile.absolutePath}")
    }
    if (buildNativeAudio.get() && (isWindowsHost || isLinuxHost || isMacOSHost)) {
        require(nativeAudioArch != "unsupported") {
            "The native audio engine is not available for architecture '$desktopOsArch'"
        }
        dependsOn(buildLazerAudio)
        jvmArgs("-Dlazer.audio.library=${nativeAudioFile.get().asFile.absolutePath}")
    }
    mainClass.set("dev.naominet.lazer.MainKt")
    classpath = sourceSets["main"].runtimeClasspath
    standardInput = System.`in`
    // Skiko on JDK 21+ needs native access; match compose run defaults loosely.
    jvmArgs(
        "--enable-native-access=ALL-UNNAMED",
        // Gradle-run builds are development builds: show the debug watermark.
        "-Dlazer.debug=true",
    )
}

// The Compose `run` task is also a development run. Match lazily because the Compose plugin may
// register `run` after this script body is evaluated.
tasks.withType<JavaExec>().configureEach {
    if (name == "run") {
        jvmArgs("-Dlazer.debug=true")
        if (isWindowsHost) {
            dependsOn(buildWindowsTaskbarBridge)
            jvmArgs("-Dlazer.taskbar.bridge=${nativeBridgeFile.get().asFile.absolutePath}")
        }
        if (buildNativeAudio.get() && (isWindowsHost || isLinuxHost || isMacOSHost)) {
            require(nativeAudioArch != "unsupported") {
                "The native audio engine is not available for architecture '$desktopOsArch'"
            }
            dependsOn(buildLazerAudio)
            jvmArgs("-Dlazer.audio.library=${nativeAudioFile.get().asFile.absolutePath}")
        }
    }
}

tasks.configureEach {
    if (name.startsWith("package") || name.startsWith("create") || name == "prepareAppResources") {
        dependsOn(prepareJpackageResources)
    }
}
