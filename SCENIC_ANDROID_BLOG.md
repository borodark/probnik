# From Desktop Scenic to Android: the Probnik Journey

I started Probnik as a desktop Scenic app. The early goal was simple: build a BEAM diagnostics cockpit that feels more like an instrument panel than a dashboard. Scenic + `scenic_driver_local` made that easy: native window, OpenGL, fast redraws, no browser overhead. It worked, and it worked *fast*.

Then came the feedback from colleagues: “Can I run this on a tablet?” That question changed the architecture.

Desktop Scenic uses `scenic_driver_local`, which assumes the BEAM and the renderer live in the same OS process and can share a native window. That assumption breaks on Android. The Android lifecycle, threading model, and EGL context rules demand a separate render process. So we evolved from a local driver to a **remote driver** and then to a **native renderer library** we could carry across platforms.

This post is a guide to that evolution, and a practical map for building an Android Scenic application today—with Probnik as the example.

---

## Phase 1 — Desktop with `scenic_driver_local`

This phase is the quick win: Scenic on the desktop uses `scenic_driver_local` to open a native GLFW window and render via NanoVG/OpenGL. The BEAM and renderer share the same process, which keeps performance and latency extremely good.

At this point:
- UI lives in Elixir (Scenes + Components)
- Rendering happens in-process
- Input is fed back directly from the driver

It’s clean and very productive. But it doesn’t scale to Android.

---

## Phase 2 — Android forces an architectural split

Android breaks the local model:
- **GL context ownership** must stay in the Android render thread
- **Lifecycle** restarts Activities unpredictably
- **JNI threading constraints** don’t align with BEAM schedulers

That means the renderer must be isolated from the BEAM and controlled via IPC.

Here’s the actual architecture we implemented (using the existing diagram):

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

In short: the BEAM runs the app logic, the Android process owns OpenGL, and a socket bridges them.

---

## Phase 3 — Generalizing: `scenic_driver_remote` + `scenic_renderer_native`

Once the Android split worked, the next question was obvious: **can this be reusable?**

That led to two packages:

### 1) `scenic_driver_remote` (Elixir)
A transport‑agnostic Scenic driver that serializes scripts and sends them over IPC. It replaces the local driver with a socket protocol.

Key idea:
- Scenic is still Scenic.
- The “driver” just becomes a serializer + transport.

### 2) `scenic_renderer_native` (C)
A standalone renderer library that speaks the Scenic protocol and renders via NanoVG/OpenGL. It’s platform‑agnostic.

Key idea:
- Extract the rendering core from `scenic_driver_local` into a reusable C library.
- Provide platform adapters (Android, desktop, and future iOS).

Here’s the split in “how to reuse” terms:

```
Layer 1 — Platform‑independent renderer
  scenic_renderer_native (C)
  - script parsing
  - font/image cache
  - NanoVG render path

Layer 2 — Platform adapter (per OS)
  Android: EGL + JNI + socket server
  iOS: Metal/OpenGLES + socket glue (future)

Layer 3 — Elixir driver
  scenic_driver_remote
  - protocol serialization
  - transport (Unix socket/TCP/WebSocket)
```

This separation is what makes iPhone plausible.

---

## Why OpenGL UI at all? (Not games.)

We’re not advocating Scenic for games here. We’re using Scenic because:
- **Deterministic rendering**: frame-to-frame stability feels like an instrument, not a webpage.
- **Low overhead**: no browser, no DOM, no rendering bloat.
- **Hardware acceleration**: dense UI (gauges, graphs, meters) stays smooth.

For dashboards, diagnostics, and control panels, OpenGL‑driven UI can feel *cleaner* and more precise. It doesn’t replace web UI—but it does expand the boundaries.

That’s the novelty: **BEAM‑native UI with OpenGL speed**, on devices that normally never run Erlang.

---

## Using Probnik as the real example

Probnik’s current architecture mirrors this split:

- **`scenic_driver_local`** → used for desktop development and iteration
- **`scenic_driver_remote`** → Elixir driver that serializes Scenic scripts over socket
- **`scenic_renderer_native`** → C renderer that decodes the scripts and renders via NanoVG

The Android app is basically a thin host: it boots BEAM, sets up the socket, and hands GL to the renderer.

---

## Where this goes next: iPhone

Once the renderer is isolated, the only iOS‑specific work is:
- device adapter (Metal/OpenGLES + surface lifecycle)
- socket glue

The BEAM UI code stays the same. The renderer stays the same.

That’s the goal: a single Scenic UI codebase running across desktop, Android, and iPhone.

---

## Closing note

This approach is still unusual. It’s not for everyone. But if your UI is instrumentation‑heavy and you care about smoothness and visual stability more than the flexibility of HTML, Scenic + OpenGL is a serious option.

Probnik started as a desktop tool. It evolved because of colleague feedback and a device‑first UX need. That forced a driver split, which unexpectedly opened the door to a truly portable BEAM + OpenGL UI stack.

The next stop is iPhone.
