import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import java.util.Properties

plugins {
    alias(libs.plugins.androidApplication)
    // Keep sibling shared-module plugin versions visible when androidApp is imported as a
    // standalone Gradle root in IDEA. They remain unapplied to the Android application itself.
    alias(libs.plugins.androidMultiplatformLibrary) apply false
    alias(libs.plugins.kotlinMultiplatform) apply false
    alias(libs.plugins.kotlinSerialization) apply false
    alias(libs.plugins.composeMultiplatform) apply false
    alias(libs.plugins.composeCompiler)
}

kotlin {
    compilerOptions {
        jvmTarget = JvmTarget.JVM_11
    }
}

// Release signing is resolved up front but never required at configuration time, so unrelated
// tasks (debug APK, desktop packaging, CI) configure and run without a keystore.
val releaseKeystoreProperties = Properties().apply {
    val file = rootProject.file("keystore.properties")
    if (file.exists()) file.inputStream().use(::load)
}
val releaseStoreFile = providers.environmentVariable("LAZER_KEYSTORE_FILE")
    .orElse(releaseKeystoreProperties.getProperty("storeFile") ?: "")
    .get()
val releaseStorePassword = providers.environmentVariable("LAZER_KEYSTORE_PASSWORD")
    .orElse(releaseKeystoreProperties.getProperty("storePassword") ?: "")
    .get()
val releaseKeyAlias = providers.environmentVariable("LAZER_KEY_ALIAS")
    .orElse(releaseKeystoreProperties.getProperty("keyAlias") ?: "")
    .get()
val releaseKeyPassword = providers.environmentVariable("LAZER_KEY_PASSWORD")
    .orElse(releaseKeystoreProperties.getProperty("keyPassword") ?: "")
    .get()
val hasReleaseSigning = listOf(
    releaseStoreFile,
    releaseStorePassword,
    releaseKeyAlias,
    releaseKeyPassword,
).all(String::isNotBlank)

// Fail loudly only when a release artifact is actually requested, and point at the fix. A dedicated
// task keeps this out of configuration-time evaluation (CI builds without a keystore) and stays
// configuration-cache safe by capturing a plain Boolean.
val verifyReleaseSigning = tasks.register("verifyReleaseSigning") {
    val signingConfigured = hasReleaseSigning
    doLast {
        check(signingConfigured) {
            "Release signing is not configured. Set LAZER_KEYSTORE_FILE, " +
                "LAZER_KEYSTORE_PASSWORD, LAZER_KEY_ALIAS and LAZER_KEY_PASSWORD, " +
                "or create keystore.properties in the project root."
        }
    }
}
tasks.matching { it.name == "assembleRelease" || it.name == "bundleRelease" }.configureEach {
    dependsOn(verifyReleaseSigning)
}
dependencies {
    implementation(project(":shared"))

    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.core.ktx)
    implementation(libs.kotlinx.coroutines.android)

    implementation(libs.compose.animation)
    implementation(libs.compose.foundation)
    implementation(libs.compose.materialIconsExtended)
    implementation(libs.compose.material3)
    implementation(libs.miuix.ui)
    implementation(libs.compose.runtime)
    implementation(libs.compose.ui)
    implementation(libs.compose.uiToolingPreview)
    implementation(libs.coil.compose)
    implementation(libs.coil.network.ktor3)
    // Publishes real-time lyrics to the system SuperLyric service.
    implementation("com.github.HChenX:SuperLyricApi:3.4")
    debugImplementation(libs.compose.uiTooling)
    testImplementation(kotlin("test"))
    testImplementation(libs.junit)
}

android {
    namespace = "dev.naominet.lazer"
    compileSdk = libs.versions.android.compileSdk.get().toInt()

    defaultConfig {
        applicationId = "dev.naominet.lazer"
        minSdk = libs.versions.android.minSdk.get().toInt()
        targetSdk = libs.versions.android.targetSdk.get().toInt()
        versionCode = 1
        versionName = "1.0"

        // CI builds a slimmer APK for a single ABI (e.g. -PlazerAbis=arm64-v8a). Local builds keep
        // every ABI unless the property is supplied.
        providers.gradleProperty("lazerAbis").orNull
            ?.split(',')
            ?.map(String::trim)
            ?.filter(String::isNotEmpty)
            ?.takeIf(List<String>::isNotEmpty)
            ?.let { abis -> ndk { abiFilters.addAll(abis) } }
    }
    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = rootProject.file(releaseStoreFile)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }
    buildTypes {
        release {
            signingConfig = if (hasReleaseSigning) signingConfigs.getByName("release") else null
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    buildFeatures {
        compose = true
    }
}
