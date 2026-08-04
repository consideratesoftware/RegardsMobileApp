// Room + SQLCipher. Repository INTERFACES live here too (parity with
// ios/Regards/Data/Repositories.swift). Android schema v1 = iOS §7 v1 + v2
// columns — see ANDROID_PORT.md A3. Room schemas are committed under schemas/.
plugins {
    id("regards.android-library")
    alias(libs.plugins.ksp)
}

android {
    namespace = "com.sdahiya.regards.data"
}

ksp {
    arg("room.schemaLocation", "$projectDir/schemas")
}

dependencies {
    api(project(":domain"))

    implementation(libs.room.runtime)
    implementation(libs.room.ktx)
    ksp(libs.room.compiler)
    implementation(libs.sqlcipher.android)
    implementation(libs.androidx.sqlite)

    testImplementation(libs.robolectric)
}
