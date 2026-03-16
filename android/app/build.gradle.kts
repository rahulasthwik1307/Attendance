plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")

    // Firebase plugin (added)
    id("com.google.gms.google-services")
}

android {
    namespace = "com.example.attendance"
    compileSdk = flutter.compileSdkVersion

    ndkVersion = "27.0.12077973"

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.example.attendance"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {

    // Core library desugaring — required by flutter_local_notifications
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")

    // 🔥 Firebase BoM (added)
    implementation(platform("com.google.firebase:firebase-bom:34.10.0"))

    // 🔔 Firebase Cloud Messaging (added)
    implementation("com.google.firebase:firebase-messaging")

    // LiteRT (TensorFlow Lite new name)
    implementation("com.google.ai.edge.litert:litert:1.4.1")
    implementation("com.google.ai.edge.litert:litert-api:1.4.1")
    implementation("com.google.ai.edge.litert:litert-gpu:1.4.1")

    // Kotlin BOM to avoid stdlib conflicts
    implementation(platform("org.jetbrains.kotlin:kotlin-bom:1.8.0"))
}