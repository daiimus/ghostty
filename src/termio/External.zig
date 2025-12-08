//! External implements a termio backend for external data sources.
//!
//! Unlike the Exec backend which spawns a subprocess with a PTY, the External
//! backend receives terminal output data through explicit API calls. This is
//! useful for scenarios where the data source is external to the process,
//! such as:
//!
//!   - SSH connections where data comes from a remote host
//!   - Serial port connections
//!   - Replay/testing scenarios
//!   - Embedded terminal widgets receiving data from network sources
//!
//! The External backend still maintains proper terminal state (modes, cursor,
//! etc.) and supports bidirectional communication - input from the terminal
//! (keyboard events) is queued and can be read by the embedder to send to
//! the external source.
const External = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const xev = @import("../global.zig").xev;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const configpkg = @import("../config.zig");

const log = std.log.scoped(.io_external);

/// Configuration for the External backend.
pub const Config = struct {
    /// Initial terminal size
    cols: u16 = 80,
    rows: u16 = 24,

    /// Callback for when terminal wants to write data (user input).
    /// The embedder should send this data to the external source (e.g., SSH).
    /// If null, input is silently discarded.
    write_callback: ?*const fn (data: []const u8, userdata: ?*anyopaque) void = null,
    write_userdata: ?*anyopaque = null,
};

// Log initialization
const init_log = std.log.scoped(.external_init);

/// The current terminal grid size
grid_size: renderer.GridSize,

/// The current screen size in pixels
screen_size: renderer.ScreenSize,

/// Write callback for sending input to external source
write_callback: ?*const fn (data: []const u8, userdata: ?*anyopaque) void,
write_userdata: ?*anyopaque,

/// Initialize the External backend.
pub fn init(
    alloc: Allocator,
    cfg: Config,
) !External {
    _ = alloc;

    init_log.info("External backend initializing with {d}x{d}, callback={}", .{
        cfg.cols,
        cfg.rows,
        cfg.write_callback != null,
    });

    return .{
        .grid_size = .{
            .columns = cfg.cols,
            .rows = cfg.rows,
        },
        .screen_size = .{
            .width = 0,
            .height = 0,
        },
        .write_callback = cfg.write_callback,
        .write_userdata = cfg.write_userdata,
    };
}

pub fn deinit(self: *External) void {
    self.* = undefined;
}

/// Initialize terminal state for this backend.
pub fn initTerminal(self: *External, term: *terminal.Terminal) void {
    // Set initial size
    self.resize(.{
        .columns = term.cols,
        .rows = term.rows,
    }, .{
        .width = term.width_px,
        .height = term.height_px,
    }) catch {};
}

/// Called when entering the IO thread.
pub fn threadEnter(
    self: *External,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    _ = self;
    _ = alloc;
    _ = io;

    // Initialize thread data for external backend
    td.backend = .{ .external = .{} };

    log.info("external backend thread entered", .{});
}

/// Called when exiting the IO thread.
pub fn threadExit(self: *External, td: *termio.Termio.ThreadData) void {
    _ = self;
    assert(td.backend == .external);
    log.info("external backend thread exiting", .{});
}

/// Handle focus changes.
pub fn focusGained(
    self: *External,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    _ = self;
    _ = td;
    _ = focused;
    // External backend doesn't need to do anything special for focus
}

/// Resize the terminal.
pub fn resize(
    self: *External,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    self.grid_size = grid_size;
    self.screen_size = screen_size;
    log.debug("external backend resized to {}x{}", .{ grid_size.columns, grid_size.rows });
}

/// Queue a write to the external source.
/// This is called when the terminal wants to send data (user input).
pub fn queueWrite(
    self: *External,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = alloc;
    _ = td;

    // If we have a write callback, call it
    if (self.write_callback) |cb| {
        cb(data, self.write_userdata);

        // If linefeed requested, also send CR
        if (linefeed) {
            cb(&[_]u8{'\r'}, self.write_userdata);
        }
    } else {
        log.debug("external write discarded (no callback): {} bytes", .{data.len});
    }
}

/// Thread data specific to the External backend.
pub const ThreadData = struct {
    // External backend doesn't need thread-specific state currently,
    // but we keep this struct for consistency with other backends.

    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        _ = alloc;
        self.* = undefined;
    }
};
