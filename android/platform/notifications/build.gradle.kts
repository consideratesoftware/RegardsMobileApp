// NotificationScheduling impl, notification channels, boot/timezone/time-set receivers (AN-12). AlarmManager exact + WorkManager fallback (§9).
plugins {
    id("regards.android-library")
}

android {
    namespace = "com.sdahiya.regards.platform.notifications"
}

dependencies {
    implementation(project(":domain"))
}
