allprojects {
    if (name == "app") {
        plugins.withId("com.android.application") {
            extensions.configure<com.android.build.gradle.AppExtension> {
                signingConfigs {
                    create("release") {
                        storeFile = file("${projectDir}/upload-keystore.jks")
                        storePassword = System.getenv("KEYSTORE_PASSWORD")
                        keyAlias = System.getenv("KEY_ALIAS")
                        keyPassword = System.getenv("KEY_PASSWORD")
                    }
                }
                buildTypes {
                    release {
                        signingConfig = signingConfigs.getByName("release")
                        isMinifyEnabled = true
                        isShrinkResources = true
                    }
                }
            }
        }
    }
}

