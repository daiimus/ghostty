# Agent Development Guide

A file for [guiding coding agents](https://agents.md/).

## Commands

- **Build:** `zig build`
  - If you're on macOS and don't need to build the macOS app, use
    `-Demit-macos-app=false` to skip building the app bundle and speed up
    compilation.
- **Test (Zig):** `zig build test`
  - Prefer to run targeted tests with `-Dtest-filter` because the full
    test suite is slow to run.
- **Test filter (Zig)**: `zig build test -Dtest-filter=<test name>`
- **Formatting (Zig)**: `zig fmt .`
- **Formatting (Swift)**: `swiftlint lint --fix`
- **Formatting (other)**: `prettier -w .`

## Directory Structure

- Shared Zig core: `src/`
- macOS app: `macos/`
- GTK (Linux and FreeBSD) app: `src/apprt/gtk`

## Issue and PR Guidelines

- Never create an issue or PR on upstream `ghostty-org/ghostty`.
- All issues are tracked on `daiimus/geistty`.
- Do not interact with upstream PRs — analyze only.

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

### Debugging iOS Builds

When debugging Ghostty changes in the context of Geistty (iOS app):

```bash
# After rebuilding GhosttyKit, deploy to device and watch logs:
xcrun devicectl device process launch --device <device-id> --console com.geistty.app

# Filter for Ghostty-specific logs:
xcrun devicectl device process launch --device <device-id> --console com.geistty.app 2>&1 | grep -E "(Ghostty|Terminal|SCREEN)" --line-buffered
```

See `../geistty/AGENTS.md` for full debugging workflow.

## Environment & Artifact Policy

- **Repo path:** `/Users/daiimus/Repositories/ghostty`
- **Branch:** `ios-external-backend`
- **Build artifacts are never committed.** The xcframework output (`macos/GhosttyKit.xcframework/`) is already gitignored upstream. Static libraries, dSYMs, and DerivedData are also ignored.
- **Git LFS is not used in this repo.**
- **Pre-commit hooks:** installed via `git config core.hooksPath .githooks`. Block binary artifacts and oversized files.
- **Issues go on `daiimus/geistty`**, not here.
