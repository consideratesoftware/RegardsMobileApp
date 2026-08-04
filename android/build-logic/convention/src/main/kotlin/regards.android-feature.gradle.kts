// Convention for :feature:* modules — android-library + Compose.
// Features depend on :domain, :designsystem, and the repository interfaces in
// :data. Importing androidx.room.* here is banned (ANDROID_PORT.md A2).
import com.android.build.gradle.LibraryExtension

plugins {
    id("regards.android-library")
    id("org.jetbrains.kotlin.plugin.compose")
}

configure<LibraryExtension> {
    buildFeatures {
        compose = true
    }
}
