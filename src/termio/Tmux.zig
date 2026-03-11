//! Tmux implements a termio backend for tmux control mode panes. Unlike the
//! exec backend, this does not spawn a subprocess or allocate a pty. Instead,
//! it routes terminal I/O through a tmux control mode connection that is
//! owned by a parent terminal surface.
//!
//! User input (keyboard, paste, etc.) is formatted as tmux `send-keys -H`
//! commands targeting a specific pane, and written to the control connection
//! via the ControlWriter interface. The `ParentWriter` implementation routes
//! commands through the parent terminal's termio mailbox, which writes them
//! to the pty connected to `tmux -CC`. The parent terminal's stream handler
//! is responsible for routing `%output` notifications back to this backend's
//! terminal.
//!
//! This backend's types are always compiled into the backend union so that
//! switch exhaustiveness checks cover it. Actual usage (creating a tmux
//! surface) is gated at call sites by `tmux_control_mode` build option.
//!
//! ## Upstream Anchor
//!
//! - Issue #1935: Support for tmux's Control Mode
//! - PR #1948: Termio refactor separating Backend and Mailbox (established
//!   the Backend union pattern this implements)
//! - PR #9860: tmux Viewer reconciliation loop (defines the Viewer that
//!   owns the tmux session state on the parent terminal)
//!
//! ## Threading
//!
//! The ControlWriter is invoked on the IO thread of the child surface.
//! The `ParentWriter` implementation posts write requests to the parent's
//! SPSC termio mailbox. See `ParentWriter` doc comments for the full
//! threading contract and the Slice 3 relay plan for cross-thread safety.
const Tmux = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");

const log = std.log.scoped(.io_tmux);

/// The pane ID this backend is attached to within the tmux session.
/// This is the numeric ID used in tmux's `%`-prefixed pane identifiers
/// (e.g., pane_id 5 corresponds to `%5`).
pane_id: usize,

/// The current grid size, tracked locally so we can issue resize
/// commands when the surface dimensions change.
grid_size: renderer.GridSize,

/// The current screen size in pixels.
screen_size: renderer.ScreenSize,

/// The writer used to send commands to the tmux control mode connection.
/// This is an interface so it can be mocked in tests and swapped for a
/// real implementation (see `ParentWriter`) when wired to the parent
/// terminal.
control_writer: ControlWriter,

/// A writer interface for sending commands to a tmux control mode
/// connection. Implementations include `ParentWriter` (routes through
/// the parent terminal's termio mailbox) and test mocks.
pub const ControlWriter = struct {
    /// Opaque context pointer, passed to writeFn on each call.
    context: *anyopaque,

    /// Write a pre-formatted tmux command (including trailing newline)
    /// to the control mode connection. The data must not be retained
    /// past the call — implementations must copy if needed.
    writeFn: *const fn (context: *anyopaque, data: []const u8) WriteError!void,

    pub const WriteError = error{
        /// The control connection has been closed or is unavailable.
        ConnectionClosed,

        /// A transient write failure occurred.
        WriteFailed,
    };

    /// Send a command to tmux via the control connection.
    pub fn write(self: ControlWriter, data: []const u8) WriteError!void {
        return self.writeFn(self.context, data);
    }
};

/// A ControlWriter implementation that routes tmux commands through
/// the parent terminal's termio mailbox. This posts a write request
/// into the parent's SPSC mailbox, which the parent's IO thread then
/// writes to the pty (connected to `tmux -CC`).
///
/// ## Threading Contract
///
/// This writer is safe to call from the parent's IO thread (the same
/// thread that runs the stream handler). This is the only context in
/// which it is used in Slice 2: the `.command` viewer action already
/// writes to the parent termio mailbox from the stream handler via
/// the same `Mailbox.send` path.
///
/// For Slice 3, when child surfaces run on their own IO threads, the
/// child will NOT call ParentWriter directly. Instead, the child will
/// post a message through `apprt.surface.Mailbox` (which routes via
/// the app thread), and the parent's surface will relay the command
/// into its own termio mailbox. This preserves the SPSC invariant:
/// the parent's IO thread remains the single producer.
///
/// ## Lifetime
///
/// The `mailbox` and `alloc` pointers must remain valid for the
/// lifetime of this writer. In practice, the parent `Termio` owns
/// both and outlives all child surfaces it creates.
///
/// ## Upstream Anchor
///
/// - `stream_handler.zig` `.command` handler (line 437-443): uses the
///   same `Mailbox.send` path to write viewer commands to the parent pty.
/// - `mailbox.zig`: SPSC send with renderer mutex handoff.
pub const ParentWriter = struct {
    mailbox: *termio.Mailbox,
    alloc: Allocator,

    /// The renderer state mutex, required by `Mailbox.send` for the
    /// backpressure unlock path. See `mailbox.zig:60-91`.
    mutex: *std.Thread.Mutex,

    pub fn controlWriter(self: *ParentWriter) ControlWriter {
        return .{
            .context = @ptrCast(self),
            .writeFn = &writeFn,
        };
    }

    fn writeFn(context: *anyopaque, data: []const u8) ControlWriter.WriteError!void {
        const self: *ParentWriter = @ptrCast(@alignCast(context));
        const msg = termio.Message.writeReq(self.alloc, data) catch
            return error.WriteFailed;
        self.mailbox.send(msg, self.mutex);
    }
};

/// Configuration for the tmux backend.
pub const Config = struct {
    /// The tmux pane ID this surface represents.
    pane_id: usize,

    /// The writer for sending commands to the tmux control connection.
    control_writer: ControlWriter,
};

/// Initialize the tmux backend. This does NOT start any I/O; it only
/// stores the configuration needed to operate.
pub fn init(cfg: Config) Tmux {
    return .{
        .pane_id = cfg.pane_id,
        .grid_size = .{},
        .screen_size = .{ .width = 0, .height = 0 },
        .control_writer = cfg.control_writer,
    };
}

pub fn deinit(self: *Tmux) void {
    self.* = undefined;
}

/// Set initial terminal state for this backend. Called once before
/// any I/O begins. This must NOT perform any I/O — only local state
/// updates. The first resize command to tmux will be sent after
/// threadEnter when the runtime resize path is invoked.
pub fn initTerminal(self: *Tmux, term: *terminal.Terminal) void {
    // Store the initial dimensions locally. We intentionally do NOT
    // call resize() here because that emits a command through the
    // ControlWriter, violating the lifecycle contract: initTerminal
    // runs before threadEnter, so no I/O may occur.
    self.grid_size = .{
        .columns = term.cols,
        .rows = term.rows,
    };
    self.screen_size = .{
        .width = term.width_px,
        .height = term.height_px,
    };
}

pub fn threadEnter(
    self: *Tmux,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    _ = alloc;
    _ = io;

    log.info("tmux backend thread enter pane_id={}", .{self.pane_id});

    // Populate the thread data with our (empty) thread state.
    td.backend = .{ .tmux = .{} };
}

pub fn threadExit(self: *Tmux, td: *termio.Termio.ThreadData) void {
    assert(td.backend == .tmux);
    log.info("tmux backend thread exit pane_id={}", .{self.pane_id});
}

/// Focus gained/lost notification. No-op for tmux — there is no local
/// termios state to poll.
pub fn focusGained(
    self: *Tmux,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    _ = self;
    _ = focused;
    assert(td.backend == .tmux);
}

/// Notify the tmux backend of a terminal resize. This sends a
/// `resize-pane` command to tmux via the control connection.
///
/// Errors from the ControlWriter are propagated to the caller so that
/// a dead control channel is not silently hidden.
pub fn resize(
    self: *Tmux,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) ControlWriter.WriteError!void {
    self.grid_size = grid_size;
    self.screen_size = screen_size;

    // Format and send a resize-pane command. tmux resize-pane uses
    // -x for width (columns) and -y for height (rows).
    var buf: [128]u8 = undefined;
    const cmd = std.fmt.bufPrint(&buf, "resize-pane -t %{d} -x {d} -y {d}\n", .{
        self.pane_id,
        grid_size.columns,
        grid_size.rows,
    }) catch |err| {
        log.warn("resize command too large for buffer err={}", .{err});
        return;
    };

    try self.control_writer.write(cmd);
}

/// Write user input to the tmux pane. Input bytes are formatted as a
/// `send-keys -H` command with hex-encoded key values, targeting this
/// backend's pane ID.
///
/// Format: `send-keys -H -t %{pane_id} {hex bytes...}\n`
///
/// The `-H` flag tells tmux to interpret the arguments as hex byte
/// values, which is the most reliable way to send arbitrary data
/// including control characters and escape sequences.
///
/// TODO: Large inputs (e.g. a 10KB paste) produce a single send-keys
/// command with ~30KB of hex. Evaluate whether tmux imposes a command
/// length limit that requires chunking into multiple send-keys calls.
pub fn queueWrite(
    self: *Tmux,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    assert(td.backend == .tmux);
    if (data.len == 0) return;

    // We need to handle linefeed mode: replace \r with \r\n in the
    // data before hex-encoding it.
    const effective_data = if (!linefeed) data else blk: {
        // Count how many \r bytes we need to expand
        var cr_count: usize = 0;
        for (data) |b| {
            if (b == '\r') cr_count += 1;
        }
        if (cr_count == 0) break :blk data;

        const expanded = try alloc.alloc(u8, data.len + cr_count);
        var j: usize = 0;
        for (data) |b| {
            expanded[j] = b;
            j += 1;
            if (b == '\r') {
                expanded[j] = '\n';
                j += 1;
            }
        }
        break :blk expanded[0..j];
    };
    defer if (linefeed and effective_data.ptr != data.ptr) {
        alloc.free(effective_data);
    };

    // Calculate the buffer size needed:
    // "send-keys -H -t %" = 18 chars
    // + pane_id digits (max ~20 for usize)
    // + " " separator before hex bytes
    // + 3 chars per byte ("XX "), last byte only 2 ("XX")
    // + 1 char for trailing newline
    const prefix = "send-keys -H -t %";
    const id_digits = digitCount(self.pane_id);
    const hex_len = if (effective_data.len > 0) effective_data.len * 3 - 1 else 0;
    const total_len = prefix.len + id_digits + 1 + hex_len + 1; // +1 space, +1 newline

    const buf = try alloc.alloc(u8, total_len);
    defer alloc.free(buf);

    // Write the prefix
    var pos: usize = 0;
    @memcpy(buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;

    // Write the pane ID
    const id_slice = std.fmt.bufPrint(buf[pos..][0..id_digits], "{d}", .{self.pane_id}) catch unreachable;
    pos += id_slice.len;

    // Space separator
    buf[pos] = ' ';
    pos += 1;

    // Write hex-encoded bytes
    const hex_chars = "0123456789ABCDEF";
    for (effective_data, 0..) |byte, i| {
        buf[pos] = hex_chars[byte >> 4];
        pos += 1;
        buf[pos] = hex_chars[byte & 0x0F];
        pos += 1;
        if (i < effective_data.len - 1) {
            buf[pos] = ' ';
            pos += 1;
        }
    }

    // Trailing newline
    buf[pos] = '\n';
    pos += 1;

    std.debug.assert(pos == total_len);

    try self.control_writer.write(buf[0..pos]);
}

/// No child process to report on — this is a no-op.
pub fn childExitedAbnormally(
    self: *Tmux,
    gpa: Allocator,
    t: *terminal.Terminal,
    exit_code: u32,
    runtime_ms: u64,
) !void {
    _ = self;
    _ = gpa;
    _ = t;
    _ = exit_code;
    _ = runtime_ms;
}

/// Thread-local data for the tmux backend. Currently empty — the tmux
/// backend does not participate in the xev event loop directly.
pub const ThreadData = struct {
    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        _ = alloc;
        self.* = undefined;
    }
};

/// Count the number of decimal digits in a usize value.
fn digitCount(n: usize) usize {
    if (n == 0) return 1;
    var count: usize = 0;
    var v = n;
    while (v > 0) : (v /= 10) {
        count += 1;
    }
    return count;
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = std.testing;

/// A test mock for ControlWriter that captures all written commands.
const TestControlWriter = struct {
    alloc: Allocator,
    commands: std.ArrayList([]const u8) = .empty,

    fn init(alloc: Allocator) TestControlWriter {
        return .{ .alloc = alloc };
    }

    fn deinit(self: *TestControlWriter) void {
        for (self.commands.items) |cmd| {
            self.alloc.free(cmd);
        }
        self.commands.deinit(self.alloc);
    }

    fn controlWriter(self: *TestControlWriter) ControlWriter {
        return .{
            .context = @ptrCast(self),
            .writeFn = &writeFn,
        };
    }

    fn writeFn(context: *anyopaque, data: []const u8) ControlWriter.WriteError!void {
        const self: *TestControlWriter = @ptrCast(@alignCast(context));
        const copy = self.alloc.dupe(u8, data) catch return error.WriteFailed;
        self.commands.append(self.alloc, copy) catch {
            self.alloc.free(copy);
            return error.WriteFailed;
        };
    }

    fn lastCommand(self: *const TestControlWriter) ?[]const u8 {
        if (self.commands.items.len == 0) return null;
        return self.commands.items[self.commands.items.len - 1];
    }
};

/// Create a minimal Termio.ThreadData with .tmux backend for testing.
/// Only the `backend` field is meaningfully set; other fields are
/// undefined since the tmux backend does not access them in queueWrite.
fn testThreadData() termio.Termio.ThreadData {
    var td: termio.Termio.ThreadData = undefined;
    td.backend = .{ .tmux = .{} };
    return td;
}

test "init sets pane_id and initial sizes" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    const tmux = Tmux.init(.{
        .pane_id = 42,
        .control_writer = writer.controlWriter(),
    });

    try testing.expectEqual(@as(usize, 42), tmux.pane_id);
    try testing.expectEqual(@as(renderer.GridSize.Unit, 0), tmux.grid_size.columns);
    try testing.expectEqual(@as(renderer.GridSize.Unit, 0), tmux.grid_size.rows);
}

test "resize sends resize-pane command" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 5,
        .control_writer = writer.controlWriter(),
    });

    try tmux.resize(
        .{ .columns = 80, .rows = 24 },
        .{ .width = 800, .height = 600 },
    );

    try testing.expectEqual(@as(usize, 1), writer.commands.items.len);
    try testing.expectEqualStrings("resize-pane -t %5 -x 80 -y 24\n", writer.lastCommand().?);

    // Verify internal state was updated
    try testing.expectEqual(@as(renderer.GridSize.Unit, 80), tmux.grid_size.columns);
    try testing.expectEqual(@as(renderer.GridSize.Unit, 24), tmux.grid_size.rows);
}

test "resize with large pane_id" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 12345,
        .control_writer = writer.controlWriter(),
    });

    try tmux.resize(
        .{ .columns = 120, .rows = 40 },
        .{ .width = 1200, .height = 800 },
    );

    try testing.expectEqualStrings("resize-pane -t %12345 -x 120 -y 40\n", writer.lastCommand().?);
}

test "queueWrite formats send-keys with hex encoding" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 2,
        .control_writer = writer.controlWriter(),
    });

    // "ls\r" = 0x6C 0x73 0x0D
    var td = testThreadData();
    try tmux.queueWrite(alloc, &td, "ls\r", false);

    try testing.expectEqual(@as(usize, 1), writer.commands.items.len);
    try testing.expectEqualStrings("send-keys -H -t %2 6C 73 0D\n", writer.lastCommand().?);
}

test "queueWrite single byte" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 0,
        .control_writer = writer.controlWriter(),
    });

    var td = testThreadData();
    try tmux.queueWrite(alloc, &td, "a", false);

    try testing.expectEqualStrings("send-keys -H -t %0 61\n", writer.lastCommand().?);
}

test "queueWrite escape sequence" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 10,
        .control_writer = writer.controlWriter(),
    });

    // Up arrow: ESC [ A = 0x1B 0x5B 0x41
    var td = testThreadData();
    try tmux.queueWrite(alloc, &td, "\x1B[A", false);

    try testing.expectEqualStrings("send-keys -H -t %10 1B 5B 41\n", writer.lastCommand().?);
}

test "queueWrite with linefeed mode" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 3,
        .control_writer = writer.controlWriter(),
    });

    // "ab\rcd" with linefeed=true should become "ab\r\ncd"
    // hex: 61 62 0D 0A 63 64
    var td = testThreadData();
    try tmux.queueWrite(alloc, &td, "ab\rcd", true);

    try testing.expectEqualStrings("send-keys -H -t %3 61 62 0D 0A 63 64\n", writer.lastCommand().?);
}

test "queueWrite empty data is no-op" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 1,
        .control_writer = writer.controlWriter(),
    });

    var td = testThreadData();
    try tmux.queueWrite(alloc, &td, "", false);

    try testing.expectEqual(@as(usize, 0), writer.commands.items.len);
}

test "queueWrite large pane_id" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 99999,
        .control_writer = writer.controlWriter(),
    });

    var td = testThreadData();
    try tmux.queueWrite(alloc, &td, "X", false);

    try testing.expectEqualStrings("send-keys -H -t %99999 58\n", writer.lastCommand().?);
}

test "deinit resets state" {
    const alloc = testing.allocator;
    var writer = TestControlWriter.init(alloc);
    defer writer.deinit();

    var tmux = Tmux.init(.{
        .pane_id = 7,
        .control_writer = writer.controlWriter(),
    });

    tmux.deinit();
    // After deinit, the struct is undefined — we just verify it
    // doesn't crash.
}

test "digitCount" {
    try testing.expectEqual(@as(usize, 1), digitCount(0));
    try testing.expectEqual(@as(usize, 1), digitCount(1));
    try testing.expectEqual(@as(usize, 1), digitCount(9));
    try testing.expectEqual(@as(usize, 2), digitCount(10));
    try testing.expectEqual(@as(usize, 2), digitCount(99));
    try testing.expectEqual(@as(usize, 3), digitCount(100));
    try testing.expectEqual(@as(usize, 5), digitCount(12345));
    try testing.expectEqual(@as(usize, 5), digitCount(99999));
}

test "ParentWriter routes commands through mailbox" {
    const alloc = testing.allocator;

    // Create a real SPSC mailbox
    var mailbox = try termio.Mailbox.initSPSC(alloc);
    defer mailbox.deinit(alloc);

    // Mutex is undefined: the queue is empty so send() takes the fast path (instant push).
    var parent_writer = ParentWriter{
        .mailbox = &mailbox,
        .alloc = alloc,
        // Mutex is unused: the queue is empty so send() takes the fast path (instant push).
        .mutex = undefined,
    };
    const writer = parent_writer.controlWriter();

    // Write a command through the ParentWriter
    try writer.write("list-windows\n");

    // Verify the command was queued in the mailbox
    const msg = mailbox.spsc.queue.pop() orelse {
        return error.TestUnexpectedResult;
    };

    // The message should be a write_small or write_alloc depending on size.
    // "list-windows\n" is 14 bytes, which fits in write_small.
    const data = switch (msg) {
        .write_small => |small| small.data[0..small.len],
        .write_alloc => |a| a.data,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqualStrings("list-windows\n", data);

    // Clean up alloc data if it was heap-allocated
    switch (msg) {
        .write_alloc => |a| a.alloc.free(a.data),
        else => {},
    }
}

test "ParentWriter handles large commands" {
    const alloc = testing.allocator;

    var mailbox = try termio.Mailbox.initSPSC(alloc);
    defer mailbox.deinit(alloc);

    var parent_writer = ParentWriter{
        .mailbox = &mailbox,
        .alloc = alloc,
        // Mutex is unused: the queue is empty so send() takes the fast path (instant push).
        .mutex = undefined,
    };
    const writer = parent_writer.controlWriter();

    // Write a command larger than WriteReq.Small capacity (38 bytes)
    const large_cmd = "send-keys -H -t %12345 41 42 43 44 45 46 47 48\n";
    try writer.write(large_cmd);

    const msg = mailbox.spsc.queue.pop() orelse {
        return error.TestUnexpectedResult;
    };

    // Large command should use write_alloc
    const data = switch (msg) {
        .write_small => |small| small.data[0..small.len],
        .write_alloc => |a| a.data,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqualStrings(large_cmd, data);

    switch (msg) {
        .write_alloc => |a| a.alloc.free(a.data),
        else => {},
    }
}

test "ParentWriter used as backend ControlWriter" {
    // Verify that ParentWriter integrates with the Tmux backend:
    // create a Tmux backend with a ParentWriter, call resize, and
    // confirm the resize-pane command reaches the mailbox.
    const alloc = testing.allocator;

    var mailbox = try termio.Mailbox.initSPSC(alloc);
    defer mailbox.deinit(alloc);

    var parent_writer = ParentWriter{
        .mailbox = &mailbox,
        .alloc = alloc,
        // Mutex is unused: the queue is empty so send() takes the fast path (instant push).
        .mutex = undefined,
    };

    var tmux = Tmux.init(.{
        .pane_id = 7,
        .control_writer = parent_writer.controlWriter(),
    });

    try tmux.resize(
        .{ .columns = 100, .rows = 30 },
        .{ .width = 1000, .height = 600 },
    );

    const msg = mailbox.spsc.queue.pop() orelse {
        return error.TestUnexpectedResult;
    };

    const data = switch (msg) {
        .write_small => |small| small.data[0..small.len],
        .write_alloc => |a| a.data,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqualStrings("resize-pane -t %7 -x 100 -y 30\n", data);

    switch (msg) {
        .write_alloc => |a| a.alloc.free(a.data),
        else => {},
    }
}
