allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// flutter_quick_video_encoder (last published 2024, unmaintained since) hardcodes
// compileSdk 33 in its own Android module — too low for the androidx.fragment/core/
// lifecycle versions other, newer plugins now pull in, which require compileSdk 34+
// (AGP's AAR metadata check fails the build otherwise). Force every subproject
// (library plugins fetched from the pub cache, not just this app's own module) to
// compile against the same SDK the app itself already targets, matching how
// flutter_secure_storage's own compileSdk requirement is handled in app/build.gradle.kts.
subprojects {
    afterEvaluate {
        if (project.hasProperty("android")) {
            project.extensions.configure<com.android.build.gradle.BaseExtension> {
                compileSdkVersion(37)
            }
        }
    }
}

// Must come *after* the afterEvaluate hook above: this forces `:app` to be
// evaluated immediately, and Gradle rejects registering an afterEvaluate
// action on a project that has already been evaluated ("Cannot run
// Project.afterEvaluate(Action) when the project is already evaluated").
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
