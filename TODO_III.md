• Here’s a clear map of the Android Scenic driver path in this codebase and how you can split it for reuse (Android now, iOS later).

  Current code path (Scenic → Android render)

  1. Elixir driver (Scenic side)
      - lib/scenic/driver/android.ex
      - Implements Scenic.Driver callbacks.
      - Serializes scripts/media and sends them over a Unix domain socket to native.
      - Receives input events (touch/reshape) from native.
  2. Socket bridge + BEAM boot (Android native)
      - android/host/app/src/main/cpp/probnik_native.cpp
      - Starts BEAM release, exposes JNI hooks, runs a UNIX socket server.
      - Sends input events to the Elixir driver (touch/reshape).
      - Receives render commands from Elixir driver.
  3. Renderer (ported from scenic_driver_local)
      - android/host/app/src/main/cpp/scenic_local/*
      - This is the core renderer (script parsing + NanoVG + resource cache) adapted from scenic_driver_local.
      - Files: renderer_android.c, script.c, comms.c, image.c, font.c, nanovg_gl_impl.c, etc.
      - This is what translates Scenic script → GL calls.
  4. Java glue
      - android/host/app/src/main/java/com/probnik/
      - ProbnikGLSurfaceView, ProbnikRenderer, ProbnikNative JNI wrapper.
      - Handles EGL context + forwards touch to JNI.

  ———

  How to split for reuse (Android + future iOS)

  You can cleanly split the code into 3 layers:

  1. Platform‑independent renderer library
      - Move everything under android/host/app/src/main/cpp/scenic_local/
      - This is the “core Scenic renderer” (script parsing, layout, font/image cache).
      - This can become a separate repo like scenic_driver_core or similar.
  2. Platform adapter layer (thin, per‑OS)
      - Android: device_android.c, renderer_android.c, probnik_native.cpp socket glue.
      - iOS: you’ll write device_ios.mm (Metal or OpenGL ES), plus socket/input glue.
      - Both would “call into” the same core renderer library.
  3. Elixir driver (transport + input)
      - lib/scenic/driver/android.ex is platform‑specific only because of socket path and input types.
      - You could generalize this into a cross‑platform “socket driver”, and then just configure different socket paths per platform.
      - For iOS, you could reuse the same driver if the native side uses the same socket protocol.

  ———

  What can be pushed to a separate repo today

  ✅ Good candidates for a separate repo

  - android/host/app/src/main/cpp/scenic_local/ (core renderer)
  - android/host/app/src/main/cpp/scenic_local/*.c/*.h (script parsing, NanoVG, caches)
  - A generic “socket driver” on the Elixir side (if you generalize android.ex)

  🔧 Keep per‑app

  - probnik_native.cpp (BEAM boot + asset extraction + app‑specific paths)
  - android/host/app (Gradle app wrapper)
  - lib/probnik/scene/* UI

  ———

  Why this helps for iPhone

  - iOS needs a different graphics surface (UIKit + Metal/OpenGLES), but the core renderer can stay the same.
  - Only the device adapter + socket bridge are iOS‑specific.
  - Elixir driver can be reused if the socket protocol stays consistent.

  ———

  If you want, I can:

  1. Propose a repo layout for scenic_driver_core,
  2. Outline the minimal iOS adapter (Metal/OpenGLES + socket),
  3. Make the Elixir driver platform‑agnostic (Scenic.Driver.Socket).


