// Android root settings. Module layout is ARCHITECTURE.md §12; see ANDROID_PORT.md A2.
pluginManagement {
    includeBuild("build-logic")
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "Regards"

include(":app")
include(":domain")
include(":data")
include(":designsystem")
include(":widget")

include(":feature:overdue")
include(":feature:upcoming")
include(":feature:contacts")
include(":feature:contact-detail")
include(":feature:edit-contact")
include(":feature:merge-duplicates")
include(":feature:onboarding")
include(":feature:settings")
include(":feature:paywall")

include(":platform:contacts")
include(":platform:calendar")
include(":platform:notifications")
include(":platform:deeplinks")
include(":platform:billing")
