# Proposal: Android Support for scenic_driver_local

## Summary

Add Android platform support to `scenic_driver_local`, enabling Scenic applications to run on Android devices with full NanoVG rendering.

## Motivation

Scenic is an excellent framework for building UI applications in Elixir, but currently only supports desktop (via GLFW) and embedded Linux (via BCM/DRM). Adding Android support would:

- Enable Scenic apps on billions of Android devices
- Provide a path for mobile Elixir applications
- Lay groundwork for iOS support using the same architecture
- Expand Scenic's reach beyond desktop/embedded niches

## The Challenge: BEAM Process Isolation on Android

On Android, the BEAM VM cannot run inside the same process as the Android application due to:

1. **Android's app lifecycle** - Activities can be destroyed/recreated; BEAM needs persistence
2. **JNI threading constraints** - BEAM's scheduler doesn't play well with Android's main thread
3. **GL context ownership** - The EGL context must live in the Android render thread

This means the traditional **NIF-based approach won't work** for Android. The BEAM must run as a separate process, communicating with the Android GL surface via IPC.

## Proposed Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Android App Process                     │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────┐  │
│  │ Java/Kotlin │───▶│ JNI Bridge  │───▶│ NanoVG Renderer │  │
│  │  Activity   │    │ (C++)       │    │ (from scenic_   │  │
│  │  GLSurface  │◀───│ Socket Srv  │◀───│  driver_local)  │  │
│  └─────────────┘    └──────┬──────┘    └─────────────────┘  │
│                            │ Unix Socket                    │
│                            ▼                                │
│  ┌─────────────────────────────────────────────────────────┐│
│  │              BEAM Process (forked)                      ││
│  │  ┌─────────────────┐    ┌─────────────────────────────┐ ││
│  │  │ Scenic.Driver.  │───▶│ Your Scenic Application     │ ││
│  │  │ Android (socket)│◀───│ (Scenes, Components, etc.)  │ ││
│  │  └─────────────────┘    └─────────────────────────────┘ ││
│  └─────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────┘
```

### Socket Protocol

Simple binary protocol over Unix domain socket:

**Host → BEAM (input events):**
```
[type:u8][payload...]

Type 1: Touch - [action:u8][x:f32be][y:f32be]
Type 3: Reshape - [width:f32be][height:f32be]
```

**BEAM → Host (render commands):**
```
[type:u8][length:u32be][payload...]

Type 1: Clear Color - [r:f32][g:f32][b:f32][a:f32]
Type 2: Update Scene - [script_binary...]
Type 3: Delete Scripts - [script_ids...]
Type 4: Reset
Type 5: Put Font - [font_data...]
Type 6: Put Image - [image_data...]
```

## What Already Exists

I have a working proof-of-concept at [link to repo if public] with:

### Elixir Side
- `Scenic.Driver.Android` - Socket-based Scenic driver implementing all callbacks
- Serializes Scenic scripts to binary format matching `scenic_driver_local`'s internal format

### Native Side (C++)
- Ported `nvg_scenic.c`, `nvg_script_ops.c`, `nvg_font_ops.c`, `nvg_image_ops.c` from scenic_driver_local
- `android.cpp` - EGL initialization, socket server, touch input handling
- JNI bridge for Java integration

### Android Side (Java/Kotlin)
- GLSurfaceView with EGL context
- Touch event forwarding
- Asset extraction for BEAM release

## Proposed Changes to scenic_driver_local

### Option A: Integrated (Recommended)

Add Android as a new device backend alongside glfw/bcm/drm:

```
c_src/device/nvg/
├── android.c          # EGL init, socket server, input handling
├── android.h          # Android-specific declarations
└── (existing files remain unchanged)

lib/scenic/driver/
├── local.ex           # Existing NIF-based driver
└── android.ex         # New socket-based driver for Android
```

Build system changes:
- Detect Android NDK cross-compilation
- Conditional compilation for socket vs NIF communication
- Android-specific Makefile targets

### Option B: Separate Package

If the socket-based approach is too different from the NIF architecture:

```
scenic_driver_android/
├── c_src/
│   ├── renderer/      # Shared from scenic_driver_local (git submodule?)
│   └── android/       # Platform-specific code
├── lib/
│   └── scenic/driver/android.ex
└── mix.exs
```

This keeps scenic_driver_local focused on NIF-based platforms while allowing Android to evolve independently.

## Discussion Points

1. **Socket vs NIF**: Is a socket-based driver acceptable for inclusion, or should it be a separate package?

2. **Shared renderer code**: The NanoVG rendering code (`nvg_*.c`) is platform-agnostic. Should it be extracted to a shared location that both NIF and socket drivers can use?

3. **iOS future**: The same socket architecture would work for iOS. Should we design with this in mind?

4. **Script format**: Currently I'm replicating the internal script binary format. Is this format stable/documented, or should there be a more formal serialization layer?

5. **Crypto dependency**: Scenic depends on `:crypto` which requires OpenSSL. On Android, this means cross-compiling OpenSSL for the NDK. Any thoughts on making crypto optional for platforms where it's problematic?

## Working Demo

Current status of my implementation:
- [x] BEAM boots and runs on Android
- [x] Socket communication working
- [x] NanoVG rendering ported and functional
- [x] Touch input forwarded to Scenic
- [x] Fonts and images loading
- [ ] Full script coverage (basic shapes working, some edge cases remain)
- [ ] Crypto/distributed Erlang (requires OpenSSL cross-compilation)

Happy to share code, provide more details, or discuss alternative approaches. I believe Android support would be a valuable addition to the Scenic ecosystem.

## References

- [Scenic Framework](https://github.com/ScenicFramework/scenic)
- [scenic_driver_local](https://github.com/ScenicFramework/scenic_driver_local)
- [NanoVG](https://github.com/memononen/nanovg)
- [Android NDK](https://developer.android.com/ndk)
