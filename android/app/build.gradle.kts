plugins {
    id("com.android.application")
}

android {
    namespace = "io.github.wasanyang.lumen"
    compileSdk = 36

    defaultConfig {
        applicationId = "io.github.wasanyang.lumen"
        minSdk = 29
        targetSdk = 36
        versionCode = 1
        versionName = "0.1"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            // Signed with the debug key until there is a release key; fine for installing on own devices.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation("androidx.activity:activity:1.11.0")
    implementation("androidx.webkit:webkit:1.14.0")
    testImplementation("junit:junit:4.13.2")
}

/**
 * Copies the files other platforms already keep in the repo into the app's assets, so there is one copy
 * of each: shared/blocklist.txt and the uBlock Origin Lite files LumenCore uses (same list as shared/copy-ubo.sh).
 */
abstract class CopySharedAssets : DefaultTask() {
    @get:InputFile abstract val blocklist: RegularFileProperty
    @get:InputDirectory abstract val uBOLite: DirectoryProperty
    @get:OutputDirectory abstract val outputDir: DirectoryProperty

    @TaskAction
    fun copy() {
        val out = outputDir.get().asFile
        out.deleteRecursively()
        blocklist.get().asFile.copyTo(File(out, "blocklist.txt"))
        val ubo = uBOLite.get().asFile
        val files = listOf("manifest.json", "LICENSE.txt") + listOf("main", "isolated").flatMap { world ->
            listOf("scriptlet-begin", "ublock-filters", "ublock-experimental", "scriptlet-end")
                .map { "rulesets/scripting/scriptlet/$world/$it.js" }
        }
        for (path in files) File(ubo, path).copyTo(File(out, "uBOLite/$path"))
    }
}

val copySharedAssets = tasks.register<CopySharedAssets>("copySharedAssets") {
    blocklist.set(rootProject.layout.projectDirectory.file("../shared/blocklist.txt"))
    uBOLite.set(rootProject.layout.projectDirectory.dir("../windows/Extensions/uBOLite"))
}

androidComponents {
    onVariants { variant ->
        variant.sources.assets?.addGeneratedSourceDirectory(copySharedAssets, CopySharedAssets::outputDir)
    }
}
