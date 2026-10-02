import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
val hasKeystoreProperties = keystorePropertiesFile.exists()
if (hasKeystoreProperties) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.expensetracker.hdfc"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    @Suppress("DEPRECATION")
    kotlinOptions {
        jvmTarget = "17"
    }

    defaultConfig {
        applicationId = "com.expensetracker.hdfc"
        minSdk = flutter.minSdkVersion
        targetSdk = 34
        versionCode = 2
        versionName = "1.1.1"
    }

    // Same applicationId, same app, different manifest merged in depending
    // on flavor. "standard" never declares READ_SMS; "recovery" adds it via
    // src/recovery/AndroidManifest.xml. Build with --flavor standard or
    // --flavor recovery; plain `flutter run` no longer works once any
    // flavor is defined.
    flavorDimensions += "feature"
    productFlavors {
        create("standard") {
            dimension = "feature"
        }
        create("recovery") {
            dimension = "feature"
        }
    }

    signingConfigs {
        if (hasKeystoreProperties) {
            create("stable") {
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
            }
        }
    }

    buildTypes {
        getByName("debug") {
            // Deliberately not the usual convention -- debug builds
            // normally use the machine's auto-generated debug keystore.
            // Pinning debug builds (what `flutter run` installs) to this
            // same stable keystore as release means the signature never
            // drifts between builds or machines, which is what actually
            // causes Android to force an uninstall-and-wipe instead of an
            // in-place update. Falls back to the normal debug key if
            // key.properties isn't set up yet, so a fresh checkout without
            // it still builds fine.
            if (hasKeystoreProperties) {
                signingConfig = signingConfigs.getByName("stable")
            }
        }
        getByName("release") {
            signingConfig = if (hasKeystoreProperties)
                signingConfigs.getByName("stable")
            else
                signingConfigs.getByName("debug")
            isMinifyEnabled = true
        }
    }
}

flutter {
    source = "../.."
}