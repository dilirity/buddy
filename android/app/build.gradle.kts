plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.buddy.app"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.buddy.app"
        minSdk = 33
        targetSdk = 34
        versionCode = 1
        versionName = "0.1"
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    sourceSets {
        getByName("main") {
            assets.srcDir(layout.buildDirectory.dir("generated/brainAssets"))
        }
    }
}

// The brain is never checked in here: the APK gets a snapshot of the live
// evolved brain (~/.buddy/brain) when it exists, else the repo seed (brain/).
val brainSource: File = run {
    val buddyHome = System.getenv("BUDDY_HOME") ?: "${System.getProperty("user.home")}/.buddy"
    val live = File("$buddyHome/brain")
    if (live.isDirectory) live else rootProject.projectDir.resolve("../brain")
}

val syncBrainAssets = tasks.register<Copy>("syncBrainAssets") {
    from(brainSource) {
        exclude(".git/**")
        into("brain")
    }
    // SpriteSheet reads sprites.json from the assets root.
    from(File(brainSource, "sprites.json"))
    into(layout.buildDirectory.dir("generated/brainAssets"))
    doFirst {
        logger.lifecycle("brain assets from: $brainSource")
    }
}

tasks.named("preBuild") {
    dependsOn(syncBrainAssets)
}

dependencies {
    implementation("wang.harlon.quickjs:wrapper-android:3.2.0")
    implementation(files("libs/glyph-sdk.aar"))
}
