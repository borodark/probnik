# Android Build - Probnik (Scenic on Android)

This document describes how to build and run a Scenic/Elixir application on Android.
The architecture uses BEAM (Erlang VM) running as a native process, communicating with
an Android host app via Unix domain sockets for OpenGL ES 3.0 rendering.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                      Android APK                            │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────────┐          ┌─────────────────────────┐   │
│  │   Host App      │          │   BEAM Process          │   │
│  │   (Java/Kotlin) │          │   (Erlang/Elixir)       │   │
│  │                 │          │                         │   │
│  │  ┌───────────┐  │  Unix    │  ┌─────────────────┐    │   │
│  │  │ GLSurface │◄─┼─Socket───┼──│ Scenic.Driver.  │    │   │
│  │  │ View      │  │          │  │ Android         │    │   │
│  │  └───────────┘  │          │  └─────────────────┘    │   │
│  │                 │          │                         │   │
│  │  ┌───────────┐  │  fork/   │  ┌─────────────────┐    │   │
│  │  │ Native    │──┼──exec────┼─►│ erlexec         │    │   │
│  │  │ (C++)     │  │          │  └─────────────────┘    │   │
│  │  └───────────┘  │          │                         │   │
│  └─────────────────┘          └─────────────────────────┘   │
├─────────────────────────────────────────────────────────────┤
│                    assets/erlang/                           │
│  (ERTS + Elixir release + Scenic NIFs)                      │
└─────────────────────────────────────────────────────────────┘
```

## Prerequisites

- Android SDK (API 26+)
- Android NDK 25.2.9519653
- Java JDK 11+ (tested with OpenJDK 21)
- Erlang/OTP source (27.3.4.3)
- Elixir 1.15+

## Environment Setup

Source the environment script before any build steps:

```bash
source android/env.sh
```

This sets:
- `ANDROID_SDK_ROOT=/home/io/Android/Sdk`
- `ANDROID_NDK_ROOT=/home/io/Android/Sdk/ndk/25.2.9519653`
- `JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64`

---

## Step 1: Cross-Compile Erlang/OTP for Android

### Overview
Build OTP for ARM64 (arm64-v8a) using the Android NDK toolchain.

### Run
```bash
./android/build_otp.sh /path/to/otp-src
```

For example, if using kerl:
```bash
./android/build_otp.sh ~/.kerl/builds/27-wx/otp_src_27.3.4.3
```

### What it does
1. Copies OTP source to `_build/otp-android-src` (to avoid polluting the original)
2. Sets up NDK cross-compilation environment
3. Configures OTP with Android-specific flags:
   - `--host=aarch64-linux-android`
   - `--disable-jit` (no JIT on Android)
   - `--without-wx --without-odbc --without-jinterface`
   - `--without-termcap` (no curses on Android)
   - `--without-megaco --without-debugger --without-observer`
4. Builds and installs to `_install/android-arm64/usr/local/lib/erlang/`

### Output
```
_install/android-arm64/usr/local/lib/erlang/
├── bin/
│   ├── erl
│   ├── erlc
│   └── ...
├── erts-15.2.6.2/
│   ├── bin/
│   │   ├── beam.smp
│   │   └── erlexec
│   └── ...
└── lib/
    ├── stdlib-6.2.2/
    ├── kernel-10.2.2/
    └── ...
```

### Known Issues & Fixes
- **config.guess not found**: The correct path is `./erts/autoconf/config.guess`, not `./erts/config.guess`
- **No curses library**: Add `--without-termcap` to configure
- **crypto skipped**: No OpenSSL in Android sysroot (acceptable for now)

---

## Step 2: Build Elixir Release with Cross-Compiled NIFs

### Overview
Build the Elixir Mix release and cross-compile Scenic NIFs for ARM64.

### Run
```bash
# Build NIFs first
./android/build_nifs.sh

# Build release
./android/build_release.sh
```

### What build_nifs.sh does
1. Compiles Scenic native code (bitmap.c, line.c, matrix.c) for ARM64
2. Uses NDK clang with OTP headers for erl_nif.h
3. Outputs to `_build/android_nifs/arm64-v8a/`:
   - `bitmap.so`
   - `line.so`
   - `matrix.so`

### What build_release.sh does
1. Builds Mix release with `MIX_ENV=prod mix release android`
2. Copies ERTS from `_install/android-arm64/`
3. Replaces x86 NIFs with ARM64 versions
4. Generates `file_manifest.txt` (list of all files for extraction)
5. Outputs to `_build/android/release/arm64-v8a/`

### Output
```
_build/android/release/arm64-v8a/
├── bin/
│   └── probnik
├── erts-15.2.6.2/
├── lib/
│   ├── probnik-0.1.0/
│   ├── scenic-0.11.2/
│   │   └── priv/
│   │       ├── bitmap.so  (ARM64)
│   │       ├── line.so    (ARM64)
│   │       └── matrix.so  (ARM64)
│   └── ...
├── releases/
│   └── 0.1.0/
└── file_manifest.txt
```

### Mix Release Configuration (mix.exs)
```elixir
defp releases do
  [
    android: [
      include_executables_for: [],
      include_erts: false,
      steps: [:assemble],
      rel_templates_path: "rel/android"
    ]
  ]
end
```

---

## Step 3: Package Release into APK

### Overview
The Gradle build automatically copies the Erlang release into `assets/erlang/`
and packages it into the APK.

### Run
```bash
cd android/host
./gradlew assembleDebug    # Debug APK (~45 MB)
./gradlew assembleRelease  # Release APK (~43 MB, unsigned)
```

### Output
```
android/host/app/build/outputs/apk/
├── debug/
│   └── app-debug.apk
└── release/
    └── app-release-unsigned.apk
```

### How it works
The `copyErlangRelease` Gradle task (defined in `app/build.gradle`) runs before
each build and copies the release from `_build/android/release/arm64-v8a/` into
`src/main/assets/erlang/`.

```groovy
task copyErlangRelease(type: Copy) {
    from "${rootProject.projectDir}/../../_build/android/release/arm64-v8a"
    into "${projectDir}/src/main/assets/erlang"
    include "**/*"
}

preBuild.dependsOn copyErlangRelease
```

---

## Step 4: Native Boot Glue (C++)

### Overview
The native layer (`probnik_native.cpp`) handles:
1. Asset extraction from APK to internal storage
2. BEAM process startup via fork/exec
3. Unix socket server for IPC with Scenic driver
4. OpenGL ES rendering

### Key Components

#### Asset Extraction
On first run (or when manifest changes), extracts all files from `assets/erlang/`
to the app's internal storage (`/data/data/com.probnik/files/erlang/`).

Uses `file_manifest.txt` to enumerate files (Android AssetManager can't list
directories recursively).

#### BEAM Startup
```cpp
// Fork child process
pid_t pid = fork();
if (pid == 0) {
    // Child: exec erlexec
    execve(erlexec_path, argv, envp);
}
// Parent: continue and wait for socket connection
```

Environment variables set for BEAM:
- `ROOTDIR` - Erlang installation root
- `BINDIR` - ERTS bin directory
- `EMU` - Emulator name (beam.smp)
- `PROGNAME` - Program name (erl)
- `HOME` - Writable directory
- `ANDROID_ROOT` - Signals Android environment to Elixir

#### Unix Socket Server
Creates socket at `/data/data/com.probnik/cache/scenic.sock` for communication
with `Scenic.Driver.Android`.

Message format:
```
[type:1 byte][length:4 bytes (big-endian)][payload:N bytes]
```

Message types:
- `0x01` - clear_color (r, g, b, a as floats)
- `0x02` - update_scene (binary scene data)
- `0x03` - delete_scripts
- `0x04` - reset

### Files
- `app/src/main/cpp/probnik_native.cpp` - Main native implementation
- `app/src/main/cpp/CMakeLists.txt` - CMake build configuration
- `app/src/main/java/com/probnik/ProbnikNative.java` - JNI interface

### JNI Interface
```java
public class ProbnikNative {
    static { System.loadLibrary("probnik_native"); }

    public static native void init(AssetManager assetManager, String filesDir);
    public static native void resize(int width, int height);
    public static native void render();
    public static native void destroy();
}
```

---

## Step 5: Scenic GLES Driver

### Overview
Custom Scenic driver that communicates with the Android host via Unix socket.

### File
`lib/scenic/driver/android.ex`

### How it works
1. On start, connects to Unix socket at `/data/data/com.probnik/cache/scenic.sock`
2. Receives Scenic commands (clear, update_scene, etc.)
3. Serializes commands and sends to native layer
4. Native layer performs actual OpenGL rendering

### Message Protocol
```elixir
# Clear color
<<0x01, byte_size(payload)::32-big, r::float-32, g::float-32, b::float-32, a::float-32>>

# Update scene
<<0x02, byte_size(payload)::32-big, scene_binary::binary>>

# Delete scripts
<<0x03, 0::32>>

# Reset
<<0x04, 0::32>>
```

### Runtime Configuration
`config/runtime.exs` detects Android and configures the driver:

```elixir
is_android = System.get_env("ANDROID_ROOT") != nil or
             File.exists?("/system/build.prop")

if is_android do
  config :probnik, :viewport,
    name: :main_viewport,
    size: {1080, 1920},
    default_scene: Probnik.Scene.Main,
    drivers: [
      [
        module: Scenic.Driver.Android,
        name: :android,
        socket_path: "/data/data/com.probnik/cache/scenic.sock"
      ]
    ]
end
```

---

## Step 6: Gradle/NDK Configuration

### NDK Setup
- NDK Version: 25.2.9519653
- ABI: arm64-v8a only
- CMake: 3.22.1
- C++ Standard: C++17

### build.gradle Configuration
```groovy
android {
    namespace "com.probnik"
    compileSdk 34
    ndkVersion "25.2.9519653"

    defaultConfig {
        applicationId "com.probnik"
        minSdk 26
        targetSdk 34

        ndk {
            abiFilters "arm64-v8a"
        }

        externalNativeBuild {
            cmake {
                cppFlags "-std=c++17 -fexceptions"
                arguments "-DANDROID_STL=c++_shared"
            }
        }
    }

    externalNativeBuild {
        cmake {
            path "src/main/cpp/CMakeLists.txt"
            version "3.22.1"
        }
    }
}
```

### CMakeLists.txt
```cmake
cmake_minimum_required(VERSION 3.22.1)
project(probnik_native LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)

add_library(probnik_native SHARED probnik_native.cpp)

find_library(log-lib log)
find_library(android-lib android)
find_library(gles-lib GLESv3)
find_library(egl-lib EGL)

target_link_libraries(probnik_native
    ${log-lib}
    ${android-lib}
    ${gles-lib}
    ${egl-lib}
)
```

### ProGuard Rules
```proguard
# Keep JNI methods
-keepclasseswithmembernames class * {
    native <methods>;
}

# Keep the native interface class
-keep class com.probnik.ProbnikNative { *; }
-keep class com.probnik.HostActivity { *; }
-keep class com.probnik.ProbnikRenderer { *; }
-keep class com.probnik.ProbnikGLSurfaceView { *; }
```

---

## Full Build Sequence

```bash
# 1. Set up environment
source android/env.sh

# 2. Build OTP for Android (one-time, ~5-10 min)
./android/build_otp.sh /path/to/otp-src

# 3. Build NIFs (quick)
./android/build_nifs.sh

# 4. Build Elixir release (quick)
./android/build_release.sh

# 5. Build APK
cd android/host
./gradlew assembleDebug

# 6. Install on device
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

---

## Directory Structure

```
android/
├── env.sh              # Environment variables
├── build_otp.sh        # Cross-compile OTP script
├── build_nifs.sh       # Cross-compile NIFs script
├── build_release.sh    # Build Elixir release script
├── README.md           # This file
└── host/               # Android Studio project
    ├── build.gradle
    ├── settings.gradle
    ├── gradle.properties
    ├── local.properties
    └── app/
        ├── build.gradle
        ├── proguard-rules.pro
        └── src/main/
            ├── AndroidManifest.xml
            ├── java/com/probnik/
            │   ├── HostActivity.java
            │   ├── ProbnikGLSurfaceView.java
            │   ├── ProbnikRenderer.java
            │   └── ProbnikNative.java
            ├── cpp/
            │   ├── CMakeLists.txt
            │   └── probnik_native.cpp
            ├── res/
            └── assets/
                └── erlang/  (copied from _build at build time)

_build/
├── otp-android-src/    # OTP source copy for cross-compile
├── android_nifs/       # Cross-compiled NIFs
│   └── arm64-v8a/
└── android/
    └── release/
        └── arm64-v8a/  # Final Elixir release

_install/
└── android-arm64/      # Cross-compiled OTP installation
    └── usr/local/lib/erlang/
```

---

## Debugging

### View BEAM logs
```bash
adb logcat | grep -E "(PROBNIK|beam|erlang)"
```

### Check if BEAM is running
```bash
adb shell ps | grep beam
```

### Inspect extracted files
```bash
adb shell ls -la /data/data/com.probnik/files/erlang/
```

### Check socket
```bash
adb shell ls -la /data/data/com.probnik/cache/scenic.sock
```

---

## Known Limitations / TODO

- [ ] Full Scenic script rendering (currently only clear_color works)
- [ ] Touch input forwarding to Scenic
- [ ] Release signing for Play Store
- [ ] App icon and splash screen
- [ ] Handle BEAM process crashes gracefully
- [ ] Optimize APK size (strip ERTS, compress assets)
- [ ] Support armeabi-v7a (32-bit ARM)

---

## Troubleshooting

### "BEAM won't start"
- Check logcat for error messages
- Verify all files were extracted: `adb shell ls -la /data/data/com.probnik/files/erlang/erts-*/bin/`
- Ensure erlexec is executable

### "Socket connection failed"
- Verify BEAM is running
- Check socket path exists
- Look for connection errors in logcat

### "Black screen"
- BEAM may have crashed - check logcat
- Scenic driver may not be connecting
- OpenGL context may not be ready
