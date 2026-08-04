// ContactsContract source + importer. systemContactRef = lookup key. Per-row fault tolerance (R35). Write-back only via partial-field ContentProviderOperation batches (§7).
plugins {
    id("regards.android-library")
}

android {
    namespace = "com.sdahiya.regards.platform.contacts"
}

dependencies {
    implementation(project(":domain"))
}
