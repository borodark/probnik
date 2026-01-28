# Plan: Extract scenic_driver_remote and scenic_renderer_native

## Summary

Extract reusable packages from probnik's Android Scenic implementation into two standalone libraries that can be used for any platform where the BEAM cannot share a process with the renderer.

**Location**: Both packages created in `/home/io/projects/learn_erl/`

**Status**: ✅ Implemented

---

## Decisions Made

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **Transports** | Unix socket + TCP + WebSocket | Full suite enables local IPC, remote debugging, and browser renderer |
| **Desktop testing** | Include GLFW backend | Enables testing C renderer without mobile device |
| **Protocol** | Binary, big-endian, versioned | Matches existing probnik implementation, cross-platform |
| **Build system** | Mix (Elixir) + CMake (C) | Standard tools for each ecosystem |

---

## Package 1: scenic_driver_remote (Elixir)

### Purpose

Transport-agnostic Scenic driver that serializes Scenic scripts to a binary protocol and sends them to a remote renderer over any supported transport.

### Directory Structure

```
/home/io/projects/learn_erl/scenic_driver_remote/
├── mix.exs
├── README.md
├── LICENSE
├── lib/
│   ├── scenic_driver_remote.ex
│   └── scenic_driver_remote/
│       ├── protocol.ex
│       ├── protocol/
│       │   ├── commands.ex              # Command encoding (PUT_SCRIPT, etc.)
│       │   └── events.ex                # Event decoding (TOUCH, KEY, etc.)
│       ├── transport.ex                 # Transport behaviour
│       └── transport/
│           ├── unix_socket.ex           # Unix domain socket
│           ├── tcp.ex                   # TCP socket
│           └── websocket.ex             # WebSocket (requires websockex)
└── test/
    ├── test_helper.exs
    └── protocol_test.exs
```

### Usage

```elixir
config :my_app, :viewport,
  size: {800, 600},
  drivers: [
    [
      module: ScenicDriverRemote,
      transport: ScenicDriverRemote.Transport.Tcp,
      host: "localhost",
      port: 4000
    ]
  ]
```

---

## Package 2: scenic_renderer_native (C Library)

### Purpose

Standalone C library that receives Scenic commands over a transport and renders them using NanoVG/OpenGL. Zero Erlang/Elixir dependencies.

### Directory Structure

```
/home/io/projects/learn_erl/scenic_renderer_native/
├── CMakeLists.txt
├── README.md
├── LICENSE
├── include/                             # Public headers
│   ├── scenic_renderer.h                # Main public API
│   ├── scenic_transport.h               # Transport interface
│   └── scenic_protocol.h                # Protocol constants
├── src/
│   ├── scenic_renderer.c                # Renderer context management
│   ├── scenic_renderer_internal.h       # Internal declarations
│   ├── protocol.c                       # Protocol parsing
│   ├── protocol.h
│   ├── script.c                         # Script storage + rendering
│   ├── script.h
│   ├── font.c                           # Font loading/rendering
│   ├── font.h
│   ├── image.c                          # Image/texture management
│   ├── image.h
│   ├── comms.c                          # Buffer reading utilities
│   ├── comms.h
│   ├── utils.c                          # Utilities
│   ├── utils.h
│   ├── types.h                          # Common types
│   ├── transport/
│   │   ├── transport.c                  # Transport abstraction
│   │   ├── unix_socket.c                # Unix socket implementation
│   │   └── tcp.c                        # TCP implementation
│   ├── nanovg/                          # Vendored NanoVG
│   └── tommyds/                         # Vendored hash table
├── src/platform/                        # Platform backends
│   ├── platform.h                       # Platform interface
│   ├── glfw/
│   │   └── platform_glfw.c              # Desktop GLFW backend
│   └── android/
│       └── platform_android.c           # Android EGL backend
├── examples/
│   └── glfw_standalone/
│       └── main.c                       # Desktop test application
└── test/
    └── test_protocol.c
```

### Building

```bash
cd scenic_renderer_native
mkdir build && cd build
cmake ..
make
```

### Running Standalone Renderer

```bash
./examples/glfw_standalone/scenic_standalone --port 4000
```

---

## Binary Protocol Specification v1.0

### Frame Format

All messages use the same frame format:

```
+--------+----------------+------------------+
| Type   | Length         | Payload          |
| 1 byte | 4 bytes BE     | Length bytes     |
+--------+----------------+------------------+
```

- **Type**: Command or event identifier (uint8)
- **Length**: Payload length in bytes (uint32, big-endian)
- **Payload**: Type-specific binary data

### Numeric Encoding

| Type | Encoding |
|------|----------|
| uint8 | 1 byte, unsigned |
| int32 | 4 bytes, big-endian, signed |
| uint32 | 4 bytes, big-endian, unsigned |
| float32 | 4 bytes, IEEE 754 single precision |

### Commands (Driver → Renderer)

| Code | Command | Description |
|------|---------|-------------|
| 0x01 | PUT_SCRIPT | Store/update a script for rendering |
| 0x02 | DEL_SCRIPT | Delete a script |
| 0x03 | RESET | Clear all scripts, fonts, and images |
| 0x04 | CLEAR_COLOR | Set background clear color |
| 0x05 | PUT_FONT | Load a font |
| 0x06 | PUT_IMAGE | Load an image/texture |
| 0x07 | RENDER | Trigger a frame render |
| 0x08 | GLOBAL_TX | Set global transform |
| 0x20 | QUIT | Shutdown the renderer |

### Events (Renderer → Driver)

| Code | Event | Description |
|------|-------|-------------|
| 0x01 | TOUCH | Touch/pointer event |
| 0x02 | KEY | Keyboard key event |
| 0x03 | RESHAPE | Window/viewport resize |
| 0x04 | CODEPOINT | Unicode character input |
| 0x05 | CURSOR_POS | Mouse cursor movement |
| 0x06 | MOUSE_BUTTON | Mouse button event |
| 0x07 | SCROLL | Scroll wheel event |
| 0x08 | CURSOR_ENTER | Cursor enter/leave |
| 0x10 | READY | Renderer is ready |

### Image Formats

| Code | Format |
|------|--------|
| 0 | Encoded file (PNG, JPEG) |
| 1 | Grayscale (1 byte/pixel) |
| 2 | Grayscale + Alpha (2 bytes/pixel) |
| 3 | RGB (3 bytes/pixel) |
| 4 | RGBA (4 bytes/pixel) |

---

## Source Extraction Map

### Files copied from probnik → scenic_renderer_native

| Source | Destination |
|--------|-------------|
| `android/.../scenic_local/script.c` | `src/script.c` |
| `android/.../scenic_local/font.c` | `src/font.c` |
| `android/.../scenic_local/image.c` | `src/image.c` |
| `android/.../scenic_local/comms.c` | `src/comms.c` |
| `android/.../scenic_local/nanovg/` | `src/nanovg/` |
| `android/.../scenic_local/tommyds/` | `src/tommyds/` |

---

## Verification Checklist

- [x] Protocol roundtrip test: Encode command in Elixir → decode in C → verify
- [x] Elixir package compiles with `mix compile`
- [x] Elixir tests pass with `mix test`
- [x] C library builds with CMake
- [x] C tests pass with `ctest`
- [x] GLFW standalone example builds
- [ ] Integration test: GLFW app + Elixir driver over TCP
- [ ] Android integration test

---

## Future Work (Out of Scope)

- WebSocket transport implementation (requires C websocket library)
- iOS platform backend
- WebGL/Canvas browser renderer (scenic_renderer_web)
- UDP transport with reliability layer
- Script caching and delta updates
- Multi-window support
