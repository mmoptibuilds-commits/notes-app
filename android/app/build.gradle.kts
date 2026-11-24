import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.mmoptibuilds.notes"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    buildFeatures {
        resValues = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Stable identity: changing this would install as a different app.
        applicationId = "com.mmoptibuilds.notes"
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
        manifestPlaceholders["cloudAuthScheme"] = "com.mmoptibuilds.notes"
        resValue("string", "app_name", "Notes")
        resValue("string", "cloud_auth_scheme", "com.mmoptibuilds.notes")
    }

    val cloudTest = providers.gradleProperty("cloudTest").orNull == "true"
    if (cloudTest) {
        defaultConfig {
            applicationIdSuffix = ".cloudtest"
            manifestPlaceholders["cloudAuthScheme"] = "com.mmoptibuilds.notes.cloudtest"
            resValue("string", "app_name", "Notes (cloud test)")
            resValue("string", "cloud_auth_scheme", "com.mmoptibuilds.notes.cloudtest")
        }
    }

    // The release signing identity lives outside the repository. android/key.properties
    // (git-ignored) points at it: storeFile, storePassword, keyAlias, keyPassword.
    // Without it, release builds are blocked by the task-graph check below. Keep this
    // optional during configuration so debug builds and analysis do not need a key.
    val keyProps = Properties()
    val keyFile = rootProject.file("key.properties")
    if (keyFile.exists()) keyProps.load(keyFile.inputStream())

    val requiredSigningProperties = listOf(
        "storeFile",
        "storePassword",
        "keyAlias",
        "keyPassword",
    )
    val missingSigningProperties = requiredSigningProperties.filter {
        keyProps.getProperty(it)?.isNotBlank() != true
    }
    val configuredStoreFile = keyProps.getProperty("storeFile")
        ?.takeIf { it.isNotBlank() }
        ?.let { file(it) }
    val releaseSigningReady = keyFile.exists() &&
        missingSigningProperties.isEmpty() &&
        configuredStoreFile?.isFile == true

    signingConfigs {
        if (releaseSigningReady) {
            create("release") {
                storeFile = configuredStoreFile
                storePassword = keyProps.getProperty("storePassword")
                keyAlias = keyProps.getProperty("keyAlias")
                keyPassword = keyProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            if (releaseSigningReady) {
                signingConfig = signingConfigs.getByName("release")
            } else if (cloudTest) {
                signingConfig = signingConfigs.getByName("debug")
            }
        }
    }

    // Fail only for tasks that package/sign the release variant. The task graph is
    // available after project configuration, so debug builds and analyzer tasks can
    // still configure the Android project without release credentials.
    gradle.taskGraph.whenReady {
        val isReleasePackagingTask = allTasks.any { task ->
            task.project == project && task.name.matches(
                Regex("^(assemble|bundle|package|sign|validateSigning).*Release.*$"),
            )
        }
        if (isReleasePackagingTask && !cloudTest && !releaseSigningReady) {
            val missing = if (!keyFile.exists()) {
                "android/key.properties is missing"
            } else if (missingSigningProperties.isNotEmpty()) {
                "android/key.properties is missing non-blank values for: " +
                    missingSigningProperties.joinToString(", ")
            } else {
                "the configured storeFile does not exist"
            }
            throw GradleException(
                "Release signing is not configured: $missing. Configure the " +
                    "release keystore properties before running an Android release build.",
            )
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
