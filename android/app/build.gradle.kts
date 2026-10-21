import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Load signing config from environment variables (Build.sh sources
// ~/.beacon_release.env) or android/key.properties (local, gitignored)
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

// Environment variables take precedence over key.properties
val signingStoreFile = System.getenv("SIGNING_STORE_FILE") ?: keystoreProperties["storeFile"] as String?
val signingStorePassword = System.getenv("SIGNING_STORE_PASSWORD") ?: keystoreProperties["storePassword"] as String?
val signingKeyAlias = System.getenv("SIGNING_KEY_ALIAS") ?: keystoreProperties["keyAlias"] as String?
val signingKeyPassword = System.getenv("SIGNING_KEY_PASSWORD") ?: keystoreProperties["keyPassword"] as String?

android {
    namespace = "meshcorebeacon.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "meshcorebeacon.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            keyAlias = signingKeyAlias
            keyPassword = signingKeyPassword
            storeFile = signingStoreFile?.let { file(it) }
            storePassword = signingStorePassword
        }
    }

    buildTypes {
        release {
            // Without a release keystore (contributors), fall back to debug keys
            // so `flutter run --release` still works
            signingConfig = if (signingStoreFile != null) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
    testOptions {
        unitTests.isIncludeAndroidResources = true
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

dependencies {
    // WindowCompat.enableEdgeToEdge (MainActivity)
    implementation("androidx.core:core:1.18.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.17")
}
