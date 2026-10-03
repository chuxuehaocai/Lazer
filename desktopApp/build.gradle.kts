import org.jetbrains.compose.desktop.application.dsl.TargetFormat
import org.gradle.api.tasks.Copy
import org.gradle.api.tasks.Exec
import org.gradle.language.jvm.tasks.ProcessResources

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

val isWindowsHost = System.getProperty("os.name").contains("windows", ignoreCase = true)
val nativeBridgeBuildDir = layout.buildDirectory.dir("native/windows-taskbar")
val nativeBridgeFile = nativeBridgeBuildDir.map { it.file("Release/lazer-taskbar-bridge.dll") }
val nativeCmakeGenerator = providers.gradleProperty("nativeCmakeGenerator").orElse("Visual Studio 17 2022").get()

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

val prepareJpackageResources = tasks.register<Copy>("prepareJpackageResources") {
    from(layout.projectDirectory.dir("src/main/jpackage"))
    into(layout.buildDirectory.dir("generated/jpackage-resources"))
    if (isWindowsHost) {
        dependsOn(buildWindowsTaskbarBridge)
        from(nativeBridgeFile) { into("common/native/windows-x64") }
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

compose.desktop {
    application {
        mainClass = "dev.naominet.lazer.MainKt"
        jvmArgs += listOf("--enable-native-access=ALL-UNNAMED")

        nativeDistributions {
            // Shell links need stable on-disk ICO paths; jpackage places this directory at app/resources.
            appResourcesRootDir.set(layout.buildDirectory.dir("generated/jpackage-resources"))
            targetFormats(TargetFormat.Msi, TargetFormat.Deb, TargetFormat.Rpm)
            packageName = "dev.naominet.lazer"
            packageVersion = rootProject.extra["lazerPackageVersion"] as String
            // DesktopAudioCache uses java.net.http.HttpClient via the JDK module API.
            // It is not visible to jdeps through the Kotlin bytecode analysis, so retain it
            // explicitly in jpackage's custom runtime image.
            modules("java.net.http")
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
    }
}

tasks.configureEach {
    if (name.startsWith("package") || name.startsWith("create") || name == "prepareAppResources") {
        dependsOn(prepareJpackageResources)
    }
}
