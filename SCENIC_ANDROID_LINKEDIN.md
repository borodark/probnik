From Elixir to Android: Shipping a Scenic UI with a BEAM‑native OpenGL stack

We built Probnik, a BEAM diagnostics cockpit, as a Scenic desktop app using `scenic_driver_local`. It was fast, precise, and felt like an instrument panel. Then colleagues asked: “Can we run this on a tablet?” That forced a re‑think.

Why the old path breaks on Android
- Android’s GL context must live on the render thread.
- Activity lifecycle can restart at any time.
- BEAM schedulers and JNI threading don’t mix cleanly.

So we split the driver.

The new architecture (novel approach)
We now run Scenic across two processes:
- **scenic_driver_remote (Elixir)** — serializes Scenic scripts and sends them over a socket.
- **scenic_renderer_native (C)** — receives those scripts and renders via NanoVG/OpenGL.
- Android app boots BEAM and hosts the GL surface.

Think of it like this:
Elixir (Scenic app) → socket → native renderer (GL) → screen

This separation unlocks:
- Android support without rewriting the UI
- A portable renderer we can reuse on other platforms
- The same Scenic codebase across desktop + mobile

Why this is interesting (not games)
This isn’t about game dev. It’s about **instrument‑grade UI**:
- deterministic rendering
- smooth, stable visuals
- low overhead

OpenGL‑based UX can be a better fit for monitoring, dashboards, and control panels where clarity and responsiveness matter more than web flexibility.

What’s next: iPhone
Because the renderer is isolated, iOS becomes a platform adapter problem: add a Metal/OpenGLES surface and a socket bridge, keep everything else the same.

If you’re working in Elixir and want UIs that feel more like avionics than web apps, Scenic + this split‑driver approach is worth exploring.

Happy to share more details or walk through the stack with anyone curious.
