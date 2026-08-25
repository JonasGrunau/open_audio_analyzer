// `java` on its own resolves to Gradle's JavaPluginExtension inside a build
// script, not to the package, so `java.util.Properties()` fails to compile with
// "Unresolved reference 'util'" and seven cascading errors under it. Importing
// the class is the way round it.
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ---------------------------------------------------------------------------
// The upload key, and why the release build still works without it
//
// Google Play refuses a bundle signed with the debug key — by fingerprint, and
// at the end of the upload rather than at the start. Nothing in an .aab says
// which key signed it, so a debug-signed one is indistinguishable from a
// release-signed one until Play looks.
//
// The credential therefore arrives in a properties file that is never
// committed: `android/key.properties`, or wherever OAA_ANDROID_KEY_PROPERTIES
// points — which is how `packaging/android/make_aab.sh` keeps the keystore and
// its two passwords out of the checkout entirely, under $RUNNER_TEMP.
//
// **Absent, the release build signs with the debug key**, exactly as it did
// before there was an upload key at all. That is the same bargain
// `ios/Runner.xcodeproj` makes by staying on automatic signing: it is what
// keeps `flutter run --release` working for somebody who has never seen the
// credential, and a fork with no secrets still builds. What stops a
// debug-signed bundle reaching the Play Store is `make_aab.sh`, which does not
// hand one over — see its header.
//
// A file that exists and is missing a key fails here rather than at Play,
// because a null `storePassword` is not an error to Gradle: it signs with an
// empty password and produces a bundle nobody can verify.
val keyPropertiesFile =
    file(System.getenv("OAA_ANDROID_KEY_PROPERTIES") ?: "$rootDir/key.properties")
val keyProperties =
    Properties().apply {
        if (keyPropertiesFile.exists()) {
            keyPropertiesFile.inputStream().use { load(it) }
        }
    }

fun keyProperty(name: String): String =
    requireNotNull(keyProperties.getProperty(name)) {
        "$keyPropertiesFile has no `$name`. All four of storeFile, storePassword, " +
            "keyAlias and keyPassword are one credential."
    }

android {
    namespace = "com.openaudioanalyzer.oaa"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.openaudioanalyzer.oaa"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (!keyProperties.isEmpty) {
            create("release") {
                // Relative paths resolve against android/app/, which is where
                // this file sits. make_aab.sh writes an absolute one.
                storeFile = file(keyProperty("storeFile"))
                storePassword = keyProperty("storePassword")
                keyAlias = keyProperty("keyAlias")
                keyPassword = keyProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig =
                signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
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
