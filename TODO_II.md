# Android Build (Path A) - Setup + Remaining Steps

## What we have now
- Android SDK detected at `/home/io/Android/Sdk`
- NDK installed at `/home/io/Android/Sdk/ndk/25.2.9519653`
- Java installed (OpenJDK 21): `/usr/lib/jvm/java-21-openjdk-amd64`
- Environment helper: `android/env.sh`
- OTP cross-compile script: `android/build_otp.sh`
- Release build script: `android/build_release.sh`
- NIF build script: `android/build_nifs.sh`
- Android host app (Gradle + GLES 3.0):
  - `android/host/...` with `HostActivity`, `GLSurfaceView`, and `Renderer`
  - NDK/CMake native lib (`probnik_native.cpp`)
  - Native hooks: `ProbnikNative.init/resize/render/destroy`

## Completed Steps

### 1) ✅ Compile Erlang/OTP for Android
- Built OTP 27.3.4.3 for `arm64-v8a`
- Location: `_install/android-arm64/usr/local/lib/erlang/`
- Disabled: wx, odbc, jinterface, termcap, megaco, debugger, observer
- Note: crypto skipped (no OpenSSL in sysroot)

### 2) ✅ Build Elixir release for Android
- Release: `_build/android/release/arm64-v8a/`
- Scenic NIFs cross-compiled for ARM64 (bitmap.so, line.so, matrix.so)
- File manifest generated for asset extraction

### 3) ✅ Package the release into the APK
- APK: `android/host/app/build/outputs/apk/debug/app-debug.apk` (45 MB)
- Erlang release in `assets/erlang/`
- Gradle task copies release before build

### 4) ✅ Native boot glue (C/C++)
- Asset extraction on first run (via file_manifest.txt)
- BEAM process started via fork/exec
- Environment variables set (ROOTDIR, BINDIR, HOME, etc.)
- Process lifecycle management (start/destroy)

### 5) ✅ Scenic GLES driver wiring
- `Scenic.Driver.Android` - Unix socket-based driver
- Socket server in native code
- Message protocol: clear_color, update_scene, delete_scripts, reset
- Runtime config auto-detects Android

### 6) ✅ Gradle/NDK wiring
- NDK version: 25.2.9519653
- ABI filter: arm64-v8a
- CMake 3.22.1
- C++17, GLES 3.0, EGL linked
- Debug/Release build types configured
- ProGuard rules

## APK build
```
cd android/host
./gradlew assembleDebug    # Debug APK (45 MB)
./gradlew assembleRelease  # Release APK (43 MB, unsigned)
```

## Full build sequence
```bash
# 1. Build OTP (one-time, ~5 min)
./android/build_otp.sh /path/to/otp-src

# 2. Build NIFs (quick)
./android/build_nifs.sh

# 3. Build release (quick)
./android/build_release.sh

# 4. Build APK
cd android/host && ./gradlew assembleDebug
```

## Known Limitations / TODO
- [ ] Full Scenic script rendering (currently only clear_color works)
- [ ] Touch input forwarding to Scenic
- [ ] Release signing for Play Store
- [ ] App icon and splash screen
- [ ] Handle BEAM process crashes gracefully
- [ ] Optimize APK size (strip ERTS, compress assets)
