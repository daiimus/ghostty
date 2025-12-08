# Agent Development Guide

A file for [guiding coding agents](https://agents.md/).

## Commands

- **Build:** `zig build`
- **Test (Zig):** `zig build test`
- **Test filter (Zig)**: `zig build test -Dtest-filter=<test name>`
- **Formatting (Zig)**: `zig fmt .`
- **Formatting (other)**: `prettier -w .`

## Directory Structure

- Shared Zig core: `src/`
- C API: `include`
- macOS app: `macos/`
- GTK (Linux and FreeBSD) app: `src/apprt/gtk`

## libghostty-vt

- Build: `zig build lib-vt`
- Build Wasm Module: `zig build lib-vt -Dtarget=wasm32-freestanding`
- Test: `zig build test-lib-vt`
- Test filter: `zig build test-lib-vt -Dtest-filter=<test name>`
- When working on libghostty-vt, do not build the full app.
- For C only changes, don't run the Zig tests. Build all the examples.

## macOS App

- Do not use `xcodebuild`
- Use `zig build` to build the macOS app and any shared Zig code
- Use `zig build run` to build and run the macOS app
- Run Xcode tests using `zig build test`

## iOS Support (ios-external-backend branch)

This branch adds iOS support via an External termio backend.

### Building for iOS

```bash
# Build xcframework with iOS slices
zig build -Demit-xcframework=true -Dxcframework-target=universal

# Output: macos/GhosttyKit.xcframework/
#   - ios-arm64/           (device)
#   - ios-arm64-simulator/ (simulator)
#   - macos-arm64_x86_64/  (macOS universal)
```

### Key iOS-Specific Files

- `src/termio/External.zig` - External backend (no PTY)
- `src/config/CApi.zig` - Extended C API
- `build.zig.zon` - Uses local `../libxev-ios` fork

### Custom C APIs (iOS-specific)

```c
// Load config from file path (iOS has no default config locations)
bool ghostty_config_load_file(ghostty_config_t, const char* path, uintptr_t len);

// Load config from string (preferred for iOS)
void ghostty_config_load_string(ghostty_config_t, const char* str, uintptr_t len);

// External backend: write output data to terminal
void ghostty_surface_write_output(ghostty_surface_t, const void* data, size_t len);
```

### External Backend Usage

The External backend allows terminal emulation without a local PTY:

```c
// Surface config for External backend
ghostty_surface_config_s config = {
    .backend_type = GHOSTTY_BACKEND_EXTERNAL,
    .write_callback = my_write_callback,  // Called when terminal wants to send data
    .userdata = context
};

// Create surface
ghostty_surface_t surface = ghostty_surface_new(app, &config);

// Feed incoming data (e.g., from SSH)
ghostty_surface_write_output(surface, ssh_data, ssh_data_len);
```

### Dependencies

- libxev: Uses `../libxev-ios` local fork (iOS kqueue support)
- All other dependencies: Same as upstream

### Known Differences from Upstream

1. **No Exec backend on iOS** - iOS doesn't support fork/exec/PTY
2. **External backend only** - Uses write callbacks for I/O
3. **Metal renderer** - iOS uses Metal, not OpenGL
4. **CoreText fonts** - Font discovery via CoreText
5. **libxev fork** - Uses kevent instead of kevent64 on iOS
