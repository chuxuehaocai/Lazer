import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing lives in `android/key.properties`, which is git-ignored, plus the
// keystore it points at. CI writes both from repository secrets; a working copy
// keeps them untracked next to this module. See docs/builds.md.
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseSigning = keystorePropertiesFile.isFile
val keystoreProperties = Properties().apply {
    if (hasReleaseSigning) {
        keystorePropertiesFile.inputStream().use { load(it) }
    }
}

// Tag builds set this so a missing keystore fails the build instead of quietly
// falling back to the debug key. Local builds never see it.
val requireReleaseSigning =
    (findProperty("lazerRequireReleaseSigning") as String?)?.toBoolean() ?: false

if (requireReleaseSigning && !hasReleaseSigning) {
    throw GradleException(
        "Release signing requested but ${keystorePropertiesFile.path} is missing. " +
            "Write key.properties and the keystore it points at, or unset " +
            "-PlazerRequireReleaseSigning.",
    )
}

android {
    namespace = "dev.naominet.lazer"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "dev.naominet.lazer"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = maxOf(flutter.minSdkVersion, 26)
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                // A relative storeFile is resolved against this module directory,
                // i.e. android/app/upload-keystore.jks.
                storeFile = file(keystoreProperties.getProperty("storeFile") ?: "upload-keystore.jks")
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword") ?: keystoreProperties.getProperty("storePassword")

                require(storePassword != null) { "key.properties is missing storePassword" }
                require(keyAlias != null) { "key.properties is missing keyAlias" }
            }
        }
    }

    buildTypes {
        release {
            // Real release key when key.properties exists; the debug key otherwise so
            // `flutter run --release` keeps working on a fresh checkout.
            signingConfig = signingConfigs.getByName(if (hasReleaseSigning) "release" else "debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
