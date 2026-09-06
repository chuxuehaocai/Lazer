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
    debugImplementation(libs.compose.uiTooling)
    testImplementation(kotlin("test"))
    testImplementation(libs.junit)
}

android {
    namespace = "dev.naominet.lazer"
    compileSdk = libs.versions.android.compileSdk.get().toInt()

    val releaseKeystorePropertiesFile = rootProject.file("keystore.properties")
    val releaseKeystoreProperties = Properties().apply {
        if (releaseKeystorePropertiesFile.exists()) {
            releaseKeystorePropertiesFile.inputStream().use(::load)
        }
    }
    val releaseStoreFile = providers.environmentVariable("LAZER_KEYSTORE_FILE")
        .orElse(releaseKeystoreProperties.getProperty("storeFile") ?: "")
    val releaseStorePassword = providers.environmentVariable("LAZER_KEYSTORE_PASSWORD")
        .orElse(releaseKeystoreProperties.getProperty("storePassword") ?: "")
    val releaseKeyAlias = providers.environmentVariable("LAZER_KEY_ALIAS")
        .orElse(releaseKeystoreProperties.getProperty("keyAlias") ?: "")
    val releaseKeyPassword = providers.environmentVariable("LAZER_KEY_PASSWORD")
        .orElse(releaseKeystoreProperties.getProperty("keyPassword") ?: "")
    val hasReleaseSigning = listOf(
        releaseStoreFile.get(),
        releaseStorePassword.get(),
        releaseKeyAlias.get(),
        releaseKeyPassword.get(),
    ).all(String::isNotBlank)

    defaultConfig {
        applicationId = "dev.naominet.lazer"
        minSdk = libs.versions.android.minSdk.get().toInt()
        targetSdk = libs.versions.android.targetSdk.get().toInt()
        versionCode = 1
        versionName = "1.0"
    }
    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = rootProject.file(releaseStoreFile.get())
                storePassword = releaseStorePassword.get()
                keyAlias = releaseKeyAlias.get()
                keyPassword = releaseKeyPassword.get()
            }
        }
    }
    buildTypes {
        release {
            check(hasReleaseSigning) {
                "Release signing is not configured. Set LAZER_KEYSTORE_FILE, " +
                    "LAZER_KEYSTORE_PASSWORD, LAZER_KEY_ALIAS and LAZER_KEY_PASSWORD, " +
                    "or create keystore.properties in the project root."
            }
            signingConfig = signingConfigs.getByName("release")
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
