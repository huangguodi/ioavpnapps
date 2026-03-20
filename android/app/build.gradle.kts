plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
    id("org.jetbrains.kotlin.plugin.serialization")
}

android {
    namespace = "com.accelerator.tg"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }

    kotlinOptions {
        jvmTarget = "1.8"
    }

    sourceSets {
        getByName("main").java.srcDirs("src/main/kotlin")
        getByName("main").jniLibs.srcDirs("src/main/jniLibs")
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.accelerator.tg"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        ndk {
            // Filter for architectures supported by Flutter and your native libs
            abiFilters.add("arm64-v8a")
        }
        
        externalNativeBuild {
            cmake {
                cppFlags += "-std=c++17"
            }
        }
    }

    externalNativeBuild {
        cmake {
            path("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            
            // ProGuard/R8 Obfuscation
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            
            // O-LLVM / NDK Obfuscation Flags
            // 注意：标准的 NDK Clang 不支持 -mllvm -sub -mllvm -fla 等 O-LLVM 特有指令。
            // 如果你使用的是标准 NDK，这些标志会被忽略或报错。
            // 只有在使用定制的 O-LLVM 编译器链时才有效。
            // 此处配置假设环境已准备好 O-LLVM，或者作为示例展示如何传递标志。
            externalNativeBuild {
                cmake {
                    // Control Flow Flattening (-fla), Instruction Substitution (-sub), Bogus Control Flow (-bcf)
                    // cppFlags += "-mllvm -fla -mllvm -sub -mllvm -bcf"
                    // Strip symbols
                    arguments += "-DCMAKE_BUILD_TYPE=Release"
                }
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.6.0")
    implementation(platform("org.jetbrains.kotlin:kotlin-bom:1.8.0"))
    implementation(files("libs/classes.jar"))
}
