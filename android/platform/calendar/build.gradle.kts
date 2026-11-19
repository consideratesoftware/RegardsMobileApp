// CalendarContract occasion source. Local calendars only — OAuth is a permanent non-goal (§3).
plugins {
    id("regards.android-library")
}

android {
    namespace = "com.consideratesoftware.regards.platform.calendar"
}

dependencies {
    implementation(project(":domain"))
}
