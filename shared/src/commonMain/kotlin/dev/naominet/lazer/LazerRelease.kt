package dev.naominet.lazer

/**
 * Release facts the About page shows. Both Gradle build scripts read these literals out of this
 * file, so a version bump happens here and nowhere else — the number on screen and the number in
 * the APK or installer cannot disagree.
 */
object LazerRelease {
    const val name = "Lazer"
    const val versionName = "1.4"
    const val versionCode = 6

    /** Where the source lives. The About page links straight to it. */
    const val repositoryUrl = "https://github.com/chuxuehaocai/Lazer"

    /** The same address without its scheme, which is how the About page shows it. */
    const val repositoryLabel = "github.com/chuxuehaocai/Lazer"
}
