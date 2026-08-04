// Convention for Android library modules (data, designsystem, platform:*, widget).
import com.android.build.gradle.LibraryExtension
import org.jetbrains.kotlin.gradle.dsl.KotlinAndroidProjectExtension

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

configure<LibraryExtension> {
    compileSdk = 36 // TODO(AN-01): verify against current stable
    defaultConfig {
        minSdk = 28 // ARCHITECTURE.md §6 — java.time available natively, no desugaring
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

configure<KotlinAndroidProjectExtension> {
    jvmToolchain(17)
}
