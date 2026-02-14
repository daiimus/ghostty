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

    /// Callback for when the terminal is resized. The embedder should use
    /// this to resize the external source (e.g., SSH PTY window change).
    /// If null, resizes are not reported to the embedder.
    resize_callback: ?*const fn (cols: u16, rows: u16, width_px: u32, height_px: u32, userdata: ?*anyopaque) void = null,
    resize_userdata: ?*anyopaque = null,
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

/// Resize callback for notifying embedder of terminal size changes
resize_callback: ?*const fn (cols: u16, rows: u16, width_px: u32, height_px: u32, userdata: ?*anyopaque) void,
resize_userdata: ?*anyopaque,

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
        .resize_callback = cfg.resize_callback,
        .resize_userdata = cfg.resize_userdata,
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

    // Notify the embedder of the new size so it can resize the external
    // source (e.g., SSH PTY window change request).
    if (self.resize_callback) |cb| {
        cb(
            grid_size.columns,
            grid_size.rows,
            screen_size.width,
            screen_size.height,
            self.resize_userdata,
        );
    }
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

// Tests
const testing = std.testing;

test "External: init with default config" {
    var ext = try External.init(testing.allocator, .{});
    defer ext.deinit();

    try testing.expectEqual(@as(u16, 80), ext.grid_size.columns);
    try testing.expectEqual(@as(u16, 24), ext.grid_size.rows);
    try testing.expect(ext.write_callback == null);
    try testing.expect(ext.resize_callback == null);
}

test "External: init with custom size and callbacks" {
    const S = struct {
        var write_called: bool = false;
        var resize_called: bool = false;

        fn writeCallback(data: []const u8, userdata: ?*anyopaque) void {
            _ = data;
            _ = userdata;
            write_called = true;
        }

        fn resizeCallback(cols: u16, rows: u16, width_px: u32, height_px: u32, userdata: ?*anyopaque) void {
            _ = cols;
            _ = rows;
            _ = width_px;
            _ = height_px;
            _ = userdata;
            resize_called = true;
        }
    };

    var ext = try External.init(testing.allocator, .{
        .cols = 120,
        .rows = 40,
        .write_callback = S.writeCallback,
        .resize_callback = S.resizeCallback,
    });
    defer ext.deinit();

    try testing.expectEqual(@as(u16, 120), ext.grid_size.columns);
    try testing.expectEqual(@as(u16, 40), ext.grid_size.rows);
    try testing.expect(ext.write_callback != null);
    try testing.expect(ext.resize_callback != null);
}

test "External: resize invokes callback" {
    const S = struct {
        var called_cols: u16 = 0;
        var called_rows: u16 = 0;
        var called_width: u32 = 0;
        var called_height: u32 = 0;
        var call_count: u32 = 0;

        fn resizeCallback(cols: u16, rows: u16, width_px: u32, height_px: u32, userdata: ?*anyopaque) void {
            _ = userdata;
            called_cols = cols;
            called_rows = rows;
            called_width = width_px;
            called_height = height_px;
            call_count += 1;
        }
    };

    S.call_count = 0;

    var ext = try External.init(testing.allocator, .{
        .resize_callback = S.resizeCallback,
    });
    defer ext.deinit();

    try ext.resize(.{ .columns = 132, .rows = 50 }, .{ .width = 1920, .height = 1080 });

    try testing.expectEqual(@as(u32, 1), S.call_count);
    try testing.expectEqual(@as(u16, 132), S.called_cols);
    try testing.expectEqual(@as(u16, 50), S.called_rows);
    try testing.expectEqual(@as(u32, 1920), S.called_width);
    try testing.expectEqual(@as(u32, 1080), S.called_height);

    // Verify internal state is also updated
    try testing.expectEqual(@as(u16, 132), ext.grid_size.columns);
    try testing.expectEqual(@as(u16, 50), ext.grid_size.rows);
}

test "External: resize without callback does not crash" {
    var ext = try External.init(testing.allocator, .{});
    defer ext.deinit();

    // Should not crash when no callback is set
    try ext.resize(.{ .columns = 100, .rows = 30 }, .{ .width = 800, .height = 600 });

    try testing.expectEqual(@as(u16, 100), ext.grid_size.columns);
    try testing.expectEqual(@as(u16, 30), ext.grid_size.rows);
}

test "External: resize callback receives userdata" {
    const Context = struct {
        resize_count: u32 = 0,
        last_cols: u16 = 0,
        last_rows: u16 = 0,
    };

    const S = struct {
        fn resizeCallback(cols: u16, rows: u16, width_px: u32, height_px: u32, userdata: ?*anyopaque) void {
            _ = width_px;
            _ = height_px;
            const ctx: *Context = @ptrCast(@alignCast(userdata.?));
            ctx.resize_count += 1;
            ctx.last_cols = cols;
            ctx.last_rows = rows;
        }
    };

    var ctx = Context{};

    var ext = try External.init(testing.allocator, .{
        .resize_callback = S.resizeCallback,
        .resize_userdata = &ctx,
    });
    defer ext.deinit();

    try ext.resize(.{ .columns = 200, .rows = 60 }, .{ .width = 2560, .height = 1440 });
    try testing.expectEqual(@as(u32, 1), ctx.resize_count);
    try testing.expectEqual(@as(u16, 200), ctx.last_cols);
    try testing.expectEqual(@as(u16, 60), ctx.last_rows);

    try ext.resize(.{ .columns = 80, .rows = 24 }, .{ .width = 640, .height = 480 });
    try testing.expectEqual(@as(u32, 2), ctx.resize_count);
    try testing.expectEqual(@as(u16, 80), ctx.last_cols);
    try testing.expectEqual(@as(u16, 24), ctx.last_rows);
}

test "External: write callback still works with resize callback" {
    const S = struct {
        var write_data: [256]u8 = undefined;
        var write_len: usize = 0;
        var resize_cols: u16 = 0;

        fn writeCallback(data: []const u8, userdata: ?*anyopaque) void {
            _ = userdata;
            @memcpy(write_data[write_len..][0..data.len], data);
            write_len += data.len;
        }

        fn resizeCallback(cols: u16, rows: u16, width_px: u32, height_px: u32, userdata: ?*anyopaque) void {
            _ = rows;
            _ = width_px;
            _ = height_px;
            _ = userdata;
            resize_cols = cols;
        }
    };

    S.write_len = 0;
    S.resize_cols = 0;

    var ext = try External.init(testing.allocator, .{
        .write_callback = S.writeCallback,
        .resize_callback = S.resizeCallback,
    });
    defer ext.deinit();

    // Test write
    try ext.queueWrite(testing.allocator, undefined, "hello", false);
    try testing.expectEqualStrings("hello", S.write_data[0..S.write_len]);

    // Test resize
    try ext.resize(.{ .columns = 160, .rows = 48 }, .{ .width = 1600, .height = 900 });
    try testing.expectEqual(@as(u16, 160), S.resize_cols);
}
