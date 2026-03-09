const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const testing = std.testing;
const assert = @import("../../quirks.zig").inlineAssert;
const size = @import("../size.zig");
const CircBuf = @import("../../datastruct/main.zig").CircBuf;
const CursorStyle = @import("../cursor.zig").Style;
const Screen = @import("../Screen.zig");
const ScreenSet = @import("../ScreenSet.zig");
const Parser = @import("../Parser.zig");
const Terminal = @import("../Terminal.zig");
const UTF8Decoder = @import("../UTF8Decoder.zig");
const Layout = @import("layout.zig").Layout;
const control = @import("control.zig");
const output = @import("output.zig");

const log = std.log.scoped(.terminal_tmux_viewer);

// TODO: A list of TODOs as I think about them.
// - We need to make startup more robust so session and block can happen
//   out of order.
// - We need to ignore `output` for panes that aren't yet initialized
//   (until capture-panes are complete).
// - We should note what the active window pane is on the tmux side;
//   we can use this at least for initial focus.

// NOTE: There is some fragility here that can possibly break if tmux
// changes their implementation. In particular, the order of notifications
// and assurances about what is sent when are based on reading the tmux
// source code as of Dec, 2025. These aren't documented as fixed.
//
// I've tried not to depend on anything that seems like it'd change
// in the future. For example, it seems reasonable that command output
// always comes before session attachment. But, I am noting this here
// in case something breaks in the future we can consider it. We should
// be able to easily unit test all variations seen in the real world.

/// The initial capacity of the command queue. We dynamically resize
/// as necessary so the initial value isn't that important, but if we
/// want to feel good about it we should make it large enough to support
/// our most realistic use cases without resizing.
const COMMAND_QUEUE_INITIAL = 8;

/// A viewer is a tmux control mode client that attempts to create
/// a remote view of a tmux session, including providing the ability to send
/// new input to the session.
///
/// This is the primary use case for tmux control mode, but technically
/// tmux control mode clients can do anything a normal tmux client can do,
/// so the `control.zig` and other files in this folder are more general
/// purpose.
///
/// This struct helps move through a state machine of connecting to a tmux
/// session, negotiating capabilities, listing window state, etc.
///
/// ## Viewer Lifecycle
///
/// The viewer progresses through several states from initial connection
/// to steady-state operation. Here is the full flow:
///
/// ```
///                              ┌─────────────────────────────────────────────┐
///                              │           TMUX CONTROL MODE START           │
///                              │         (DCS 1000p received by host)        │
///                              └─────────────────┬───────────────────────────┘
///                                                │
///                                                ▼
///                              ┌─────────────────────────────────────────────┐
///                              │            startup_block                    │
///                              │                                             │
///                              │  Wait for initial %begin/%end block from    │
///                              │  tmux. This is the response to the initial  │
///                              │  command (e.g., "attach -t 0").             │
///                              └─────────────────┬───────────────────────────┘
///                                                │ %end / %error
///                                                ▼
///                              ┌─────────────────────────────────────────────┐
///                              │           startup_session                   │
///                              │                                             │
///                              │  Wait for %session-changed notification     │
///                              │  to get the initial session ID.             │
///                              └─────────────────┬───────────────────────────┘
///                                                │ %session-changed
///                                                ▼
///                              ┌─────────────────────────────────────────────┐
///                              │           command_queue                     │
///                              │                                             │
///                              │  Main operating state. Process commands     │
///                              │  sequentially and handle notifications.     │
///                              └─────────────────────────────────────────────┘
///                                                │
///                    ┌───────────────────────────┼───────────────────────────┐
///                    │                           │                           │
///                    ▼                           ▼                           ▼
///     ┌──────────────────────────┐ ┌──────────────────────────┐ ┌────────────────────────┐
///     │     tmux_version         │ │     list_windows         │ │   %output / %layout-   │
///     │                          │ │                          │ │   change / etc.        │
///     │  Query tmux version for  │ │  Get all windows in the  │ │                        │
///     │  compatibility checks.   │ │  current session.        │ │  Handle live updates   │
///     └──────────────────────────┘ └────────────┬─────────────┘ │  from tmux server.     │
///                                               │               └────────────────────────┘
///                                               ▼
///                              ┌─────────────────────────────────────────────┐
///                              │          syncLayouts                        │
///                              │                                             │
///                              │  For each window, parse layout and sync     │
///                              │  panes. New panes trigger capture commands. │
///                              └─────────────────┬───────────────────────────┘
///                                                │
///                    ┌───────────────────────────┴───────────────────────────┐
///                    │                  For each new pane:                   │
///                    ▼                                                       ▼
///     ┌──────────────────────────┐                            ┌──────────────────────────┐
///     │     pane_history         │                            │     pane_visible         │
///     │     (primary screen)     │                            │     (primary screen)     │
///     │                          │                            │                          │
///     │  Capture scrollback      │                            │  Capture visible area    │
///     │  history into terminal.  │                            │  into terminal.          │
///     └──────────────────────────┘                            └──────────────────────────┘
///                    │                                                       │
///                    ▼                                                       ▼
///     ┌──────────────────────────┐                            ┌──────────────────────────┐
///     │     pane_history         │                            │     pane_visible         │
///     │     (alternate screen)   │                            │     (alternate screen)   │
///     └──────────────────────────┘                            └──────────────────────────┘
///                    │                                                       │
///                    └───────────────────────────┬───────────────────────────┘
///                                                ▼
///                              ┌─────────────────────────────────────────────┐
///                              │          pane_state                         │
///                              │                                             │
///                              │  Query cursor position, cursor style,       │
///                              │  and alternate screen mode for all panes.   │
///                              └─────────────────────────────────────────────┘
///                                                │
///                                                ▼
///                              ┌─────────────────────────────────────────────┐
///                              │        READY FOR OPERATION                  │
///                              │                                             │
///                              │  Panes are populated with content. The      │
///                              │  viewer handles %output for live updates,   │
///                              │  %layout-change for pane changes, and       │
///                              │  %session-changed for session switches.     │
///                              └─────────────────────────────────────────────┘
/// ```
///
/// ## Error Handling
///
/// At any point, if an unrecoverable error occurs or tmux sends `%exit`,
/// the viewer transitions to the `defunct` state and emits an `.exit` action.
///
/// ## Session Changes
///
/// When `%session-changed` is received during `command_queue` state, the
/// viewer resets itself completely: clears all windows/panes, emits an
/// empty windows action, and restarts the `list_windows` flow for the new
/// session.
///
pub const Viewer = struct {
    /// Allocator used for all internal state.
    alloc: Allocator,

    /// Current state of the state machine.
    state: State,

    /// The current session ID we're attached to.
    session_id: usize,

    /// The current session name (updated on %session-renamed).
    session_name: ?[]const u8 = null,

    /// The tmux server version string (e.g., "3.5a"). We capture this
    /// on startup because it will allow us to change behavior between
    /// versions as necessary.
    tmux_version: []const u8,

    /// The parsed version for comparison. Null if the version string
    /// could not be parsed (should not happen with well-behaved tmux
    /// servers, but we handle it gracefully).
    parsed_version: ?TmuxVersion,

    /// The list of commands we've sent that we want to send and wait
    /// for a response for. We only send one command at a time just
    /// to avoid any possible confusion around ordering.
    command_queue: CommandQueue,

    /// The windows in the current session.
    windows: std.ArrayList(Window),

    /// The panes in the current session, mapped by pane ID.
    panes: PanesMap,

    /// The arena used for the prior action allocated state. This contains
    /// the contents for the actions as well as the actions slice itself.
    action_arena: ArenaAllocator.State,

    /// A single action pre-allocated that we use for single-action
    /// returns (common). This ensures that we can never get allocation
    /// errors on single-action returns, especially those such as `.exit`.
    action_single: [1]Action,

    /// Whether the initial `.ready` action has been sent. This is set
    /// to true the first time the command queue drains after entering
    /// the `command_queue` state. It prevents duplicate ready signals
    /// when the queue drains again (e.g., after layout changes).
    initial_ready_sent: bool,

    /// Set to true by nextCommand() when the initial ready signal fires.
    /// The caller (stream_handler) checks this after next() returns,
    /// handles the notification, and clears it. This replaces the former
    /// `.ready` Action variant.
    ready_just_fired: bool = false,

    /// Set by receivedCommandOutput() when a user command response arrives.
    /// The caller (stream_handler) checks this after next() returns,
    /// handles the notification, and clears it. This replaces the former
    /// `.command_response` Action variant. The content slice points into
    /// the parser's buffer and is valid until the next call to `next()`.
    last_command_response: ?CommandResponse = null,

    /// Set by the `.pause` notification handler when a pane needs a
    /// `refresh-client -A continue` command sent. The caller
    /// (stream_handler) checks this after next() returns, formats and
    /// sends the continue command, calls trackFireAndForget(), and
    /// clears this field. This replaces the former `.send_keys` emission
    /// from the pause handler.
    pause_continue_pane_id: ?usize = null,

    /// The currently active pane ID for user input routing. This is set
    /// by the apprt (e.g., when a user focuses a pane in the GUI) and
    /// is used by `sendKeys` to target `send-keys` commands. When null,
    /// no pane is active and `sendKeys` will return null.
    active_pane_id: ?usize,

    /// The currently active window ID, as reported by tmux via
    /// `%session-window-changed`. This lets the apprt know which window
    /// tab should be highlighted. Null until the first notification.
    active_window_id: ?usize,

    /// Count of fire-and-forget commands (e.g., send-keys, flow control
    /// continue) whose %begin/%end responses have not yet arrived. When
    /// a block response arrives with an empty command queue, this counter
    /// is decremented to absorb the expected response instead of logging
    /// "unexpected block output."
    pending_fire_and_forget: usize,

    /// Optional callback invoked after receivedOutput() processes %output
    /// data for a pane. The callback receives the pane ID that was updated.
    /// This allows the caller (e.g., stream_handler) to wake observer
    /// renderers without the viewer needing to know about observers.
    output_cb: ?OutputCallback = null,
    output_ud: ?*anyopaque = null,

    pub const OutputCallback = *const fn (ud: ?*anyopaque, pane_id: usize) void;

    pub const CommandQueue = CircBuf(Command, undefined);
    pub const PanesMap = std.AutoArrayHashMapUnmanaged(usize, Pane);

    /// A parsed tmux version for comparison purposes. Tmux versions
    /// follow the format "major.minor[suffix]" where suffix is an
    /// optional lowercase letter (e.g., "3.5a", "2.9", "3.2a").
    /// Development builds may have a "next-" prefix (e.g., "next-3.5")
    /// which is stripped during parsing and treated as that version.
    pub const TmuxVersion = struct {
        major: u16,
        minor: u16,
        /// Optional suffix letter (e.g., 'a' in "3.5a"). Zero means
        /// no suffix. A version with a suffix is newer than the same
        /// version without one (3.5a > 3.5).
        suffix: u8,

        /// Well-known version thresholds for feature gating.
        pub const flow_control = TmuxVersion{ .major = 3, .minor = 2, .suffix = 0 };
        pub const format_subscriptions = TmuxVersion{ .major = 3, .minor = 2, .suffix = 0 };
        pub const unlinked_window = TmuxVersion{ .major = 3, .minor = 1, .suffix = 0 };
        pub const send_keys_hex = TmuxVersion{ .major = 2, .minor = 9, .suffix = 0 };

        /// Parse a version string like "3.5a", "2.9", or "next-3.5".
        /// Returns null if the string cannot be parsed.
        pub fn parse(input: []const u8) ?TmuxVersion {
            // Strip "next-" prefix from development builds.
            const version_str = if (std.mem.startsWith(u8, input, "next-"))
                input[5..]
            else
                input;

            // Find the dot separator.
            const dot_pos = std.mem.indexOfScalar(u8, version_str, '.') orelse return null;
            if (dot_pos == 0) return null;

            const major = std.fmt.parseInt(u16, version_str[0..dot_pos], 10) catch return null;

            // After the dot: digits optionally followed by a single letter.
            const after_dot = version_str[dot_pos + 1 ..];
            if (after_dot.len == 0) return null;

            // Find where the digits end.
            var digit_end: usize = 0;
            while (digit_end < after_dot.len and std.ascii.isDigit(after_dot[digit_end])) {
                digit_end += 1;
            }
            if (digit_end == 0) return null;

            const minor = std.fmt.parseInt(u16, after_dot[0..digit_end], 10) catch return null;

            // Check for an optional suffix letter.
            var suffix: u8 = 0;
            if (digit_end < after_dot.len) {
                if (std.ascii.isLower(after_dot[digit_end])) {
                    suffix = after_dot[digit_end];
                    // Must be the last character (reject "3.5ab").
                    if (digit_end + 1 != after_dot.len) return null;
                } else {
                    // Unexpected trailing character.
                    return null;
                }
            }

            return .{ .major = major, .minor = minor, .suffix = suffix };
        }

        /// Compare two versions. Returns .lt, .eq, or .gt.
        pub fn order(self: TmuxVersion, other: TmuxVersion) std.math.Order {
            if (self.major != other.major) return std.math.order(self.major, other.major);
            if (self.minor != other.minor) return std.math.order(self.minor, other.minor);
            // suffix=0 means no suffix, which sorts before any letter.
            return std.math.order(self.suffix, other.suffix);
        }

        /// Returns true if this version is at least the given version.
        pub fn atLeast(self: TmuxVersion, minimum: TmuxVersion) bool {
            return self.order(minimum) != .lt;
        }
    };

    pub const Action = union(enum) {
        /// Tmux has closed the control mode connection, we should end
        /// our viewer session in some way. The reason string describes
        /// why the exit occurred (e.g., "detached", "server-exited").
        exit: []const u8,

        /// Send a command to tmux, e.g. `list-windows`. The caller
        /// should not worry about parsing this or reading what command
        /// it is; just send it to tmux as-is. This will include the
        /// trailing newline so you can send it directly.
        command: []const u8,

        /// Windows changed. This may add, remove or change windows. The
        /// caller is responsible for diffing the new window list against
        /// the prior one. Remember that for a given Viewer, window IDs
        /// are guaranteed to be stable. Additionally, tmux (as of Dec 2025)
        /// never reuses window IDs within a server process lifetime.
        windows: []const Window,

        pub fn format(self: Action, writer: *std.Io.Writer) !void {
            const T = Action;
            const info = @typeInfo(T).@"union";

            try writer.writeAll(@typeName(T));
            if (info.tag_type) |TagType| {
                try writer.writeAll("{ .");
                try writer.writeAll(@tagName(@as(TagType, self)));
                try writer.writeAll(" = ");

                inline for (info.fields) |u_field| {
                    if (self == @field(TagType, u_field.name)) {
                        const value = @field(self, u_field.name);
                        switch (u_field.type) {
                            []const u8 => try writer.print("\"{s}\"", .{std.mem.trim(u8, value, " \t\r\n")}),
                            else => try writer.print("{any}", .{value}),
                        }
                    }
                }

                try writer.writeAll(" }");
            }
        }
    };

    /// Response from a user-initiated tmux command.
    pub const CommandResponse = struct {
        /// The block content returned by tmux. Points into the parser's
        /// buffer and is valid until the next call to `next()`.
        content: []const u8,
        /// Whether the response was a `%error` block.
        is_error: bool,
    };

    pub const Input = union(enum) {
        /// Data from tmux was received that needs to be processed.
        tmux: control.Notification,
    };

    pub const Window = struct {
        id: usize,
        width: usize,
        height: usize,
        layout_arena: ArenaAllocator.State,
        layout: Layout,
        /// The window name (e.g., "bash", "vim"). Owned by the Viewer's
        /// allocator (duped from tmux output). Empty string if unknown.
        name: []const u8,
        /// The raw tmux layout string (e.g., "b7dd,83x44,0,0,0"). Owned by
        /// the Viewer's allocator. This crosses the C API boundary so Swift
        /// can parse it with its own layout parser. Empty string if unknown.
        raw_layout: []const u8,
        /// The pane that tmux considers focused in this window.
        /// Set by `%window-pane-changed` notifications. `null` means
        /// we haven't received a focus notification for this window yet.
        focused_pane_id: ?usize = null,

        pub fn deinit(self: *Window, alloc: Allocator) void {
            // name and raw_layout use empty string "" as a sentinel for
            // "no name" / "no layout". Empty string literals are static
            // (not heap-allocated), so we must not free them. Non-empty
            // values are heap-duped by the viewer.
            if (self.name.len > 0) alloc.free(self.name);
            if (self.raw_layout.len > 0) alloc.free(self.raw_layout);
            self.layout_arena.promote(alloc).deinit();
        }
    };

    pub const Pane = struct {
        terminal: Terminal,

        /// Persistent VT parser state for %output processing.
        /// Without this, CSI sequences split across %output messages
        /// lose parser state and render as literal text.
        vt_parser: Parser = .init(),
        vt_utf8decoder: UTF8Decoder = .{},

        /// Flow control: true when tmux has paused output for this pane
        /// because the client fell behind. Output resumes when the client
        /// sends `refresh-client -A '%N:continue'`.
        paused: bool = false,

        pub fn deinit(self: *Pane, alloc: Allocator) void {
            self.vt_parser.deinit();
            self.terminal.deinit(alloc);
        }
    };

    /// Initialize a new viewer.
    ///
    /// The given allocator is used for all internal state. You must
    /// call deinit when you're done with the viewer to free it.
    pub fn init(alloc: Allocator) Allocator.Error!Viewer {
        // Create our initial command queue
        var command_queue: CommandQueue = try .init(alloc, COMMAND_QUEUE_INITIAL);
        errdefer command_queue.deinit(alloc);

        return .{
            .alloc = alloc,
            .state = .startup_block,
            // The default value here is meaningless. We don't get started
            // until we receive a session-changed notification which will
            // set this to a real value.
            .session_id = 0,
            .tmux_version = "",
            .parsed_version = null,
            .command_queue = command_queue,
            .windows = .empty,
            .panes = .empty,
            .action_arena = .{},
            // Safety: action_single is only accessed via singleAction(),
            // which writes the element before returning a slice over it.
            .action_single = undefined,
            .initial_ready_sent = false,
            .active_pane_id = null,
            .active_window_id = null,
            .pending_fire_and_forget = 0,
        };
    }

    pub fn deinit(self: *Viewer) void {
        {
            for (self.windows.items) |*window| window.deinit(self.alloc);
            self.windows.deinit(self.alloc);
        }
        {
            var it = self.command_queue.iterator(.forward);
            while (it.next()) |command| command.deinit(self.alloc);
            self.command_queue.deinit(self.alloc);
        }
        {
            var it = self.panes.iterator();
            while (it.next()) |kv| kv.value_ptr.deinit(self.alloc);
            self.panes.deinit(self.alloc);
        }
        if (self.tmux_version.len > 0) {
            self.alloc.free(self.tmux_version);
        }
        self.action_arena.promote(self.alloc).deinit();
    }

    /// Promote the action arena, append a single action, and save the
    /// arena state back. This consolidates the arena-promote-append
    /// boilerplate used at many call sites that only need one append.
    fn appendAction(self: *Viewer, actions: *std.ArrayList(Action), action: Action) Allocator.Error!void {
        var arena = self.action_arena.promote(self.alloc);
        defer self.action_arena = arena.state;
        try actions.append(arena.allocator(), action);
    }

    /// Set the active pane for user input routing. The pane_id must
    /// refer to a pane that exists in our panes map, or be null to
    /// clear the active pane. If the pane_id is not null and does not
    /// exist, this is a no-op (the active pane remains unchanged).
    pub fn setActivePaneId(self: *Viewer, pane_id: ?usize) void {
        if (pane_id) |id| {
            if (!self.panes.contains(id)) {
                log.warn("setActivePaneId: pane %{} not found, ignoring", .{id});
                return;
            }
        }
        self.active_pane_id = pane_id;
    }

    /// Format a `send-keys -H` command for the given data bytes,
    /// targeting the active pane. Returns a `send_keys` action whose
    /// payload is the formatted command with trailing newline, or null
    /// if there is no active pane or the data is empty.
    ///
    /// The returned slice is arena-allocated and valid until the next
    /// call to `next()` (which resets the action arena).
    pub fn sendKeys(self: *Viewer, data: []const u8) ?[]const u8 {
        if (data.len == 0) return null;

        const pane_id = self.active_pane_id orelse return null;

        // Verify the pane still exists (it may have been removed).
        if (!self.panes.contains(pane_id)) {
            self.active_pane_id = null;
            return null;
        }

        // Format: "send-keys -H -t %{id} {hex}...\n"
        // Each byte becomes "XX " (3 chars), last byte "XX\n" (3 chars).
        // Prefix: "send-keys -H -t %" + digits + " " = ~25 + digits chars.
        var arena = self.action_arena.promote(self.alloc);
        defer self.action_arena = arena.state;
        const arena_alloc = arena.allocator();

        // Calculate the pane ID digit count manually to size the buffer once.
        // This is a hot path (every keystroke in tmux mode), so we compute
        // the decimal width inline instead of using a formatting helper like
        // std.fmt.allocPrint that would perform an extra pass and allocation.
        var id_digits: usize = 1;
        {
            var n = pane_id;
            while (n >= 10) : (n /= 10) {
                id_digits += 1;
            }
        }

        const prefix_len = "send-keys -H -t %".len + id_digits + " ".len;
        const hex_len = data.len * 3; // "XX " per byte (last space becomes \n)
        const total_len = prefix_len + hex_len;

        const buf = arena_alloc.alloc(u8, total_len) catch {
            log.warn("sendKeys: failed to allocate {} bytes for pane {}", .{ total_len, pane_id });
            return null;
        };

        // Write prefix.
        var pos: usize = 0;
        const prefix = std.fmt.bufPrint(buf[0..prefix_len], "send-keys -H -t %{d} ", .{pane_id}) catch {
            log.warn("sendKeys: failed to format prefix for pane {}", .{pane_id});
            return null;
        };
        pos = prefix.len;

        // Write hex bytes.
        const hex_upper = "0123456789ABCDEF";
        for (data, 0..) |byte, i| {
            buf[pos] = hex_upper[byte >> 4];
            buf[pos + 1] = hex_upper[byte & 0x0F];
            if (i < data.len - 1) {
                buf[pos + 2] = ' ';
            } else {
                buf[pos + 2] = '\n';
            }
            pos += 3;
        }

        return buf[0..pos];
    }

    /// Queue a user command to be sent through the tmux command queue.
    /// The response will arrive as a `command_response` action in a
    /// subsequent call to `next()`.
    ///
    /// If the command queue is empty (no command in flight), this returns
    /// a `.command` action that the caller must send to tmux immediately.
    /// If a command is already in flight, the user command is appended to
    /// the queue and will be sent automatically when the current command
    /// completes — in that case, `null` is returned.
    ///
    /// `cmd` must include a trailing newline. The string is copied into
    /// the viewer's allocator.
    ///
    /// Returns `null` if the viewer is not in `command_queue` state (e.g.,
    /// during startup or after becoming defunct) or if the command was
    /// queued behind an in-flight command. Returns error on allocation
    /// failure.
    pub fn queueUserCommand(self: *Viewer, cmd: []const u8) Allocator.Error!?Action {
        if (self.state != .command_queue) return null;
        if (cmd.len == 0) return null;

        const was_empty = self.command_queue.empty();
        const cmd_copy = try self.alloc.dupe(u8, cmd);
        errdefer self.alloc.free(cmd_copy);

        try self.command_queue.ensureUnusedCapacity(self.alloc, 1);
        self.command_queue.appendAssumeCapacity(.{ .user = cmd_copy });

        if (was_empty) {
            // No command in flight — format and return the command to send.
            var arena = self.action_arena.promote(self.alloc);
            defer self.action_arena = arena.state;
            var builder: std.Io.Writer.Allocating = .init(arena.allocator());
            (Command{ .user = cmd_copy }).formatCommand(&builder.writer) catch
                return error.OutOfMemory;
            return .{ .command = builder.writer.buffered() };
        }
        return null;
    }

    /// Increment the fire-and-forget counter. Call this after dispatching
    /// a fire-and-forget action (send_keys, flow control continue) that
    /// will produce a %begin/%end response outside the command queue.
    pub fn trackFireAndForget(self: *Viewer) void {
        self.pending_fire_and_forget +|= 1;
    }

    /// Send in an input event (such as a tmux protocol notification,
    /// keyboard input for a pane, etc.) and process it. The returned
    /// list is a set of actions to take as a result of the input prior
    /// to the next input. This list may be empty.
    pub fn next(self: *Viewer, input: Input) []const Action {
        // Developer note: this function must never return an error. If
        // an error occurs we must go into a defunct state or some other
        // state to gracefully handle it.
        return switch (input) {
            .tmux => self.nextTmux(input.tmux),
        };
    }

    fn nextTmux(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        return switch (self.state) {
            .defunct => defunct: {
                log.info("received notification in defunct state, ignoring", .{});
                break :defunct &.{};
            },

            .startup_block => self.nextStartupBlock(n),
            .startup_session => self.nextStartupSession(n),
            .command_queue => self.nextCommand(n),
        };
    }

    fn nextStartupBlock(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        assert(self.state == .startup_block);

        switch (n) {
            // This is only sent by the DCS parser when we first get
            // DCS 1000p, it should never reach us here.
            .enter => unreachable,

            // I don't think this is technically possible (reading the
            // tmux source code), but if we see an exit we can semantically
            // handle this without issue.
            .exit => |info| return self.defunctWithReason(info.reason),

            // Any begin and end (even error) is fine! Now we wait for
            // session-changed to get the initial session ID. session-changed
            // is guaranteed to come after the initial command output
            // since if the initial command is `attach` tmux will run that,
            // queue the notification, then do notificatins.
            .block_end, .block_err => {
                self.state = .startup_session;
                return &.{};
            },

            // I don't like catch-all else branches but startup is such
            // a special case of looking for very specific things that
            // are unlikely to expand.
            else => return &.{},
        }
    }

    fn nextStartupSession(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        assert(self.state == .startup_session);

        switch (n) {
            .enter => unreachable,

            .exit => |info| return self.defunctWithReason(info.reason),

            .session_changed => |info| {
                self.session_id = info.id;

                var arena = self.action_arena.promote(self.alloc);
                defer self.action_arena = arena.state;
                _ = arena.reset(.free_all);

                return self.enterCommandQueue(
                    arena.allocator(),
                    &.{ .tmux_version, .enable_flow_control, .register_subscriptions, .list_windows },
                ) catch {
                    log.warn("failed to queue command, becoming defunct", .{});
                    return self.defunct();
                };
            },

            else => return &.{},
        }
    }

    fn nextCommand(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        // We have to be in a command queue, but the command queue MAY
        // be empty. If it is empty, then receivedCommandOutput will
        // handle it by ignoring any command output. That's okay!
        assert(self.state == .command_queue);

        // Clear our prior arena so it is ready to be used for any
        // actions immediately.
        {
            var arena = self.action_arena.promote(self.alloc);
            _ = arena.reset(.free_all);
            self.action_arena = arena.state;
        }

        // Setup our empty actions list that commands can populate.
        var actions: std.ArrayList(Action) = .empty;

        // Track whether the in-flight command slot is available. Starts true
        // if queue is empty (no command in flight). Set to true when a command
        // completes (block_end/block_err) or the queue is reset (session_changed).
        var command_consumed = self.command_queue.empty();

        switch (n) {
            .enter => unreachable,
            .exit => |info| return self.defunctWithReason(info.reason),

            inline .block_end,
            .block_err,
            => |content, tag| {
                self.receivedCommandOutput(
                    &actions,
                    content,
                    tag == .block_err,
                ) catch {
                    log.warn("failed to process command output, becoming defunct", .{});
                    return self.defunct();
                };

                // Command is consumed since a block end/err is the output
                // from a command.
                command_consumed = true;
            },

            .output => |out| self.receivedOutput(
                out.pane_id,
                out.data,
            ) catch |err| {
                log.warn(
                    "failed to process output for pane id={}: {}",
                    .{ out.pane_id, err },
                );
            },

            // Session changed means we switched to a different tmux session.
            // We need to reset our state and start fresh with list-windows.
            // This completely replaces the viewer, so treat it like a fresh start.
            .session_changed => |info| {
                self.sessionChanged(
                    &actions,
                    info.id,
                ) catch {
                    log.warn("failed to handle session change, becoming defunct", .{});
                    return self.defunct();
                };

                // Command is consumed because sessionChanged resets
                // our entire viewer.
                command_consumed = true;
            },

            // Layout changed of a single window.
            .layout_change => |info| self.layoutChanged(
                &actions,
                info.window_id,
                info.layout,
            ) catch {
                // Note: in the future, we can probably handle a failure
                // here with a fallback to remove this one window, list
                // windows again, and try again.
                log.warn("failed to handle layout change, becoming defunct", .{});
                return self.defunct();
            },

            // A window was added to this session.
            .window_add => |info| self.windowAdd(info.id) catch {
                log.warn("failed to handle window add, becoming defunct", .{});
                return self.defunct();
            },

            // The active pane changed. Track it so the apprt can query
            // which pane tmux considers focused in each window (e.g.,
            // when switching windows, the apprt needs to highlight the
            // correct pane rather than falling back to the first pane).
            // The stream_handler sends the surface notification directly
            // from the raw control notification.
            .window_pane_changed => |info| {
                for (self.windows.items) |*win| {
                    if (win.id == info.window_id) {
                        win.focused_pane_id = info.pane_id;
                        break;
                    }
                }
            },

            // Sessions changed — forwarded by stream_handler directly.
            .sessions_changed => {},

            // Window was renamed. Update our stored name and notify the apprt.
            .window_renamed => |info| {
                self.windowRenamed(
                    &actions,
                    info.id,
                    info.name,
                ) catch {
                    log.warn("failed to handle window rename, becoming defunct", .{});
                    return self.defunct();
                };
            },

            // Window was closed. Remove it and any orphaned panes.
            .window_close => |info| {
                self.windowClose(
                    &actions,
                    info.id,
                ) catch {
                    log.warn("failed to handle window close, becoming defunct", .{});
                    return self.defunct();
                };
            },

            // The active window in our session changed (e.g., the user
            // switched windows via tmux prefix+n). Track it so the apprt
            // can highlight the correct tab. The stream_handler sends the
            // surface notification directly from the raw control notification.
            .session_window_changed => |info| {
                if (info.session_id == self.session_id) {
                    self.active_window_id = info.window_id;
                }
            },

            // This is for other clients, which we don't do anything about.
            // For us, we'll get `exit` or `session_changed`, respectively.
            .client_detached,
            .client_session_changed,
            => {},

            // Pane mode changes — forwarded by stream_handler directly.
            .pane_mode_changed => {},

            // Session renamed. Update our stored session name. The
            // stream_handler sends the surface notification directly
            // from the raw control notification.
            .session_renamed => |info| {
                if (info.id == self.session_id) {
                    // Dupe the name into self.alloc since info.name is
                    // a view into the parser buffer, invalidated on the next
                    // call to next().
                    const duped = self.alloc.dupe(u8, info.name) catch {
                        log.warn("failed to dupe session name", .{});
                        return self.defunct();
                    };
                    if (self.session_name) |old| self.alloc.free(old);
                    self.session_name = duped;
                }
            },

            // Unlinked window notifications are for windows in sessions other
            // than the one we're attached to. The viewer only manages the
            // attached session, so these are no-ops.
            .unlinked_window_add,
            .unlinked_window_close,
            .unlinked_window_renamed,
            => {},

            // Flow control: tmux paused output for a pane. Record the
            // pause state. Since the viewer processes all queued output
            // synchronously before reaching %pause, we have already
            // consumed everything — immediately send continue to resume.
            .pause => |info| {
                if (self.panes.getEntry(info.pane_id)) |entry| {
                    entry.value_ptr.paused = true;
                    log.info("pane {} paused by tmux flow control, sending continue", .{info.pane_id});

                    // Signal the caller (stream_handler) to send a
                    // `refresh-client -A '%N:continue'` command for this
                    // pane. The caller formats and sends it directly,
                    // then calls trackFireAndForget().
                    self.pause_continue_pane_id = info.pane_id;
                } else {
                    log.warn("received %pause for unknown pane {}", .{info.pane_id});
                }
            },

            // Flow control: tmux continued a previously paused pane.
            .continue_pane => |info| {
                if (self.panes.getEntry(info.pane_id)) |entry| {
                    entry.value_ptr.paused = false;
                    log.info("pane {} continued by tmux flow control", .{info.pane_id});
                } else {
                    log.warn("received %continue for unknown pane {}", .{info.pane_id});
                }
            },

            // Flow control: extended output replaces %output when flow
            // control is enabled. Process the data identically to %output;
            // the age_ms metadata is logged but not yet used for adaptive
            // throttling.
            .extended_output => |out| {
                if (out.age_ms > 5000) {
                    log.warn(
                        "pane {} output is {}ms behind",
                        .{ out.pane_id, out.age_ms },
                    );
                }
                self.receivedOutput(
                    out.pane_id,
                    out.data,
                ) catch |err| {
                    log.warn(
                        "failed to process extended output for pane id={}: {}",
                        .{ out.pane_id, err },
                    );
                };
            },

            // Format subscription changed — forwarded by stream_handler directly.
            .subscription_changed => {},

            // Display message — forwarded by stream_handler directly.
            .message => {},

            // Paste buffer changed — forwarded by stream_handler directly.
            .paste_buffer_changed => {},

            // Paste buffer deleted — forwarded by stream_handler directly.
            .paste_buffer_deleted => {},

            // Configuration file error. Log as a warning — this is
            // informational and not critical enough to surface to the
            // apprt as an action.
            .config_error => |text| {
                log.warn("tmux config error: {s}", .{text});
            },
        }

        // After processing commands, we add our next command to
        // execute if we have one. We do this last because command
        // processing may itself queue more commands. We only emit a
        // command if a prior command was consumed (or never existed).
        if (self.state == .command_queue and command_consumed) {
            // Skip any commands that are gated on a tmux version we
            // don't meet. This handles the case where enable_flow_control
            // was queued but the tmux server is older than 3.2.
            while (self.command_queue.first()) |queued| {
                if (!queued.meetsVersionRequirement(self.parsed_version)) {
                    log.info("skipping command {s}: requires newer tmux", .{@tagName(queued.*)});
                    queued.deinit(self.alloc);
                    self.command_queue.deleteOldest(1);
                    continue;
                }
                break;
            }

            if (self.command_queue.first()) |next_command| {
                // We should not have any commands, because our nextCommand
                // always queues them.
                if (comptime std.debug.runtime_safety) {
                    for (actions.items) |action| {
                        if (action == .command) assert(false);
                    }
                }

                var arena = self.action_arena.promote(self.alloc);
                defer self.action_arena = arena.state;
                const arena_alloc = arena.allocator();

                var builder: std.Io.Writer.Allocating = .init(arena_alloc);
                next_command.formatCommand(&builder.writer) catch
                    return self.defunct();
                actions.append(
                    arena_alloc,
                    .{ .command = builder.writer.buffered() },
                ) catch return self.defunct();
            } else if (!self.initial_ready_sent) {
                // The command queue has drained for the first time after
                // startup. Signal that the viewer is ready — user input
                // is now safe to send without interleaving with viewer
                // commands.
                self.initial_ready_sent = true;
                self.ready_just_fired = true;
            }
        }

        return actions.items;
    }

    /// When the layout changes for a single window, a pane may be added
    /// or removed that we've never seen, in addition to the layout itself
    /// physically changing.
    ///
    /// To handle this, its similar to list-windows except we expect the
    /// window to already exist. We update the layout, do the initLayout
    /// call for any diffs, setup commands to capture any new panes,
    /// prune any removed panes.
    fn layoutChanged(
        self: *Viewer,
        actions: *std.ArrayList(Action),
        window_id: usize,
        layout_str: []const u8,
    ) !void {
        // Find the window this layout change is for.
        const window: *Window = window: for (self.windows.items) |*w| {
            if (w.id == window_id) break :window w;
        } else {
            log.info("layout change for unknown window id={}", .{window_id});
            return;
        };

        // Clear our prior window arena and setup our layout
        window.layout = layout: {
            var arena = window.layout_arena.promote(self.alloc);
            defer window.layout_arena = arena.state;
            _ = arena.reset(.retain_capacity);
            break :layout Layout.parseWithChecksum(
                arena.allocator(),
                layout_str,
            ) catch |err| {
                log.info(
                    "failed to parse window layout id={} layout={s}",
                    .{ window_id, layout_str },
                );
                return err;
            };
        };

        // Stash the raw layout string so it can cross the C API boundary.
        if (window.raw_layout.len > 0) self.alloc.free(window.raw_layout);
        window.raw_layout = try self.alloc.dupe(u8, layout_str);

        // Reset our arena so we can build up actions.
        var arena = self.action_arena.promote(self.alloc);
        defer self.action_arena = arena.state;
        const arena_alloc = arena.allocator();

        // Our initial action is to definitely let the caller know that
        // some windows changed.
        try actions.append(arena_alloc, .{ .windows = self.windows.items });

        // Sync up our panes
        try self.syncLayouts(self.windows.items);
    }

    /// When a window is added to the session, we need to refresh our window
    /// list to get the new window's information.
    fn windowAdd(
        self: *Viewer,
        window_id: usize,
    ) !void {
        _ = window_id; // We refresh all windows via list-windows

        // Queue list-windows to get the updated window list
        try self.queueCommands(&.{.list_windows});
    }

    /// When a window is renamed, update the stored name and emit a
    /// `.windows` action so the apprt can refresh its tab bar.
    fn windowRenamed(
        self: *Viewer,
        actions: *std.ArrayList(Action),
        window_id: usize,
        new_name: []const u8,
    ) !void {
        const window: *Window = window: for (self.windows.items) |*w| {
            if (w.id == window_id) break :window w;
        } else {
            log.info("window rename for unknown window id={}", .{window_id});
            return;
        };

        // Replace the old name with the new one.
        if (window.name.len > 0) self.alloc.free(window.name);
        window.name = if (new_name.len > 0)
            try self.alloc.dupe(u8, new_name)
        else
            "";

        // Notify the apprt that windows changed so it can refresh.
        try self.appendAction(actions, .{ .windows = self.windows.items });
    }

    /// When a window is closed, remove it from our list, prune any panes
    /// that are no longer referenced by any remaining window layout, and
    /// emit a `.windows` action.
    fn windowClose(
        self: *Viewer,
        actions: *std.ArrayList(Action),
        window_id: usize,
    ) !void {
        // Find and remove the window.
        const idx: ?usize = idx: for (self.windows.items, 0..) |*w, i| {
            if (w.id == window_id) break :idx i;
        } else null;

        if (idx) |i| {
            var window = self.windows.orderedRemove(i);
            window.deinit(self.alloc);
        } else {
            log.info("window close for unknown window id={}", .{window_id});
            return;
        }

        // Clear active_window_id if it was this window.
        if (self.active_window_id) |awid| {
            if (awid == window_id) self.active_window_id = null;
        }

        // Sync layouts to prune orphaned panes. This re-evaluates which
        // panes are still referenced by remaining windows.
        try self.syncLayouts(self.windows.items);

        // Notify the apprt.
        try self.appendAction(actions, .{ .windows = self.windows.items });
    }

    fn syncLayouts(
        self: *Viewer,
        windows: []const Window,
    ) !void {
        // Go through the window layout and setup all our panes. We move
        // this into a new panes map so that we can easily prune our old
        // list.
        var panes: PanesMap = .empty;
        errdefer {
            // Clear out all the new panes.
            var panes_it = panes.iterator();
            while (panes_it.next()) |kv| {
                if (!self.panes.contains(kv.key_ptr.*)) {
                    kv.value_ptr.deinit(self.alloc);
                }
            }
            panes.deinit(self.alloc);
        }
        for (windows) |window| try initLayout(
            self.alloc,
            &self.panes,
            &panes,
            window.layout,
        );

        // Build up the list of removed panes.
        var removed: std.ArrayList(usize) = removed: {
            var removed: std.ArrayList(usize) = .empty;
            errdefer removed.deinit(self.alloc);
            var panes_it = self.panes.iterator();
            while (panes_it.next()) |kv| {
                if (panes.contains(kv.key_ptr.*)) continue;
                try removed.append(self.alloc, kv.key_ptr.*);
            }

            break :removed removed;
        };
        defer removed.deinit(self.alloc);

        // Ensure we can add the windows
        try self.windows.ensureTotalCapacity(self.alloc, windows.len);

        // Get our list of added panes and setup our command queue
        // to populate them.
        //
        // No errdefer cleanup needed for the queued commands: the command
        // variants are value types (union enum) that don't own heap memory,
        // and any queued commands are reclaimed when the viewer is eventually
        // deinitialized by its owner.
        {
            var panes_it = panes.iterator();
            var added: bool = false;
            while (panes_it.next()) |kv| {
                const pane_id: usize = kv.key_ptr.*;
                if (self.panes.contains(pane_id)) continue;
                added = true;
                try self.queueCommands(&.{
                    .{ .pane_history = .{ .id = pane_id, .screen_key = .primary } },
                    .{ .pane_visible = .{ .id = pane_id, .screen_key = .primary } },
                    .{ .pane_history = .{ .id = pane_id, .screen_key = .alternate } },
                    .{ .pane_visible = .{ .id = pane_id, .screen_key = .alternate } },
                });
            }

            // If we added any panes, then we also want to resync the pane
            // state (terminal modes and cursor positions and so on).
            if (added) try self.queueCommands(&.{.pane_state});
        }

        // No more errors after this point. We're about to replace all
        // our owned state with our temporary state, and our errdefers
        // above will double-free if there is an error.
        errdefer comptime unreachable;

        // Replace our window list if it changed. We assume it didn't
        // change if our pointer is pointing to the same data.
        if (windows.ptr != self.windows.items.ptr) {
            for (self.windows.items) |*window| window.deinit(self.alloc);
            self.windows.clearRetainingCapacity();
            self.windows.appendSliceAssumeCapacity(windows);
        }

        // Replace our panes
        {
            // First remove our old panes
            for (removed.items) |id| if (self.panes.fetchSwapRemove(
                id,
            )) |entry_const| {
                var entry = entry_const;
                entry.value.deinit(self.alloc);
            };
            // We can now deinit self.panes because the existing
            // entries are preserved.
            self.panes.deinit(self.alloc);
            self.panes = panes;
        }
    }

    /// When a session changes, we have to basically reset our whole state.
    /// To do this, we emit an empty windows event (so callers can clear all
    /// windows), reset ourself, and start all over.
    fn sessionChanged(
        self: *Viewer,
        actions: *std.ArrayList(Action),
        session_id: usize,
    ) (Allocator.Error || std.Io.Writer.Error)!void {
        // Build up a new viewer. Its the easiest way to reset ourselves.
        var replacement: Viewer = try .init(self.alloc);
        errdefer replacement.deinit();

        // Our actions must start out empty so we don't mix arenas
        assert(actions.items.len == 0);
        errdefer actions.* = .empty;

        // Build actions: empty windows notification + list-windows command
        var arena = replacement.action_arena.promote(replacement.alloc);
        const arena_alloc = arena.allocator();
        try actions.append(arena_alloc, .{ .windows = &.{} });

        // Setup our command queue and put ourselves in the command queue
        // state.
        try replacement.queueCommands(&.{.list_windows});
        replacement.state = .command_queue;

        // Transfer preserved version to replacement
        replacement.tmux_version = try replacement.alloc.dupe(u8, self.tmux_version);
        replacement.parsed_version = self.parsed_version;

        // Save arena state back before swap
        replacement.action_arena = arena.state;

        // Swap our self, no more error handling after this.
        errdefer comptime unreachable;
        self.deinit();
        self.* = replacement;

        // Set our session ID and jump directly to the list
        self.session_id = session_id;

        assert(self.state == .command_queue);
    }

    fn receivedCommandOutput(
        self: *Viewer,
        actions: *std.ArrayList(Action),
        content: []const u8,
        is_err: bool,
    ) !void {
        // Get the command we're expecting output for. We need to get the
        // non-pointer value because we are deleting it from the circular
        // buffer immediately. This shallow copy is all we need since
        // all the memory in Command is owned by GPA.
        const command: Command = if (self.command_queue.first()) |ptr| switch (ptr.*) {
            // I truly can't explain this. A simple `ptr.*` copy will cause
            // our memory to become undefined when deleteOldest is called
            // below. I logged all the pointers and they don't match so I
            // don't know how its being set to undefined. But a copy like
            // this does work.
            inline else => |v, tag| @unionInit(
                Command,
                @tagName(tag),
                v,
            ),
        } else {
            // No pending commands in the queue. Check if this response
            // belongs to a fire-and-forget action (send-keys, flow control
            // continue) that was dispatched outside the command queue.
            if (self.pending_fire_and_forget > 0) {
                self.pending_fire_and_forget -= 1;
                log.debug("consumed fire-and-forget response (remaining={})", .{self.pending_fire_and_forget});
                return;
            }
            // Truly unexpected output — nothing in queue and no pending
            // fire-and-forget actions.
            log.warn("unexpected block output err={} with empty queue and no pending fire-and-forget", .{is_err});
            return;
        };
        self.command_queue.deleteOldest(1);
        defer command.deinit(self.alloc);

        // We'll use our arena for the return value here so we can
        // easily accumulate actions.
        var arena = self.action_arena.promote(self.alloc);
        defer self.action_arena = arena.state;
        const arena_alloc = arena.allocator();

        // Process our command. If the response is an error, log it and
        // skip processing for commands where error content is meaningless
        // (pane captures). For other commands, let the handler deal with
        // potentially empty/malformed content — they already have error
        // paths that handle parse failures gracefully.
        if (is_err) {
            log.warn("tmux command error for {s}: {s}", .{
                @tagName(command),
                if (content.len > 0) content[0..@min(content.len, 200)] else "(empty)",
            });
            switch (command) {
                // Pane capture errors are expected when a pane is destroyed
                // between queueing the command and receiving the response.
                // Silently skip — the pane will be cleaned up by layout sync.
                .pane_history, .pane_visible => return,
                else => {},
            }
        }

        switch (command) {
            .user => {
                self.last_command_response = .{
                    .content = content,
                    .is_error = is_err,
                };
            },

            .pane_state => try self.receivedPaneState(content),

            .list_windows => try self.receivedListWindows(
                arena_alloc,
                actions,
                content,
            ),

            .pane_history => |cap| try self.receivedPaneHistory(
                cap.screen_key,
                cap.id,
                content,
            ),

            .pane_visible => |cap| try self.receivedPaneVisible(
                cap.screen_key,
                cap.id,
                content,
            ),

            .tmux_version => try self.receivedTmuxVersion(content),

            // Flow control enable response: nothing to parse. The server
            // acknowledges the flag silently.
            .enable_flow_control => {},

            // Subscription registration response: nothing to parse.
            // The server acknowledges the subscription silently.
            .register_subscriptions => {},
        }
    }

    fn receivedTmuxVersion(
        self: *Viewer,
        content: []const u8,
    ) !void {
        const line = std.mem.trim(u8, content, " \t\r\n");
        if (line.len == 0) return;

        const data = output.parseFormatStruct(
            Format.tmux_version.Struct(),
            line,
            Format.tmux_version.delim,
        ) catch |err| {
            log.info("failed to parse tmux version: {s}", .{line});
            return err;
        };

        if (self.tmux_version.len > 0) {
            self.alloc.free(self.tmux_version);
        }
        self.tmux_version = try self.alloc.dupe(u8, data.version);
        self.parsed_version = TmuxVersion.parse(data.version);

        if (self.parsed_version == null) {
            log.warn("could not parse tmux version: {s}", .{data.version});
        }
    }

    fn receivedListWindows(
        self: *Viewer,
        arena_alloc: Allocator,
        actions: *std.ArrayList(Action),
        content: []const u8,
    ) !void {
        // If there is an error, reset our actions to what it was before.
        // Capture the length now — at errdefer-run time, actions.items.len
        // would already reflect the appended items, making shrink a no-op.
        const actions_start = actions.items.len;
        errdefer actions.shrinkRetainingCapacity(actions_start);

        // This stores our new window state from this list-windows output.
        var windows: std.ArrayList(Window) = .empty;
        errdefer {
            // On error, each partially-built window may own a layout_arena
            // and heap-duped name/raw_layout strings. We must deinit them
            // individually before freeing the ArrayList backing store.
            for (windows.items) |*w| w.deinit(self.alloc);
            windows.deinit(self.alloc);
        }

        // Parse all our windows
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0) continue;
            const data = output.parseFormatStruct(
                Format.list_windows.Struct(),
                line,
                Format.list_windows.delim,
            ) catch |err| {
                log.info("failed to parse list-windows line: {s}", .{line});
                return err;
            };

            // Parse the layout
            var arena: ArenaAllocator = .init(self.alloc);
            errdefer arena.deinit();
            const window_alloc = arena.allocator();
            const layout: Layout = Layout.parseWithChecksum(
                window_alloc,
                data.window_layout,
            ) catch |err| {
                log.info(
                    "failed to parse window layout id={} layout={s}",
                    .{ data.window_id, data.window_layout },
                );
                return err;
            };

            // Build the window value before appending so that errdefer
            // can clean up partial allocations if a later step fails.
            const name: []const u8 = if (data.window_name.len > 0)
                try self.alloc.dupe(u8, data.window_name)
            else
                "";
            errdefer if (name.len > 0) self.alloc.free(name);

            const raw_layout = try self.alloc.dupe(u8, data.window_layout);
            errdefer self.alloc.free(raw_layout);

            try windows.append(self.alloc, .{
                .id = data.window_id,
                .width = data.window_width,
                .height = data.window_height,
                .layout_arena = arena.state,
                .layout = layout,
                .name = name,
                .raw_layout = raw_layout,
            });
        }

        // Setup our windows action so the caller can process GUI
        // window changes. We must dupe into the arena because `windows`
        // is a local ArrayList whose backing memory is freed when this
        // function returns. Without the dupe, the action would hold a
        // dangling pointer (use-after-free).
        const arena_windows = try arena_alloc.dupe(Window, windows.items);
        try actions.append(arena_alloc, .{ .windows = arena_windows });

        // Sync up our layouts. This will populate unknown panes, prune, etc.
        // On success, syncLayouts takes ownership of the window internals
        // (layout_arena, name, raw_layout) by shallow-copying into self.windows.
        // We only need to free the ArrayList backing store afterward.
        try self.syncLayouts(windows.items);
        windows.deinit(self.alloc);
    }

    fn receivedPaneState(
        self: *Viewer,
        content: []const u8,
    ) !void {
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0) continue;

            const data = output.parseFormatStruct(
                Format.list_panes.Struct(),
                line,
                Format.list_panes.delim,
            ) catch |err| {
                log.info("failed to parse list-panes line: {s}", .{line});
                return err;
            };

            // Get the pane for this ID
            const entry = self.panes.getEntry(data.pane_id) orelse {
                log.info("received pane state for untracked pane id={}", .{data.pane_id});
                continue;
            };
            const pane: *Pane = entry.value_ptr;
            const t: *Terminal = &pane.terminal;

            // Determine which screen to use based on alternate_on
            const screen_key: ScreenSet.Key = if (data.alternate_on) .alternate else .primary;

            // Switch the terminal to the correct active screen. The capture-pane
            // sequence leaves the terminal on the alternate screen (because it
            // captures alternate last), so we must restore the correct screen here.
            // Without this, the renderer would show the alternate screen (blank for
            // a normal shell), and subsequent %output would write to the wrong screen.
            //
            // Use the lightweight switchTo when the screen already exists to avoid
            // the side effects of switchScreen (clearing selection, ending
            // hyperlinks, copying charset state, setting dirty flags). Fall back
            // to switchScreen only when the screen hasn't been initialized yet
            // (e.g., first time seeing the alternate screen).
            if (t.screens.active_key != screen_key) {
                if (t.screens.get(screen_key) != null) {
                    t.screens.switchTo(screen_key);
                } else {
                    _ = try t.switchScreen(screen_key);
                }
            }

            // Set cursor position on the appropriate screen (tmux uses 0-based)
            if (t.screens.get(screen_key)) |screen| {
                cursor: {
                    const cursor_x = std.math.cast(
                        size.CellCountInt,
                        data.cursor_x,
                    ) orelse break :cursor;
                    const cursor_y = std.math.cast(
                        size.CellCountInt,
                        data.cursor_y,
                    ) orelse break :cursor;
                    if (cursor_x >= screen.pages.cols or
                        cursor_y >= screen.pages.rows) break :cursor;
                    screen.cursorAbsolute(cursor_x, cursor_y);
                }

                // Set cursor shape on this screen
                if (data.cursor_shape.len > 0) {
                    if (std.mem.eql(u8, data.cursor_shape, "block")) {
                        screen.cursor.cursor_style = .block;
                    } else if (std.mem.eql(u8, data.cursor_shape, "underline")) {
                        screen.cursor.cursor_style = .underline;
                    } else if (std.mem.eql(u8, data.cursor_shape, "bar")) {
                        screen.cursor.cursor_style = .bar;
                    }
                }
                // "default" or unknown: leave as-is
            }

            // Set alternate screen saved cursor position
            if (t.screens.get(.alternate)) |alt_screen| cursor: {
                const alt_x = std.math.cast(
                    size.CellCountInt,
                    data.alternate_saved_x,
                ) orelse break :cursor;
                const alt_y = std.math.cast(
                    size.CellCountInt,
                    data.alternate_saved_y,
                ) orelse break :cursor;

                // If our coordinates are outside our screen we ignore it.
                // tmux actually sends MAX_INT for when there isn't a set
                // cursor position, so this isn't theoretical.
                if (alt_x >= alt_screen.pages.cols or
                    alt_y >= alt_screen.pages.rows) break :cursor;

                alt_screen.cursorAbsolute(alt_x, alt_y);
            }

            // Set cursor visibility
            t.modes.set(.cursor_visible, data.cursor_flag);

            // Set cursor blinking
            t.modes.set(.cursor_blinking, data.cursor_blinking);

            // Terminal modes
            t.modes.set(.insert, data.insert_flag);
            t.modes.set(.wraparound, data.wrap_flag);
            t.modes.set(.keypad_keys, data.keypad_flag);
            t.modes.set(.cursor_keys, data.keypad_cursor_flag);
            t.modes.set(.origin, data.origin_flag);

            // Mouse modes — set both modes (for DECRPM queries) and flags
            // (for Surface mouse reporting). The flags must reflect the
            // highest-numbered enabled mode, matching stream_handler behavior
            // where the last DECSET wins.
            t.modes.set(.mouse_event_any, data.mouse_all_flag);
            t.modes.set(.mouse_event_button, data.mouse_any_flag);
            t.modes.set(.mouse_event_normal, data.mouse_button_flag);
            t.modes.set(.mouse_event_x10, data.mouse_standard_flag);
            t.modes.set(.mouse_format_utf8, data.mouse_utf8_flag);
            t.modes.set(.mouse_format_sgr, data.mouse_sgr_flag);

            // Sync flags.mouse_event from modes. Higher-numbered modes
            // take priority (any > button > normal > x10), matching the
            // precedence order that stream_readonly applies.
            t.flags.mouse_event = if (data.mouse_all_flag)
                .any
            else if (data.mouse_any_flag)
                .button
            else if (data.mouse_button_flag)
                .normal
            else if (data.mouse_standard_flag)
                .x10
            else
                .none;

            // Sync flags.mouse_format from modes.
            t.flags.mouse_format = if (data.mouse_sgr_flag)
                .sgr
            else if (data.mouse_utf8_flag)
                .utf8
            else
                .x10;

            // Focus and bracketed paste
            t.modes.set(.focus_event, data.focus_flag);
            t.modes.set(.bracketed_paste, data.bracketed_paste);

            // Scroll region (tmux uses 0-based values)
            scroll: {
                const scroll_top = std.math.cast(
                    size.CellCountInt,
                    data.scroll_region_upper,
                ) orelse break :scroll;
                const scroll_bottom = std.math.cast(
                    size.CellCountInt,
                    data.scroll_region_lower,
                ) orelse break :scroll;
                t.scrolling_region.top = scroll_top;
                t.scrolling_region.bottom = scroll_bottom;
            }

            // Tab stops - parse comma-separated list and set
            t.tabstops.reset(0); // Clear all tabstops first
            if (data.pane_tabs.len > 0) {
                var tabs_it = std.mem.splitScalar(u8, data.pane_tabs, ',');
                while (tabs_it.next()) |tab_str| {
                    const col = std.fmt.parseInt(usize, tab_str, 10) catch continue;
                    const col_cell = std.math.cast(size.CellCountInt, col) orelse continue;
                    if (col_cell >= t.cols) continue;
                    t.tabstops.set(col_cell);
                }
            }
        }
    }

    fn receivedPaneHistory(
        self: *Viewer,
        screen_key: ScreenSet.Key,
        id: usize,
        content: []const u8,
    ) !void {
        // Get our pane
        const entry = self.panes.getEntry(id) orelse {
            log.info("received pane history for untracked pane id={}", .{id});
            return;
        };
        const pane: *Pane = entry.value_ptr;
        const t: *Terminal = &pane.terminal;
        _ = try t.switchScreen(screen_key);
        const screen: *Screen = t.screens.active;

        // Get a VT stream from the terminal so we can send data as-is into
        // it. This will populate the active area too so it won't be exactly
        // correct but we'll get the active contents soon.
        var stream = t.vtStream();
        defer stream.deinit();
        stream.nextSlice(content) catch |err| {
            log.info("failed to process pane history for pane id={}: {}", .{ id, err });
            return err;
        };

        // Populate the active area to be empty since this is only history.
        // We'll fill it with blanks and move the cursor to the top-left.
        t.carriageReturn();
        for (0..t.rows) |_| try t.index();
        t.setCursorPos(1, 1);

        // Our active area should be empty
        if (comptime std.debug.runtime_safety) {
            var discarding: std.Io.Writer.Discarding = .init(&.{});
            screen.dumpString(&discarding.writer, .{
                .tl = screen.pages.getTopLeft(.active),
                .unwrap = false,
            }) catch unreachable;
            assert(discarding.count == 0);
        }
    }

    fn receivedPaneVisible(
        self: *Viewer,
        screen_key: ScreenSet.Key,
        id: usize,
        content: []const u8,
    ) !void {
        // Get our pane
        const entry = self.panes.getEntry(id) orelse {
            log.info("received pane visible for untracked pane id={}", .{id});
            return;
        };
        const pane: *Pane = entry.value_ptr;
        const t: *Terminal = &pane.terminal;
        _ = try t.switchScreen(screen_key);

        // Erase the active area and reset the cursor to the top-left
        // before writing the visible content.
        t.eraseDisplay(.complete, false);
        t.setCursorPos(1, 1);

        var stream = t.vtStream();
        defer stream.deinit();
        stream.nextSlice(content) catch |err| {
            log.info("failed to process pane visible for pane id={}: {}", .{ id, err });
            return err;
        };
    }

    fn receivedOutput(
        self: *Viewer,
        id: usize,
        raw_data: []const u8,
    ) !void {
        const entry = self.panes.getEntry(id) orelse {
            log.info("received output for untracked pane id={}", .{id});
            return;
        };
        const pane: *Pane = entry.value_ptr;
        const t: *Terminal = &pane.terminal;

        // Decode tmux octal escapes (\NNN for bytes <32 and backslash)
        // in-place on a mutable copy. This is deferred from the parser
        // (control.zig) to avoid unnecessary work for untracked or
        // discarded pane output. We dupe because the input slice may
        // alias read-only memory (e.g. string literals in tests, or
        // comptime-known data in the parser's notification union).
        const buf = try self.alloc.dupe(u8, raw_data);
        defer self.alloc.free(buf);
        const data = control.Parser.unescapeOctal(buf);

        // Use pane's persistent parser state to handle CSI sequences
        // that span multiple %output messages. We start with the
        // standard vtStream() (which produces a correctly-initialized
        // ReadonlyStream with a fresh parser in ground state), then
        // swap in the pane's saved parser/utf8decoder. After processing
        // we save the parser state back and hand deinit a fresh parser
        // so it only frees that throw-away instance.
        var stream = t.vtStream();
        // Swap in persistent parser state from the pane.
        stream.parser = pane.vt_parser;
        stream.utf8decoder = pane.vt_utf8decoder;
        // Restore the OSC parser allocator lost during the swap.
        // VTParser.init() sets osc_parser.alloc = null; vtStream()
        // sets it via initAlloc(), but our parser swap overwrites it.
        // Without this, multi-field OSC sequences (OSC 4, 10, 11)
        // are silently dropped.
        stream.parser.osc_parser.alloc = self.alloc;
        defer {
            // DCS/OSC/APC sequences within %output data that span to
            // the end of a message are passthrough sequences meant for
            // the outer terminal, not for this pane. The ReadonlyStream
            // handler ignores them anyway, but the parser would remain
            // trapped in an absorbing state across messages if we
            // persisted it as-is (dcs_passthrough in particular can
            // only be exited by the 8-bit C1 ST, which tmux never
            // sends in 7-bit control mode). Reset to ground so the
            // next message starts clean.
            //
            // CSI/escape states are safe to persist: they are
            // short-lived and exit on the next final byte, which is
            // the exact split-sequence case we need to handle.
            switch (stream.parser.state) {
                .dcs_passthrough,
                .dcs_entry,
                .dcs_param,
                .dcs_intermediate,
                .dcs_ignore,
                .sos_pm_apc_string,
                => {
                    stream.parser.state = .ground;
                    stream.parser.clear();
                },
                .osc_string => {
                    stream.parser.osc_parser.reset();
                    stream.parser.state = .ground;
                    stream.parser.clear();
                },
                else => {},
            }

            // Save updated parser state back to the pane.
            pane.vt_parser = stream.parser;
            pane.vt_utf8decoder = stream.utf8decoder;
            // Give deinit a fresh parser to clean up (prevents it
            // from freeing the parser we just saved to the pane).
            stream.parser = .init();
            stream.deinit();
        }
        // Use try — callers catch and log with their own context
        // (pane ID, whether it's extended output, etc.).
        try stream.nextSlice(data);

        // Notify the caller (e.g., stream_handler) that output was
        // processed for this pane, so it can wake observer renderers
        // or perform other post-output actions.
        if (self.output_cb) |cb| cb(self.output_ud, id);
    }

    fn initLayout(
        gpa_alloc: Allocator,
        panes_old: *const PanesMap,
        panes_new: *PanesMap,
        layout: Layout,
    ) !void {
        switch (layout.content) {
            // Nested layouts, continue going.
            .horizontal, .vertical => |layouts| {
                for (layouts) |l| {
                    try initLayout(
                        gpa_alloc,
                        panes_old,
                        panes_new,
                        l,
                    );
                }
            },

            // A leaf! Initialize.
            .pane => |id| pane: {
                const gop = try panes_new.getOrPut(gpa_alloc, id);
                if (gop.found_existing) break :pane;
                errdefer _ = panes_new.swapRemove(gop.key_ptr.*);

                // Validate layout dimensions fit in CellCountInt before
                // using them. Oversized dimensions from a corrupted or
                // adversarial layout would panic on @intCast.
                const cols: size.CellCountInt = std.math.cast(
                    size.CellCountInt,
                    layout.width,
                ) orelse {
                    log.warn("pane {} layout width {} overflows CellCountInt, skipping", .{ id, layout.width });
                    _ = panes_new.swapRemove(gop.key_ptr.*);
                    break :pane;
                };
                const rows: size.CellCountInt = std.math.cast(
                    size.CellCountInt,
                    layout.height,
                ) orelse {
                    log.warn("pane {} layout height {} overflows CellCountInt, skipping", .{ id, layout.height });
                    _ = panes_new.swapRemove(gop.key_ptr.*);
                    break :pane;
                };

                // If we already have this pane, it is already initialized
                // so just copy it over.
                if (panes_old.getEntry(id)) |entry| {
                    gop.value_ptr.* = entry.value_ptr.*;

                    // Resize the pane terminal if tmux assigned it new
                    // dimensions (e.g. after refresh-client -C). Without
                    // this, the pane's Terminal grid stays at its old size
                    // and output is rendered with the wrong dimensions.
                    if (gop.value_ptr.terminal.cols != cols or
                        gop.value_ptr.terminal.rows != rows)
                    {
                        try gop.value_ptr.terminal.resize(
                            gpa_alloc,
                            cols,
                            rows,
                        );
                    }

                    break :pane;
                }

                var t: Terminal = try .init(gpa_alloc, .{
                    .cols = cols,
                    .rows = rows,
                });
                errdefer t.deinit(gpa_alloc);

                gop.value_ptr.* = .{
                    .terminal = t,
                };
            },
        }
    }

    /// Enters the command queue state from any other state, queueing
    /// the commands and returning an action to execute the first command.
    fn enterCommandQueue(
        self: *Viewer,
        arena_alloc: Allocator,
        commands: []const Command,
    ) Allocator.Error![]const Action {
        assert(self.state != .command_queue);
        assert(commands.len > 0);

        // Build our command string to send for the action.
        var builder: std.Io.Writer.Allocating = .init(arena_alloc);
        commands[0].formatCommand(&builder.writer) catch return error.OutOfMemory;
        const action: Action = .{ .command = builder.writer.buffered() };

        // Add our commands
        try self.command_queue.ensureUnusedCapacity(self.alloc, commands.len);
        for (commands) |cmd| self.command_queue.appendAssumeCapacity(cmd);

        // Move into the command queue state
        self.state = .command_queue;

        return self.singleAction(action);
    }

    /// Queue multiple commands to execute. This doesn't add anything
    /// to the actions queue or return actions or anything because the
    /// command_queue state will automatically send the next command when
    /// it receives output.
    fn queueCommands(
        self: *Viewer,
        commands: []const Command,
    ) Allocator.Error!void {
        try self.command_queue.ensureUnusedCapacity(
            self.alloc,
            commands.len,
        );
        for (commands) |command| {
            self.command_queue.appendAssumeCapacity(command);
        }
    }

    /// Helper to return a single action. The input action may use the arena
    /// for allocated memory; this will not touch the arena.
    fn singleAction(self: *Viewer, action: Action) []const Action {
        // Make our single action slice.
        self.action_single[0] = action;
        return &self.action_single;
    }

    fn defunct(self: *Viewer) []const Action {
        return self.defunctWithReason("");
    }

    fn defunctWithReason(self: *Viewer, reason: []const u8) []const Action {
        self.state = .defunct;
        return self.singleAction(.{ .exit = reason });
    }

    /// Request a graceful detach from the tmux session. This sends
    /// `detach-client` to tmux, which will cause tmux to send %exit
    /// back to us (triggering the normal exit/cleanup flow).
    pub fn detach(self: *Viewer) []const Action {
        return self.singleAction(.{ .command = "detach-client\n" });
    }
};

const State = enum {
    /// We start in this state just after receiving the initial
    /// DCS 1000p opening sequence. We wait for an initial
    /// begin/end block that is guaranteed to be sent by tmux for
    /// the initial control mode command. (See tmux server-client.c
    /// where control mode starts).
    startup_block,

    /// After receiving the initial block, we wait for a session-changed
    /// notification to record the initial session ID.
    startup_session,

    /// Tmux has closed the control mode connection
    defunct,

    /// We're sitting on the command queue waiting for command output
    /// in the order provided in the `command_queue` field. This field
    /// isn't part of the state because it can be queued at any state.
    ///
    /// Precondition: if self.command_queue.len > 0, then the first
    /// command in the queue has already been sent to tmux (via a
    /// `command` Action). The next output is assumed to be the result
    /// of this command.
    ///
    /// To satisfy the above, any transitions INTO this state should
    /// send a command Action for the first command in the queue.
    command_queue,
};

const Command = union(enum) {
    /// List all windows so we can sync our window state.
    list_windows,

    /// Capture history for the given pane ID.
    pane_history: CapturePane,

    /// Capture visible area for the given pane ID.
    pane_visible: CapturePane,

    /// Capture the pane terminal state as best we can. The pane ID(s)
    /// are part of the output so we can map it back to our panes.
    pane_state,

    /// Get the tmux server version.
    tmux_version,

    /// Enable flow control by setting the pause-after flag. When enabled,
    /// tmux sends %extended-output instead of %output and will pause panes
    /// that fall more than the specified number of seconds behind.
    enable_flow_control,

    /// Register format subscriptions via refresh-client -B. This allows
    /// tmux to notify us when certain format values change (e.g., pane
    /// titles) without polling.
    register_subscriptions,

    /// User command. This is a command provided by the user. Since
    /// this is user provided, we can't be sure what it is.
    user: []const u8,

    const CapturePane = struct {
        id: usize,
        screen_key: ScreenSet.Key,
    };

    pub fn deinit(self: Command, alloc: Allocator) void {
        return switch (self) {
            .list_windows,
            .pane_history,
            .pane_visible,
            .pane_state,
            .tmux_version,
            .enable_flow_control,
            .register_subscriptions,
            => {},
            .user => |v| alloc.free(v),
        };
    }

    /// Returns true if the command is allowed to run given the current
    /// parsed tmux version. Commands that require a specific minimum
    /// version return false when the version is unknown (null) or too
    /// old. Most commands have no version requirement.
    pub fn meetsVersionRequirement(self: Command, version: ?Viewer.TmuxVersion) bool {
        return switch (self) {
            .enable_flow_control => if (version) |v| v.atLeast(Viewer.TmuxVersion.flow_control) else false,
            .register_subscriptions => if (version) |v| v.atLeast(Viewer.TmuxVersion.format_subscriptions) else false,
            // All other commands work on any version.
            .list_windows,
            .pane_history,
            .pane_visible,
            .pane_state,
            .tmux_version,
            .user,
            => true,
        };
    }

    /// Format the command into the command that should be executed
    /// by tmux. Trailing newlines are appended so this can be sent as-is
    /// to tmux.
    pub fn formatCommand(
        self: Command,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .list_windows => try writer.writeAll(std.fmt.comptimePrint(
                "list-windows -F '{s}'\n",
                .{comptime Format.list_windows.comptimeFormat()},
            )),

            .pane_history => |cap| try writer.print(
                // -p = output to stdout instead of buffer
                // -e = output escape sequences for SGR
                // -a = capture alternate screen (only valid for alternate)
                // -q = quiet, don't error if alternate screen doesn't exist
                // -S - = start at the top of history ("-")
                // -E -1 = end at the last line of history (1 before the
                //   visible area is -1).
                // -t %{d} = target a specific pane ID
                "capture-pane -p -e -q {s}-S - -E -1 -t %{d}\n",
                .{
                    if (cap.screen_key == .alternate) "-a " else "",
                    cap.id,
                },
            ),

            .pane_visible => |cap| try writer.print(
                // -p = output to stdout instead of buffer
                // -e = output escape sequences for SGR
                // -a = capture alternate screen (only valid for alternate)
                // -q = quiet, don't error if alternate screen doesn't exist
                // -t %{d} = target a specific pane ID
                // (no -S/-E = capture visible area only)
                "capture-pane -p -e -q {s}-t %{d}\n",
                .{
                    if (cap.screen_key == .alternate) "-a " else "",
                    cap.id,
                },
            ),

            .pane_state => try writer.writeAll(std.fmt.comptimePrint(
                "list-panes -F '{s}'\n",
                .{comptime Format.list_panes.comptimeFormat()},
            )),

            .tmux_version => try writer.writeAll(std.fmt.comptimePrint(
                "display-message -p '{s}'\n",
                .{comptime Format.tmux_version.comptimeFormat()},
            )),

            // Enable flow control with a 30-second pause threshold and
            // wait-exit mode. When the client falls 30+ seconds behind
            // on a pane's output, tmux pauses that pane and sends %pause.
            // The client can then catch up and send
            // `refresh-client -A '%N:continue'` to resume.
            // This replaces %output with %extended-output which includes
            // latency metadata.
            //
            // wait-exit tells tmux to wait for an empty-line acknowledgment
            // from the client after sending %exit, giving us time to
            // perform graceful cleanup before tmux closes the connection.
            .enable_flow_control => try writer.writeAll(
                "refresh-client -f wait-exit,pause-after=30\n",
            ),

            .register_subscriptions => try writer.writeAll(
                "refresh-client" ++
                    " -B 'pane_title:%*:#{pane_title}'" ++
                    " -B 'status_left::#{T:status-left}'" ++
                    " -B 'status_right::#{T:status-right}'" ++
                    "\n",
            ),

            .user => |v| try writer.writeAll(v),
        }
    }
};

/// Format strings used for commands in our viewer.
const Format = struct {
    /// The variables included in this format, in order.
    vars: []const output.Variable,

    /// The delimiter to use between variables. This must be a character
    /// guaranteed to not appear in any of the variable outputs.
    delim: u8,

    const list_panes: Format = .{
        .delim = ';',
        .vars = &.{
            .pane_id,
            // Cursor position & appearance
            .cursor_x,
            .cursor_y,
            .cursor_flag,
            .cursor_shape,
            .cursor_colour,
            .cursor_blinking,
            // Alternate screen
            .alternate_on,
            .alternate_saved_x,
            .alternate_saved_y,
            // Terminal modes
            .insert_flag,
            .wrap_flag,
            .keypad_flag,
            .keypad_cursor_flag,
            .origin_flag,
            // Mouse modes
            .mouse_all_flag,
            .mouse_any_flag,
            .mouse_button_flag,
            .mouse_standard_flag,
            .mouse_utf8_flag,
            .mouse_sgr_flag,
            // Focus & special features
            .focus_flag,
            .bracketed_paste,
            // Scroll region
            .scroll_region_upper,
            .scroll_region_lower,
            // Tab stops
            .pane_tabs,
        },
    };

    const list_windows: Format = .{
        .delim = ';',
        .vars = &.{
            .session_id,
            .window_id,
            .window_width,
            .window_height,
            .window_name,
            .window_layout,
        },
    };

    const tmux_version: Format = .{
        .delim = ' ',
        .vars = &.{.version},
    };

    /// The format string, available at comptime.
    pub fn comptimeFormat(comptime self: Format) []const u8 {
        return output.comptimeFormat(self.vars, self.delim);
    }

    /// The struct that can contain the parsed output.
    pub fn Struct(comptime self: Format) type {
        return output.FormatStruct(self.vars);
    }
};

const TestStep = struct {
    input: Viewer.Input,
    contains_tags: []const std.meta.Tag(Viewer.Action) = &.{},
    contains_command: []const u8 = "",
    /// Expect the viewer's ready_just_fired flag to be set after this step.
    expect_ready: bool = false,
    /// Expect the viewer's pause_continue_pane_id to be set to this pane
    /// after this step.
    expect_pause_continue_pane: ?usize = null,
    check: ?*const fn (viewer: *Viewer, []const Viewer.Action) anyerror!void = null,
    check_command: ?*const fn (viewer: *Viewer, []const u8) anyerror!void = null,

    fn run(self: TestStep, viewer: *Viewer) !void {
        const actions = viewer.next(self.input);

        // Common mistake, forgetting the newline on a command.
        for (actions) |action| {
            if (action == .command) {
                try testing.expect(std.mem.endsWith(u8, action.command, "\n"));
            }
        }

        for (self.contains_tags) |tag| {
            var found = false;
            for (actions) |action| {
                if (action == tag) {
                    found = true;
                    break;
                }
            }
            try testing.expect(found);
        }

        if (self.contains_command.len > 0) {
            var found = false;
            for (actions) |action| {
                if (action == .command and
                    std.mem.startsWith(u8, action.command, self.contains_command))
                {
                    found = true;
                    break;
                }
            }
            try testing.expect(found);
        }

        // Check field-based signals (replacements for former Action variants).
        if (self.expect_ready) {
            try testing.expect(viewer.ready_just_fired);
            viewer.ready_just_fired = false;
        }

        if (self.expect_pause_continue_pane) |expected_pane| {
            try testing.expectEqual(expected_pane, viewer.pause_continue_pane_id.?);
            viewer.pause_continue_pane_id = null;
        }

        if (self.check) |check_fn| {
            try check_fn(viewer, actions);
        }

        if (self.check_command) |check_fn| {
            var found = false;
            for (actions) |action| {
                if (action == .command) {
                    found = true;
                    try check_fn(viewer, action.command);
                }
            }
            try testing.expect(found);
        }
    }
};

/// A helper to run a series of test steps against a viewer and assert
/// that the expected actions are produced.
///
/// I'm generally not a fan of these types of abstracted tests because
/// it makes diagnosing failures harder, but being able to construct
/// simulated tmux inputs and verify outputs is going to be extremely
/// important since the tmux control mode protocol is very complex and
/// fragile.
fn testViewer(viewer: *Viewer, steps: []const TestStep) !void {
    for (steps, 0..) |step, i| {
        step.run(viewer) catch |err| {
            log.warn("testViewer step failed i={} step={}", .{ i, step });
            return err;
        };
    }
}

test "immediate exit" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{
            .input = .{ .tmux = .{ .exit = .{ .reason = "" } } },
            .contains_tags = &.{.exit},
        },
        .{
            .input = .{ .tmux = .{ .exit = .{ .reason = "" } } },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                }
            }).check,
        },
    });
}

test "exit propagates reason" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{
            .input = .{ .tmux = .{ .exit = .{ .reason = "detached" } } },
            .contains_tags = &.{.exit},
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    for (actions) |action| {
                        if (action == .exit) {
                            try testing.expectEqualStrings("detached", action.exit);
                            return;
                        }
                    }
                    return error.TestUnexpectedResult;
                }
            }).check,
        },
    });
}

test "exit with server-exited reason" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{
            .input = .{ .tmux = .{ .exit = .{ .reason = "server-exited" } } },
            .contains_tags = &.{.exit},
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    for (actions) |action| {
                        if (action == .exit) {
                            try testing.expectEqualStrings("server-exited", action.exit);
                            return;
                        }
                    }
                    return error.TestUnexpectedResult;
                }
            }).check,
        },
    });
}

test "session changed resets state" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "first",
            } } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "refresh-client",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
        // Receive window layout with two panes (same format as "initial flow" test)
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$1;@0;83;44;bash;027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1]
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, v.session_id);
                    try testing.expectEqual(1, v.windows.items.len);
                    try testing.expectEqual(2, v.panes.count());
                    try testing.expectEqualStrings("3.5a", v.tmux_version);
                }
            }).check,
        },
        // Now session changes - should reset everything but keep version
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 2,
                .name = "second",
            } } },
            .contains_tags = &.{ .windows, .command },
            .contains_command = "list-windows",
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // Session ID should be updated
                    try testing.expectEqual(2, v.session_id);
                    // Windows should be cleared (empty windows action sent)
                    var found_empty_windows = false;
                    for (actions) |action| {
                        if (action == .windows and action.windows.len == 0) {
                            found_empty_windows = true;
                        }
                    }
                    try testing.expect(found_empty_windows);
                    // Old windows should be cleared
                    try testing.expectEqual(0, v.windows.items.len);
                    // Old panes should be cleared
                    try testing.expectEqual(0, v.panes.count());
                    // Version should still be preserved
                    try testing.expectEqualStrings("3.5a", v.tmux_version);
                }
            }).check,
        },
        // Receive new window layout for new session (same layout, different session/window)
        // Uses same pane IDs 0,1 - they should be re-created since old panes were cleared
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$2;@1;83;44;bash;027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1]
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(2, v.session_id);
                    try testing.expectEqual(1, v.windows.items.len);
                    try testing.expectEqual(1, v.windows.items[0].id);
                    // Panes 0 and 1 should be created (fresh, since old ones were cleared)
                    try testing.expectEqual(2, v.panes.count());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = .{ .reason = "" } } },
            .contains_tags = &.{.exit},
        },
    });
}

test "initial flow" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 42,
                .name = "main",
            } } },
            .contains_command = "display-message",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(42, v.session_id);
                }
            }).check,
        },
        // Receive version response, which triggers enable_flow_control
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "refresh-client",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqualStrings("3.5a", v.tmux_version);
                }
            }).check,
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0;@0;83;44;bash;027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1]
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .contains_command = "capture-pane",
            // pane_history for pane 0 (primary)
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %0"));
                    try testing.expect(!std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\Hello, world!
                ,
            } },
            // Moves on to pane_visible for pane 0 (primary)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %0"));
                    try testing.expect(!std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                    const screen: *Screen = pane.terminal.screens.active;
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .history = .{} },
                        );
                        defer testing.allocator.free(str);
                        try testing.expectEqualStrings("Hello, world!", str);
                    }
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .active = .{} },
                        );
                        defer testing.allocator.free(str);
                        try testing.expectEqualStrings("", str);
                    }
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            // Moves on to pane_history for pane 0 (alternate)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %0"));
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            // Moves on to pane_visible for pane 0 (alternate)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %0"));
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            // Moves on to pane_history for pane 1 (primary)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %1"));
                    try testing.expect(!std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            // Moves on to pane_visible for pane 1 (primary)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %1"));
                    try testing.expect(!std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            // Moves on to pane_history for pane 1 (alternate)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %1"));
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            // Moves on to pane_visible for pane 1 (alternate)
            .contains_command = "capture-pane",
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-t %1"));
                    try testing.expect(std.mem.containsAtLeast(u8, command, 1, "-a"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
        },
        .{
            .input = .{ .tmux = .{ .output = .{ .pane_id = 0, .data = "new output" } } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                    const screen: *Screen = pane.terminal.screens.active;
                    const str = try screen.dumpStringAlloc(
                        testing.allocator,
                        .{ .active = .{} },
                    );
                    defer testing.allocator.free(str);
                    try testing.expect(std.mem.containsAtLeast(u8, str, 1, "new output"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .output = .{ .pane_id = 999, .data = "ignored" } } },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = .{ .reason = "" } } },
            .contains_tags = &.{.exit},
        },
    });
}

test "layout change" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "refresh-client",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0;@0;83;44;bash;b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, v.windows.items.len);
                    try testing.expectEqual(1, v.panes.count());
                    try testing.expect(v.panes.contains(0));
                }
            }).check,
        },
        // Complete all capture-pane commands for pane 0 (primary and alternate)
        // plus pane_state
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Now send a layout_change that splits into two panes
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .visible_layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .raw_flags = "*",
            } } },
            .contains_tags = &.{.windows},
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Should still have 1 window
                    try testing.expectEqual(1, v.windows.items.len);
                    // Should now have 2 panes (0 and 2)
                    try testing.expectEqual(2, v.panes.count());
                    try testing.expect(v.panes.contains(0));
                    try testing.expect(v.panes.contains(2));
                    // Commands should be queued for the new pane (4 capture-pane + 1 pane_state)
                    try testing.expectEqual(5, v.command_queue.len());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = .{ .reason = "" } } },
            .contains_tags = &.{.exit},
        },
    });
}

test "layout_change does not return command when queue not empty" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "refresh-client",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0;@0;83;44;bash;b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(!v.command_queue.empty());
                }
            }).check,
        },
        // Do NOT complete capture-pane commands - queue still has commands.
        // Send a layout_change that splits into two panes.
        // This should NOT return a command action since queue was not empty.
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .visible_layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .raw_flags = "*",
            } } },
            .contains_tags = &.{.windows},
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(2, v.panes.count());
                    // Should not contain a command action
                    for (actions) |action| {
                        try testing.expect(action != .command);
                    }
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = .{ .reason = "" } } },
            .contains_tags = &.{.exit},
        },
    });
}

test "layout_change returns command when queue was empty" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "refresh-client",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0;@0;83;44;bash;b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete all capture-pane commands for pane 0
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Queue should now be empty
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
        // Now send a layout_change that splits into two panes.
        // This should return a command action since we're queuing commands
        // for the new pane and the queue was empty.
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .visible_layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .raw_flags = "*",
            } } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(2, v.panes.count());
                    try testing.expect(!v.command_queue.empty());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = .{ .reason = "" } } },
            .contains_tags = &.{.exit},
        },
    });
}

test "window_add queues list_windows when queue empty" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "refresh-client",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0;@0;83;44;bash;b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete all capture-pane commands for pane 0
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Queue should now be empty
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
        // Now send window_add - should trigger list-windows command
        .{
            .input = .{ .tmux = .{ .window_add = .{ .id = 1 } } },
            .contains_command = "list-windows",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Command queue should have list_windows
                    try testing.expect(!v.command_queue.empty());
                    try testing.expectEqual(1, v.command_queue.len());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = .{ .reason = "" } } },
            .contains_tags = &.{.exit},
        },
    });
}

test "window_add queues list_windows when queue not empty" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "refresh-client",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0;@0;83;44;bash;b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Queue should have capture-pane commands
                    try testing.expect(!v.command_queue.empty());
                }
            }).check,
        },
        // Do NOT complete capture-pane commands - queue still has commands.
        // Send window_add - should queue list-windows but NOT return command action
        .{
            .input = .{ .tmux = .{ .window_add = .{ .id = 1 } } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // Should not contain a command action since queue was not empty
                    for (actions) |action| {
                        try testing.expect(action != .command);
                    }
                    // But list_windows should be in the queue
                    try testing.expect(!v.command_queue.empty());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = .{ .reason = "" } } },
            .contains_tags = &.{.exit},
        },
    });
}

test "two pane flow with pane state" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial block_end from attach
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Session changed notification
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 0,
                .name = "0",
            } } },
            .contains_command = "display-message",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, v.session_id);
                }
            }).check,
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "refresh-client",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
        // list-windows output with 2 panes in a vertical split
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0;@0;165;79;bash;ca97,165x79,0,0[165x40,0,0,0,165x38,0,41,4]
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, v.windows.items.len);
                    const window = v.windows.items[0];
                    try testing.expectEqual(0, window.id);
                    try testing.expectEqual(165, window.width);
                    try testing.expectEqual(79, window.height);
                    try testing.expectEqual(2, v.panes.count());
                    try testing.expect(v.panes.contains(0));
                    try testing.expect(v.panes.contains(4));
                }
            }).check,
        },
        // capture-pane pane 0 primary history
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\prompt %
                \\prompt %
                ,
            } },
        },
        // capture-pane pane 0 primary visible
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\prompt %
                ,
            } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                    const screen: *Screen = pane.terminal.screens.active;
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .history = .{} },
                        );
                        defer testing.allocator.free(str);
                        // History has 2 lines with "prompt %" (padded to screen width)
                        try testing.expect(std.mem.containsAtLeast(u8, str, 2, "prompt %"));
                    }
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .active = .{} },
                        );
                        defer testing.allocator.free(str);
                        try testing.expectEqualStrings("prompt %", str);
                    }
                }
            }).check,
        },
        // capture-pane pane 0 alternate history (empty)
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // capture-pane pane 0 alternate visible (empty)
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // capture-pane pane 4 primary history
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\prompt %
                ,
            } },
        },
        // capture-pane pane 4 primary visible
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\prompt %
                ,
            } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(4).?.value_ptr;
                    const screen: *Screen = pane.terminal.screens.active;
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .history = .{} },
                        );
                        defer testing.allocator.free(str);
                        try testing.expectEqualStrings("prompt %", str);
                    }
                    {
                        const str = try screen.dumpStringAlloc(
                            testing.allocator,
                            .{ .active = .{} },
                        );
                        defer testing.allocator.free(str);
                        // Active screen starts with "prompt %" at beginning
                        try testing.expect(std.mem.startsWith(u8, str, "prompt %"));
                    }
                }
            }).check,
        },
        // capture-pane pane 4 alternate history (empty)
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // capture-pane pane 4 alternate visible (empty)
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // list-panes output with terminal state
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\%0;42;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;;;0;39;8,16,24,32,40,48,56,64,72,80,88,96,104,112,120,128,136,144,152,160
                \\%4;10;5;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;;;0;37;8,16,24,32,40,48,56,64,72,80,88,96,104,112,120,128,136,144,152,160
                ,
            } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Pane 0: cursor at (42, 0), cursor visible, wraparound on
                    {
                        const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                        const t: *Terminal = &pane.terminal;
                        const screen: *Screen = t.screens.get(.primary).?;
                        try testing.expectEqual(42, screen.cursor.x);
                        try testing.expectEqual(0, screen.cursor.y);
                        try testing.expect(t.modes.get(.cursor_visible));
                        try testing.expect(t.modes.get(.wraparound));
                        try testing.expect(!t.modes.get(.insert));
                        try testing.expect(!t.modes.get(.origin));
                        try testing.expect(!t.modes.get(.keypad_keys));
                        try testing.expect(!t.modes.get(.cursor_keys));
                        // alternate_on=0 → active screen should be primary
                        try testing.expectEqual(.primary, t.screens.active_key);
                    }
                    // Pane 4: cursor at (10, 5), cursor visible, wraparound on
                    {
                        const pane: *Viewer.Pane = v.panes.getEntry(4).?.value_ptr;
                        const t: *Terminal = &pane.terminal;
                        const screen: *Screen = t.screens.get(.primary).?;
                        try testing.expectEqual(10, screen.cursor.x);
                        try testing.expectEqual(5, screen.cursor.y);
                        try testing.expect(t.modes.get(.cursor_visible));
                        try testing.expect(t.modes.get(.wraparound));
                        try testing.expect(!t.modes.get(.insert));
                        try testing.expect(!t.modes.get(.origin));
                        try testing.expect(!t.modes.get(.keypad_keys));
                        try testing.expect(!t.modes.get(.cursor_keys));
                        // alternate_on=0 → active screen should be primary
                        try testing.expectEqual(.primary, t.screens.active_key);
                    }
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = .{ .reason = "" } } },
            .contains_tags = &.{.exit},
        },
    });
}

test "setActivePaneId valid pane" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    // Manually create a pane in the panes map.
    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    errdefer t.deinit(testing.allocator);
    try viewer.panes.put(testing.allocator, 5, .{ .terminal = t });

    try testing.expectEqual(null, viewer.active_pane_id);
    viewer.setActivePaneId(5);
    try testing.expectEqual(5, viewer.active_pane_id);
}

test "setActivePaneId invalid pane is no-op" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    // Manually create a pane in the panes map.
    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    errdefer t.deinit(testing.allocator);
    try viewer.panes.put(testing.allocator, 5, .{ .terminal = t });

    viewer.setActivePaneId(5);
    try testing.expectEqual(5, viewer.active_pane_id);

    // Setting to an invalid pane should not change active_pane_id.
    viewer.setActivePaneId(99);
    try testing.expectEqual(5, viewer.active_pane_id);
}

test "setActivePaneId null clears" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    errdefer t.deinit(testing.allocator);
    try viewer.panes.put(testing.allocator, 5, .{ .terminal = t });

    viewer.setActivePaneId(5);
    try testing.expectEqual(5, viewer.active_pane_id);

    viewer.setActivePaneId(null);
    try testing.expectEqual(null, viewer.active_pane_id);
}

test "sendKeys basic formatting" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    // Create pane 2.
    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    errdefer t.deinit(testing.allocator);
    try viewer.panes.put(testing.allocator, 2, .{ .terminal = t });
    viewer.setActivePaneId(2);

    // "ls\r" = 0x6C 0x73 0x0D
    const result = viewer.sendKeys("ls\r");
    try testing.expect(result != null);
    try testing.expectEqualStrings("send-keys -H -t %2 6C 73 0D\n", result.?);
}

test "sendKeys single byte" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    errdefer t.deinit(testing.allocator);
    try viewer.panes.put(testing.allocator, 0, .{ .terminal = t });
    viewer.setActivePaneId(0);

    // Single byte: 'a' = 0x61
    const result = viewer.sendKeys("a");
    try testing.expect(result != null);
    try testing.expectEqualStrings("send-keys -H -t %0 61\n", result.?);
}

test "sendKeys escape sequence" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    errdefer t.deinit(testing.allocator);
    try viewer.panes.put(testing.allocator, 10, .{ .terminal = t });
    viewer.setActivePaneId(10);

    // ESC [ A (cursor up) = 0x1B 0x5B 0x41
    const result = viewer.sendKeys("\x1B[A");
    try testing.expect(result != null);
    try testing.expectEqualStrings("send-keys -H -t %10 1B 5B 41\n", result.?);
}

test "sendKeys empty data returns null" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    errdefer t.deinit(testing.allocator);
    try viewer.panes.put(testing.allocator, 0, .{ .terminal = t });
    viewer.setActivePaneId(0);

    try testing.expectEqual(null, viewer.sendKeys(""));
}

test "sendKeys no active pane returns null" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    errdefer t.deinit(testing.allocator);
    try viewer.panes.put(testing.allocator, 0, .{ .terminal = t });

    // active_pane_id is null by default.
    try testing.expectEqual(null, viewer.sendKeys("hello"));
}

test "sendKeys stale pane clears active and returns null" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    errdefer t.deinit(testing.allocator);
    try viewer.panes.put(testing.allocator, 3, .{ .terminal = t });
    viewer.setActivePaneId(3);

    // Remove the pane (simulating tmux pane removal).
    if (viewer.panes.fetchSwapRemove(3)) |entry_const| {
        var entry = entry_const;
        entry.value.deinit(testing.allocator);
    }

    // sendKeys should detect the stale pane, clear active_pane_id, return null.
    try testing.expectEqual(null, viewer.sendKeys("x"));
    try testing.expectEqual(null, viewer.active_pane_id);
}

test "sendKeys after setActivePaneId round-trip" {
    // Verify the exact sequence that the C API performs:
    // 1. Create viewer with panes (via processOutput/startup)
    // 2. setActivePaneId (via ghostty_surface_tmux_set_active_pane)
    // 3. sendKeys (via queueWrite on IO thread)
    // Both 2 and 3 should be protected by renderer_state.mutex
    // in production; this test verifies the logical correctness.
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    // Simulate viewer startup populating two panes.
    var t1: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    errdefer t1.deinit(testing.allocator);
    try viewer.panes.put(testing.allocator, 2, .{ .terminal = t1 });

    var t2: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    errdefer t2.deinit(testing.allocator);
    try viewer.panes.put(testing.allocator, 5, .{ .terminal = t2 });

    // Before activation, sendKeys returns null.
    try testing.expectEqual(null, viewer.sendKeys("a"));

    // Activate pane %5.
    viewer.setActivePaneId(5);
    try testing.expectEqual(@as(?usize, 5), viewer.active_pane_id);

    // sendKeys should now format for pane %5.
    const result = viewer.sendKeys("a");
    try testing.expect(result != null);
    try testing.expectEqualStrings("send-keys -H -t %5 61\n", result.?);

    // Switch to pane %2.
    viewer.setActivePaneId(2);
    try testing.expectEqual(@as(?usize, 2), viewer.active_pane_id);

    const result2 = viewer.sendKeys("b");
    try testing.expect(result2 != null);
    try testing.expectEqualStrings("send-keys -H -t %2 62\n", result2.?);

    // Set active to a non-existent pane — should be ignored.
    viewer.setActivePaneId(99);
    // active_pane_id should remain %2 (the setActivePaneId no-ops).
    try testing.expectEqual(@as(?usize, 2), viewer.active_pane_id);
}

test "pane terminal pointer invalidated after layout change" {
    // Regression test for use-after-free: after syncLayouts replaces
    // the panes map, any pointer into the old map's backing array is
    // dangling. Callers (e.g. renderer_state.terminal) must re-resolve
    // pointers via active_pane_id after a .windows action.
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "refresh-client",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
        // One-pane layout
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0;@0;83;44;bash;b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Drain capture-pane commands + pane_state
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
    });

    // Set active pane to %0 and capture the terminal pointer.
    viewer.setActivePaneId(0);
    const old_pane_ptr = viewer.panes.getPtr(0).?;
    const old_terminal_ptr: *const Terminal = &old_pane_ptr.terminal;

    // Now send a layout_change with the same pane (resize).
    // This triggers syncLayouts which replaces the panes map.
    try testViewer(&viewer, &.{
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "acfd,120x50,0,0,0",
                .visible_layout = "acfd,120x50,0,0,0",
                .raw_flags = "*",
            } } },
            .contains_tags = &.{.windows},
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Pane %0 should still exist.
                    try testing.expectEqual(1, v.panes.count());
                    try testing.expect(v.panes.contains(0));
                    // active_pane_id should be preserved.
                    try testing.expectEqual(@as(?usize, 0), v.active_pane_id);
                    // Pane terminal should have been resized to
                    // the new layout dimensions (120x50).
                    const pane = v.panes.getPtr(0).?;
                    try testing.expectEqual(120, pane.terminal.cols);
                    try testing.expectEqual(50, pane.terminal.rows);
                }
            }).check,
        },
    });

    // After syncLayouts, the new pane pointer may differ from the old one
    // (the backing array was reallocated). The old pointer is now dangling.
    // Anyone holding old_terminal_ptr (like renderer_state.terminal) must
    // re-resolve via active_pane_id.
    const new_pane_ptr = viewer.panes.getPtr(0).?;
    const new_terminal_ptr: *const Terminal = &new_pane_ptr.terminal;

    // The pane data is preserved (same Terminal contents) but the
    // pointer may have moved. Callers MUST NOT use old_terminal_ptr.
    _ = old_terminal_ptr;
    _ = new_terminal_ptr;
    // The active_pane_id mechanism allows safe re-resolution:
    if (viewer.active_pane_id) |id| {
        const resolved = viewer.panes.getPtr(id).?;
        try testing.expectEqual(new_pane_ptr, resolved);
    }
}

test "window name and raw layout from list-windows" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "refresh-client",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
        // list-windows output with window name "vim"
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$1;@0;83;44;vim;b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, v.windows.items.len);
                    const window = v.windows.items[0];
                    try testing.expectEqualStrings("vim", window.name);
                    try testing.expectEqualStrings("b7dd,83x44,0,0,0", window.raw_layout);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = .{ .reason = "" } } },
            .contains_tags = &.{.exit},
        },
    });
}

test "window_renamed updates name" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "refresh-client",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$1;@0;83;44;bash;b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Drain capture-pane commands + pane_state
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Now rename the window
        .{
            .input = .{ .tmux = .{ .window_renamed = .{
                .id = 0,
                .name = "vim",
            } } },
            .contains_tags = &.{.windows},
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, v.windows.items.len);
                    try testing.expectEqualStrings("vim", v.windows.items[0].name);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = .{ .reason = "" } } },
            .contains_tags = &.{.exit},
        },
    });
}

test "window_close removes window and orphaned panes" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "refresh-client",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
        // Two windows: @0 with pane 0, @1 with pane 2
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$1;@0;83;44;bash;b7dd,83x44,0,0,0
                \\$1;@1;83;44;vim;b7df,83x44,0,0,2
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(2, v.windows.items.len);
                    try testing.expectEqual(2, v.panes.count());
                    try testing.expect(v.panes.contains(0));
                    try testing.expect(v.panes.contains(2));
                }
            }).check,
        },
        // Drain capture-pane commands (4 per pane + 1 pane_state = 9)
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Close window @1, which should remove pane 2
        .{
            .input = .{ .tmux = .{ .window_close = .{ .id = 1 } } },
            .contains_tags = &.{.windows},
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, v.windows.items.len);
                    try testing.expectEqual(0, v.windows.items[0].id);
                    // Pane 0 still exists, pane 2 was pruned
                    try testing.expectEqual(1, v.panes.count());
                    try testing.expect(v.panes.contains(0));
                    try testing.expect(!v.panes.contains(2));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = .{ .reason = "" } } },
            .contains_tags = &.{.exit},
        },
    });
}

test "window_close clears active_window_id" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "refresh-client",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$1;@0;83;44;bash;b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Drain capture-pane commands + pane_state
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // Set active_window_id via session-window-changed
        .{
            .input = .{ .tmux = .{ .session_window_changed = .{
                .session_id = 1,
                .window_id = 0,
            } } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(@as(?usize, 0), v.active_window_id);
                }
            }).check,
        },
        // Close the active window
        .{
            .input = .{ .tmux = .{ .window_close = .{ .id = 0 } } },
            .contains_tags = &.{.windows},
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, v.windows.items.len);
                    // active_window_id should be cleared
                    try testing.expectEqual(@as(?usize, null), v.active_window_id);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = .{ .reason = "" } } },
            .contains_tags = &.{.exit},
        },
    });
}

test "session_window_changed sets active_window_id" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "refresh-client",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$1;@0;83;44;bash;b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Drain capture-pane commands + pane_state
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // active_window_id starts null
        .{
            .input = .{ .tmux = .{ .session_window_changed = .{
                .session_id = 1,
                .window_id = 0,
            } } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(@as(?usize, 0), v.active_window_id);
                }
            }).check,
        },
        // Switch to window @3
        .{
            .input = .{ .tmux = .{ .session_window_changed = .{
                .session_id = 1,
                .window_id = 3,
            } } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(@as(?usize, 3), v.active_window_id);
                }
            }).check,
        },
        // Different session — should be ignored
        .{
            .input = .{ .tmux = .{ .session_window_changed = .{
                .session_id = 99,
                .window_id = 7,
            } } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Should still be 3, not 7
                    try testing.expectEqual(@as(?usize, 3), v.active_window_id);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = .{ .reason = "" } } },
            .contains_tags = &.{.exit},
        },
    });
}

test "layout_change stashes raw layout" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "refresh-client",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
        // Initial layout
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$1;@0;83;44;bash;b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqualStrings(
                        "b7dd,83x44,0,0,0",
                        v.windows.items[0].raw_layout,
                    );
                }
            }).check,
        },
        // Drain capture-pane commands + pane_state
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // layout_change with a new layout — raw_layout should update
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .visible_layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .raw_flags = "*",
            } } },
            .contains_tags = &.{.windows},
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqualStrings(
                        "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                        v.windows.items[0].raw_layout,
                    );
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = .{ .reason = "" } } },
            .contains_tags = &.{.exit},
        },
    });
}

test "split OSC across output messages does not corrupt state" {
    // Verify that an OSC sequence split across two %output messages
    // doesn't corrupt the parser state or prevent subsequent output
    // from rendering. The OSC itself may be lost (acceptable), but
    // the terminal must keep processing after the split.
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Standard initialization
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 0,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "refresh-client",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0;@0;83;44;bash;b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Drain capture-pane + list-panes
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = 
        \\%0;0;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;;;0;24;
        } } },
        // First output: starts an OSC that doesn't finish
        .{
            .input = .{ .tmux = .{ .output = .{
                .pane_id = 0,
                .data = "A\x1b]0;partial-tit",
            } } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                    const screen: *Screen = pane.terminal.screens.active;
                    const str = try screen.dumpStringAlloc(
                        testing.allocator,
                        .{ .active = .{} },
                    );
                    defer testing.allocator.free(str);
                    // "A" should be printed before the OSC started
                    try testing.expect(std.mem.startsWith(u8, str, "A"));
                }
            }).check,
        },
        // Second output: finishes the OSC and prints more text
        .{
            .input = .{ .tmux = .{ .output = .{
                .pane_id = 0,
                .data = "le\x07HELLO",
            } } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                    const screen: *Screen = pane.terminal.screens.active;
                    const str = try screen.dumpStringAlloc(
                        testing.allocator,
                        .{ .active = .{} },
                    );
                    defer testing.allocator.free(str);
                    // "HELLO" must appear — the parser must not be stuck
                    try testing.expect(std.mem.containsAtLeast(u8, str, 1, "HELLO"));
                }
            }).check,
        },
        // Third output: more text to verify parser is still working
        .{
            .input = .{ .tmux = .{ .output = .{
                .pane_id = 0,
                .data = "\r\nWORLD",
            } } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                    const screen: *Screen = pane.terminal.screens.active;
                    const str = try screen.dumpStringAlloc(
                        testing.allocator,
                        .{ .active = .{} },
                    );
                    defer testing.allocator.free(str);
                    try testing.expect(std.mem.containsAtLeast(u8, str, 1, "WORLD"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = .{ .reason = "" } } },
            .contains_tags = &.{.exit},
        },
    });
}

test "multiple output rounds with OSC sequences keep rendering" {
    // Regression test for display freeze: after the first command response
    // the terminal stopped visually updating. This test simulates the
    // pattern: prompt → command output → new prompt, verifying text
    // from each phase appears on screen.
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Standard initialization
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 0,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "refresh-client",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0;@0;83;44;bash;b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Drain capture-pane + list-panes
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = 
        \\%0;0;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;;;0;24;
        } } },
        // First output: initial prompt with OSC title + semantic prompt
        .{
            .input = .{ .tmux = .{ .output = .{
                .pane_id = 0,
                .data = "\x1b]0;user@host:~\x07\x1b]133;A\x07$ ",
            } } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                    const screen: *Screen = pane.terminal.screens.active;
                    const str = try screen.dumpStringAlloc(
                        testing.allocator,
                        .{ .active = .{} },
                    );
                    defer testing.allocator.free(str);
                    // "$ " should appear (the prompt text)
                    try testing.expect(std.mem.containsAtLeast(u8, str, 1, "$ "));
                }
            }).check,
        },
        // Second output: command echo + result
        .{
            .input = .{ .tmux = .{ .output = .{
                .pane_id = 0,
                .data = "ls\r\nfile1  file2  file3\r\n",
            } } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                    const screen: *Screen = pane.terminal.screens.active;
                    const str = try screen.dumpStringAlloc(
                        testing.allocator,
                        .{ .active = .{} },
                    );
                    defer testing.allocator.free(str);
                    try testing.expect(std.mem.containsAtLeast(u8, str, 1, "file1"));
                }
            }).check,
        },
        // Third output: new prompt (this is where the freeze happened)
        .{
            .input = .{ .tmux = .{ .output = .{
                .pane_id = 0,
                .data = "\x1b]133;D;0\x07\x1b]0;user@host:~\x07\x1b]133;A\x07$ ",
            } } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                    const screen: *Screen = pane.terminal.screens.active;
                    const str = try screen.dumpStringAlloc(
                        testing.allocator,
                        .{ .active = .{} },
                    );
                    defer testing.allocator.free(str);
                    // The second "$ " prompt must appear after the command output.
                    // Count occurrences — we should have at least 2 prompts.
                    var count: usize = 0;
                    var pos: usize = 0;
                    while (std.mem.indexOfPos(u8, str, pos, "$ ")) |idx| {
                        count += 1;
                        pos = idx + 2;
                    }
                    try testing.expect(count >= 2);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = .{ .reason = "" } } },
            .contains_tags = &.{.exit},
        },
    });
}

test "DCS tmux passthrough does not trap parser across messages" {
    // Regression test for the display freeze root cause: shells wrap
    // sequences like OSC 7 (CWD) in DCS tmux passthrough:
    //   \x1bPtmux;\x1b\x1b]7;file://host/path\x07\x1b\\
    // The 7-bit ST terminator (\x1b\\) cannot exit dcs_passthrough
    // because ESC is overridden to `put` in our parse_table (needed
    // for tmux control mode's UTF-8 support). Without the absorbing-
    // state reset in receivedOutput(), the parser stays trapped in
    // dcs_passthrough and ALL subsequent text is silently consumed.
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Standard initialization
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 0,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "refresh-client",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0;@0;83;44;bash;b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Drain capture-pane + list-panes
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = 
        \\%0;0;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;;;0;24;
        } } },
        // First output: DCS tmux passthrough wrapping OSC 7 (CWD report)
        // This is the exact pattern zsh emits on every prompt.
        // \x1bP = DCS entry, tmux; = DCS param, then inner content,
        // \x1b\\ = 7-bit ST (which CANNOT exit dcs_passthrough).
        .{
            .input = .{ .tmux = .{ .output = .{
                .pane_id = 0,
                .data = "\x1bPtmux;\x1b\x1b]7;file://%2Fhome%2Fuser\x07\x1b\\",
            } } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // After this message the parser MUST be back in ground
                    // state (thanks to the absorbing-state reset). Without
                    // the fix it would be stuck in dcs_passthrough.
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                    try testing.expectEqual(
                        @as(@TypeOf(pane.vt_parser.state), .ground),
                        pane.vt_parser.state,
                    );
                }
            }).check,
        },
        // Second output: regular text. Without the fix this would be
        // swallowed by dcs_passthrough's `put` action → invisible.
        .{
            .input = .{ .tmux = .{ .output = .{
                .pane_id = 0,
                .data = "HELLO",
            } } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                    const screen: *Screen = pane.terminal.screens.active;
                    const str = try screen.dumpStringAlloc(
                        testing.allocator,
                        .{ .active = .{} },
                    );
                    defer testing.allocator.free(str);
                    // "HELLO" MUST be visible on screen
                    try testing.expect(std.mem.containsAtLeast(u8, str, 1, "HELLO"));
                }
            }).check,
        },
        // Third output: another DCS passthrough (second prompt cycle).
        // In real wire captures, the DCS and the subsequent prompt
        // arrive in separate %output messages (lines 106 vs 107).
        .{
            .input = .{ .tmux = .{ .output = .{
                .pane_id = 0,
                .data = "\x1bPtmux;\x1b\x1b]7;file://%2Fhome%2Fuser\x07\x1b\\",
            } } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Parser must be back in ground after the reset
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                    try testing.expectEqual(
                        @as(@TypeOf(pane.vt_parser.state), .ground),
                        pane.vt_parser.state,
                    );
                }
            }).check,
        },
        // Fourth output: the prompt text that follows the DCS.
        // Without the absorbing-state reset this would be invisible.
        .{
            .input = .{ .tmux = .{ .output = .{
                .pane_id = 0,
                .data = "\r\nuser@host:~ $ ",
            } } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                    const screen: *Screen = pane.terminal.screens.active;
                    const str = try screen.dumpStringAlloc(
                        testing.allocator,
                        .{ .active = .{} },
                    );
                    defer testing.allocator.free(str);
                    // Prompt text must be visible on screen
                    try testing.expect(std.mem.containsAtLeast(u8, str, 1, "user@host"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = .{ .reason = "" } } },
            .contains_tags = &.{.exit},
        },
    });
}

test "split CSI across output messages persists parser state" {
    // Regression test: receivedOutput() used to create a fresh VT parser
    // on every %output message. When tmux splits a CSI sequence across
    // two messages (e.g., ESC[32 | mX), the second message's leading 'm'
    // was printed as literal text instead of completing the SGR sequence.
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Standard initialization: block_end, session_changed, version, list-windows
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 0,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "refresh-client",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
        // Single pane layout (83x44, pane 0)
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0;@0;83;44;bash;b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Drain capture-pane commands (primary history, primary visible,
        // alternate history, alternate visible) + list-panes
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = 
        \\%0;0;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;;;0;24;
        } } },
        // First %output: ESC[32  (incomplete CSI — sequence continues in next message)
        .{
            .input = .{ .tmux = .{ .output = .{ .pane_id = 0, .data = "\x1b[32" } } },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                }
            }).check,
        },
        // Second %output: mX  (completes ESC[32m = SGR green, then prints 'X')
        .{
            .input = .{ .tmux = .{ .output = .{ .pane_id = 0, .data = "mX" } } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                    const screen: *Screen = pane.terminal.screens.active;
                    // The cell at (0,0) should contain 'X'
                    const str = try screen.dumpStringAlloc(
                        testing.allocator,
                        .{ .active = .{} },
                    );
                    defer testing.allocator.free(str);
                    try testing.expect(std.mem.startsWith(u8, str, "X"));
                    // Verify 'X' has green foreground (SGR 32 = palette index 2)
                    // and NOT that 'm' appears as literal text
                    const list_cell = screen.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
                    const cell_style = list_cell.style();
                    try testing.expectEqual(
                        @as(@TypeOf(cell_style.fg_color), .{ .palette = 2 }),
                        cell_style.fg_color,
                    );
                    // The literal 'm' should NOT be on screen — it was consumed
                    // by the parser as the CSI terminator, not printed.
                    try testing.expect(!std.mem.startsWith(u8, str, "m"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = .{ .reason = "" } } },
            .contains_tags = &.{.exit},
        },
    });
}

test "UTF-8 box-drawing codepoints in %output reach terminal grid correctly" {
    // End-to-end test for the U+FFFD investigation: feed raw UTF-8
    // box-drawing characters through %output and verify the terminal
    // grid contains the correct Unicode codepoints, not U+FFFD (0xFFFD).
    //
    // Characters under test:
    //   ┄ U+2504 (0xE2 0x94 0x84) - box drawings light triple dash horizontal
    //   • U+2022 (0xE2 0x80 0xA2) - bullet
    //   ━ U+2501 (0xE2 0x94 0x81) - box drawings heavy horizontal
    //   ═ U+2550 (0xE2 0x95 0x90) - box drawings double horizontal
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Standard initialization
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 0,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "refresh-client",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0;@0;83;44;bash;b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Drain capture-pane + list-panes
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = 
        \\%0;0;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;;;0;24;
        } } },
        // Send %output with raw UTF-8 box-drawing characters
        .{
            .input = .{
                .tmux = .{
                    .output = .{
                        .pane_id = 0,
                        // Raw UTF-8: ┄•━═
                        .data = "\xe2\x94\x84\xe2\x80\xa2\xe2\x94\x81\xe2\x95\x90",
                    },
                },
            },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                    const screen: *Screen = pane.terminal.screens.active;
                    // Verify via dumpStringAlloc that the UTF-8 chars appear
                    const str = try screen.dumpStringAlloc(
                        testing.allocator,
                        .{ .active = .{} },
                    );
                    defer testing.allocator.free(str);
                    // The dump should contain the raw UTF-8 for our characters
                    try testing.expect(std.mem.startsWith(
                        u8,
                        str,
                        "\xe2\x94\x84\xe2\x80\xa2\xe2\x94\x81\xe2\x95\x90",
                    ));
                    // Also verify at the cell level — each character should be
                    // at its own grid position with the correct codepoint.
                    const cell0 = screen.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
                    const cell1 = screen.pages.getCell(.{ .active = .{ .x = 1, .y = 0 } }).?;
                    const cell2 = screen.pages.getCell(.{ .active = .{ .x = 2, .y = 0 } }).?;
                    const cell3 = screen.pages.getCell(.{ .active = .{ .x = 3, .y = 0 } }).?;
                    // ┄ U+2504
                    try testing.expectEqual(@as(u21, 0x2504), cell0.cell.codepoint());
                    // • U+2022
                    try testing.expectEqual(@as(u21, 0x2022), cell1.cell.codepoint());
                    // ━ U+2501
                    try testing.expectEqual(@as(u21, 0x2501), cell2.cell.codepoint());
                    // ═ U+2550
                    try testing.expectEqual(@as(u21, 0x2550), cell3.cell.codepoint());
                    // None should be U+FFFD (replacement character)
                    try testing.expect(cell0.cell.codepoint() != 0xFFFD);
                    try testing.expect(cell1.cell.codepoint() != 0xFFFD);
                    try testing.expect(cell2.cell.codepoint() != 0xFFFD);
                    try testing.expect(cell3.cell.codepoint() != 0xFFFD);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = .{ .reason = "" } } },
            .contains_tags = &.{.exit},
        },
    });
}

test "UTF-8 box-drawing split across %output messages" {
    // Test that UTF-8 multi-byte sequences split across two %output messages
    // are correctly reassembled by the persistent UTF8Decoder, producing
    // the correct codepoint instead of U+FFFD.
    //
    // ┄ U+2504 = 0xE2 0x94 0x84 — we split after the first byte.
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Standard initialization
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 0,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "refresh-client",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0;@0;83;44;bash;b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Drain capture-pane + list-panes
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = 
        \\%0;0;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;;;0;24;
        } } },
        // First %output: "A" + first byte of ┄ (0xE2)
        .{
            .input = .{ .tmux = .{ .output = .{
                .pane_id = 0,
                .data = "A\xe2",
            } } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                    const screen: *Screen = pane.terminal.screens.active;
                    const str = try screen.dumpStringAlloc(
                        testing.allocator,
                        .{ .active = .{} },
                    );
                    defer testing.allocator.free(str);
                    // "A" should appear; the incomplete byte is buffered
                    try testing.expect(std.mem.startsWith(u8, str, "A"));
                }
            }).check,
        },
        // Second %output: remaining bytes of ┄ (0x94 0x84) + "B"
        .{
            .input = .{ .tmux = .{ .output = .{
                .pane_id = 0,
                .data = "\x94\x84B",
            } } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                    const screen: *Screen = pane.terminal.screens.active;
                    // Cell 0 = 'A' (0x41)
                    const cell0 = screen.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
                    try testing.expectEqual(@as(u21, 'A'), cell0.cell.codepoint());
                    // Cell 1 = ┄ U+2504 (reassembled from split bytes)
                    const cell1 = screen.pages.getCell(.{ .active = .{ .x = 1, .y = 0 } }).?;
                    try testing.expectEqual(@as(u21, 0x2504), cell1.cell.codepoint());
                    try testing.expect(cell1.cell.codepoint() != 0xFFFD);
                    // Cell 2 = 'B' (0x42)
                    const cell2 = screen.pages.getCell(.{ .active = .{ .x = 2, .y = 0 } }).?;
                    try testing.expectEqual(@as(u21, 'B'), cell2.cell.codepoint());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = .{ .reason = "" } } },
            .contains_tags = &.{.exit},
        },
    });
}

test "ACS charset (ESC(0) followed by UTF-8 box-drawing produces spaces not U+FFFD" {
    // When G0 is configured as DEC Special Graphics via ESC(0, multi-byte
    // UTF-8 codepoints (> 255) are mapped to space by Terminal.printCell()
    // (line 622: unmapped_c > maxInt(u8) => ' '). This test confirms that
    // ACS mode does NOT produce U+FFFD — it produces spaces. This helps
    // rule out (or confirm) ACS leakage as the cause of U+FFFD rendering.
    //
    // Sequence: ESC(0 (G0=dec_special), then ┄ (U+2504 raw UTF-8),
    // then ESC(B (G0=ascii), then ━ (U+2501 raw UTF-8).
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Standard initialization
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 0,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "refresh-client",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0;@0;83;44;bash;b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Drain capture-pane + list-panes
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = 
        \\%0;0;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;;;0;24;
        } } },
        // Send ESC(0 (G0=dec_special) + ┄ U+2504 + ESC(B (G0=ascii) + ━ U+2501
        .{
            .input = .{
                .tmux = .{
                    .output = .{
                        .pane_id = 0,
                        // ESC(0 = 0x1B 0x28 0x30
                        // ┄ U+2504 = 0xE2 0x94 0x84
                        // ESC(B = 0x1B 0x28 0x42
                        // ━ U+2501 = 0xE2 0x94 0x81
                        .data = "\x1b\x28\x30" ++ "\xe2\x94\x84" ++ "\x1b\x28\x42" ++ "\xe2\x94\x81",
                    },
                },
            },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                    const screen: *Screen = pane.terminal.screens.active;
                    // Cell 0: ┄ was printed while G0=dec_special.
                    // Since U+2504 > 255, Terminal.printCell maps it to space.
                    const cell0 = screen.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
                    try testing.expectEqual(@as(u21, ' '), cell0.cell.codepoint());
                    // Crucially: it should NOT be U+FFFD
                    try testing.expect(cell0.cell.codepoint() != 0xFFFD);
                    // Cell 1: ━ was printed after ESC(B restored G0=ascii.
                    // U+2501 should pass through unmapped.
                    const cell1 = screen.pages.getCell(.{ .active = .{ .x = 1, .y = 0 } }).?;
                    try testing.expectEqual(@as(u21, 0x2501), cell1.cell.codepoint());
                    try testing.expect(cell1.cell.codepoint() != 0xFFFD);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = .{ .reason = "" } } },
            .contains_tags = &.{.exit},
        },
    });
}

test "4-byte emoji codepoints in %output reach terminal grid correctly" {
    // UTF-8 integrity fence: 4-byte emoji sequences must produce the correct
    // Unicode codepoints in the terminal grid, not U+FFFD.
    //
    // Characters under test:
    //   😀 U+1F600 (0xF0 0x9F 0x98 0x80) - grinning face
    //   🎉 U+1F389 (0xF0 0x9F 0x8E 0x89) - party popper
    //   🚀 U+1F680 (0xF0 0x9F 0x9A 0x80) - rocket
    //
    // Note: These emoji are typically rendered as wide (2-cell) characters.
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Standard initialization
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 0,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "refresh-client",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0;@0;83;44;bash;b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Drain capture-pane + list-panes
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = 
        \\%0;0;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;;;0;24;
        } } },
        // Send %output with 4-byte emoji
        .{
            .input = .{
                .tmux = .{
                    .output = .{
                        .pane_id = 0,
                        // Raw UTF-8: 😀🎉🚀
                        .data = "\xf0\x9f\x98\x80\xf0\x9f\x8e\x89\xf0\x9f\x9a\x80",
                    },
                },
            },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                    const screen: *Screen = pane.terminal.screens.active;
                    // Each emoji is wide (2 cells): emoji at x=0, spacer_tail at x=1, etc.
                    // 😀 U+1F600 at x=0
                    const cell0 = screen.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
                    try testing.expectEqual(@as(u21, 0x1F600), cell0.cell.codepoint());
                    try testing.expect(cell0.cell.wide == .wide);
                    // Spacer tail at x=1
                    const cell1 = screen.pages.getCell(.{ .active = .{ .x = 1, .y = 0 } }).?;
                    try testing.expect(cell1.cell.wide == .spacer_tail);
                    // 🎉 U+1F389 at x=2
                    const cell2 = screen.pages.getCell(.{ .active = .{ .x = 2, .y = 0 } }).?;
                    try testing.expectEqual(@as(u21, 0x1F389), cell2.cell.codepoint());
                    try testing.expect(cell2.cell.wide == .wide);
                    // 🚀 U+1F680 at x=4
                    const cell4 = screen.pages.getCell(.{ .active = .{ .x = 4, .y = 0 } }).?;
                    try testing.expectEqual(@as(u21, 0x1F680), cell4.cell.codepoint());
                    try testing.expect(cell4.cell.wide == .wide);
                    // None should be U+FFFD
                    try testing.expect(cell0.cell.codepoint() != 0xFFFD);
                    try testing.expect(cell2.cell.codepoint() != 0xFFFD);
                    try testing.expect(cell4.cell.codepoint() != 0xFFFD);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = .{ .reason = "" } } },
            .contains_tags = &.{.exit},
        },
    });
}

test "CJK double-width characters in %output produce wide cells" {
    // UTF-8 integrity fence: CJK ideographs are 3-byte UTF-8 sequences that
    // render as double-width (2-cell) characters in terminal grids.
    //
    // Characters under test:
    //   中 U+4E2D (0xE4 0xB8 0xAD) - CJK ideograph "middle"
    //   文 U+6587 (0xE6 0x96 0x87) - CJK ideograph "writing"
    //   字 U+5B57 (0xE5 0xAD 0x97) - CJK ideograph "character"
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Standard initialization
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 0,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "refresh-client",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0;@0;83;44;bash;b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Drain capture-pane + list-panes
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = 
        \\%0;0;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;;;0;24;
        } } },
        // Send %output with CJK characters
        .{
            .input = .{
                .tmux = .{
                    .output = .{
                        .pane_id = 0,
                        // Raw UTF-8: 中文字
                        .data = "\xe4\xb8\xad\xe6\x96\x87\xe5\xad\x97",
                    },
                },
            },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                    const screen: *Screen = pane.terminal.screens.active;
                    // 中 U+4E2D at x=0, wide
                    const cell0 = screen.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
                    try testing.expectEqual(@as(u21, 0x4E2D), cell0.cell.codepoint());
                    try testing.expect(cell0.cell.wide == .wide);
                    // Spacer tail at x=1
                    const cell1 = screen.pages.getCell(.{ .active = .{ .x = 1, .y = 0 } }).?;
                    try testing.expect(cell1.cell.wide == .spacer_tail);
                    // 文 U+6587 at x=2, wide
                    const cell2 = screen.pages.getCell(.{ .active = .{ .x = 2, .y = 0 } }).?;
                    try testing.expectEqual(@as(u21, 0x6587), cell2.cell.codepoint());
                    try testing.expect(cell2.cell.wide == .wide);
                    // 字 U+5B57 at x=4, wide
                    const cell4 = screen.pages.getCell(.{ .active = .{ .x = 4, .y = 0 } }).?;
                    try testing.expectEqual(@as(u21, 0x5B57), cell4.cell.codepoint());
                    try testing.expect(cell4.cell.wide == .wide);
                    // None should be U+FFFD
                    try testing.expect(cell0.cell.codepoint() != 0xFFFD);
                    try testing.expect(cell2.cell.codepoint() != 0xFFFD);
                    try testing.expect(cell4.cell.codepoint() != 0xFFFD);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = .{ .reason = "" } } },
            .contains_tags = &.{.exit},
        },
    });
}

test "braille pattern codepoints in %output reach terminal grid correctly" {
    // UTF-8 integrity fence: Braille patterns are 3-byte UTF-8 sequences in
    // the U+2800-U+28FF range, rendered as narrow (1-cell) characters.
    //
    // Characters under test:
    //   ⠿ U+283F (0xE2 0xA0 0xBF) - braille pattern dots-123456
    //   ⣿ U+28FF (0xE2 0xA3 0xBF) - braille pattern dots-12345678
    //   ⠁ U+2801 (0xE2 0xA0 0x81) - braille pattern dots-1
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Standard initialization
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 0,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "refresh-client",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0;@0;83;44;bash;b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Drain capture-pane + list-panes
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = 
        \\%0;0;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;;;0;24;
        } } },
        // Send %output with braille patterns
        .{
            .input = .{
                .tmux = .{
                    .output = .{
                        .pane_id = 0,
                        // Raw UTF-8: ⠿⣿⠁
                        .data = "\xe2\xa0\xbf\xe2\xa3\xbf\xe2\xa0\x81",
                    },
                },
            },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                    const screen: *Screen = pane.terminal.screens.active;
                    // Braille characters are narrow (1-cell wide)
                    // ⠿ U+283F at x=0
                    const cell0 = screen.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
                    try testing.expectEqual(@as(u21, 0x283F), cell0.cell.codepoint());
                    try testing.expect(cell0.cell.wide == .narrow);
                    // ⣿ U+28FF at x=1
                    const cell1 = screen.pages.getCell(.{ .active = .{ .x = 1, .y = 0 } }).?;
                    try testing.expectEqual(@as(u21, 0x28FF), cell1.cell.codepoint());
                    try testing.expect(cell1.cell.wide == .narrow);
                    // ⠁ U+2801 at x=2
                    const cell2 = screen.pages.getCell(.{ .active = .{ .x = 2, .y = 0 } }).?;
                    try testing.expectEqual(@as(u21, 0x2801), cell2.cell.codepoint());
                    try testing.expect(cell2.cell.wide == .narrow);
                    // None should be U+FFFD
                    try testing.expect(cell0.cell.codepoint() != 0xFFFD);
                    try testing.expect(cell1.cell.codepoint() != 0xFFFD);
                    try testing.expect(cell2.cell.codepoint() != 0xFFFD);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = .{ .reason = "" } } },
            .contains_tags = &.{.exit},
        },
    });
}

test "4-byte emoji split across %output messages" {
    // UTF-8 integrity fence: A 4-byte emoji split across two %output messages
    // must be correctly reassembled by the persistent UTF8Decoder.
    //
    // 🚀 U+1F680 = 0xF0 0x9F 0x9A 0x80 — we split after the first two bytes.
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Standard initialization
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 0,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "refresh-client",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0;@0;83;44;bash;b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Drain capture-pane + list-panes
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = 
        \\%0;0;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;;;0;24;
        } } },
        // First %output: "A" + first two bytes of 🚀 (0xF0 0x9F)
        .{
            .input = .{ .tmux = .{ .output = .{
                .pane_id = 0,
                .data = "A\xf0\x9f",
            } } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                    const screen: *Screen = pane.terminal.screens.active;
                    // "A" should appear; the incomplete bytes are buffered
                    const cell0 = screen.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
                    try testing.expectEqual(@as(u21, 'A'), cell0.cell.codepoint());
                }
            }).check,
        },
        // Second %output: remaining bytes of 🚀 (0x9A 0x80) + "B"
        .{
            .input = .{ .tmux = .{ .output = .{
                .pane_id = 0,
                .data = "\x9a\x80B",
            } } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                    const screen: *Screen = pane.terminal.screens.active;
                    // Cell 0 = 'A' (0x41)
                    const cell0 = screen.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
                    try testing.expectEqual(@as(u21, 'A'), cell0.cell.codepoint());
                    // Cell 1 = 🚀 U+1F680 (reassembled from split bytes), wide
                    const cell1 = screen.pages.getCell(.{ .active = .{ .x = 1, .y = 0 } }).?;
                    try testing.expectEqual(@as(u21, 0x1F680), cell1.cell.codepoint());
                    try testing.expect(cell1.cell.wide == .wide);
                    try testing.expect(cell1.cell.codepoint() != 0xFFFD);
                    // Spacer tail at x=2
                    const cell2 = screen.pages.getCell(.{ .active = .{ .x = 2, .y = 0 } }).?;
                    try testing.expect(cell2.cell.wide == .spacer_tail);
                    // Cell 3 = 'B' (0x42)
                    const cell3 = screen.pages.getCell(.{ .active = .{ .x = 3, .y = 0 } }).?;
                    try testing.expectEqual(@as(u21, 'B'), cell3.cell.codepoint());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = .{ .reason = "" } } },
            .contains_tags = &.{.exit},
        },
    });
}

test "mixed CJK and ASCII in %output with correct cell positions" {
    // UTF-8 integrity fence: Mixed narrow ASCII and wide CJK characters must
    // produce correct codepoints at correct grid positions, accounting for
    // the fact that wide chars occupy 2 cells each.
    //
    // Input: "A中B文C" — expected layout:
    //   x=0: 'A' (narrow)
    //   x=1: 中 (wide), x=2: spacer_tail
    //   x=3: 'B' (narrow)
    //   x=4: 文 (wide), x=5: spacer_tail
    //   x=6: 'C' (narrow)
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Standard initialization
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 0,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "refresh-client",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0;@0;83;44;bash;b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Drain capture-pane + list-panes
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = 
        \\%0;0;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;;;0;24;
        } } },
        // Send %output with mixed ASCII and CJK
        .{
            .input = .{
                .tmux = .{
                    .output = .{
                        .pane_id = 0,
                        // "A" + 中 + "B" + 文 + "C"
                        .data = "A\xe4\xb8\xadB\xe6\x96\x87C",
                    },
                },
            },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(0).?.value_ptr;
                    const screen: *Screen = pane.terminal.screens.active;
                    // x=0: 'A' narrow
                    const cell0 = screen.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
                    try testing.expectEqual(@as(u21, 'A'), cell0.cell.codepoint());
                    try testing.expect(cell0.cell.wide == .narrow);
                    // x=1: 中 U+4E2D wide
                    const cell1 = screen.pages.getCell(.{ .active = .{ .x = 1, .y = 0 } }).?;
                    try testing.expectEqual(@as(u21, 0x4E2D), cell1.cell.codepoint());
                    try testing.expect(cell1.cell.wide == .wide);
                    // x=2: spacer_tail
                    const cell2 = screen.pages.getCell(.{ .active = .{ .x = 2, .y = 0 } }).?;
                    try testing.expect(cell2.cell.wide == .spacer_tail);
                    // x=3: 'B' narrow
                    const cell3 = screen.pages.getCell(.{ .active = .{ .x = 3, .y = 0 } }).?;
                    try testing.expectEqual(@as(u21, 'B'), cell3.cell.codepoint());
                    try testing.expect(cell3.cell.wide == .narrow);
                    // x=4: 文 U+6587 wide
                    const cell4 = screen.pages.getCell(.{ .active = .{ .x = 4, .y = 0 } }).?;
                    try testing.expectEqual(@as(u21, 0x6587), cell4.cell.codepoint());
                    try testing.expect(cell4.cell.wide == .wide);
                    // x=5: spacer_tail
                    const cell5 = screen.pages.getCell(.{ .active = .{ .x = 5, .y = 0 } }).?;
                    try testing.expect(cell5.cell.wide == .spacer_tail);
                    // x=6: 'C' narrow
                    const cell6 = screen.pages.getCell(.{ .active = .{ .x = 6, .y = 0 } }).?;
                    try testing.expectEqual(@as(u21, 'C'), cell6.cell.codepoint());
                    try testing.expect(cell6.cell.wide == .narrow);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = .{ .reason = "" } } },
            .contains_tags = &.{.exit},
        },
    });
}

test "flow control: enable_flow_control in init sequence" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            // First command: tmux_version (display-message)
            .contains_command = "display-message",
        },
        // Version response triggers enable_flow_control (refresh-client -f)
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "refresh-client -f wait-exit,pause-after=",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
    });
}

// --- TmuxVersion parsing tests ---

test "TmuxVersion: parse standard version" {
    const v = Viewer.TmuxVersion.parse("3.5a").?;
    try testing.expectEqual(@as(u16, 3), v.major);
    try testing.expectEqual(@as(u16, 5), v.minor);
    try testing.expectEqual(@as(u8, 'a'), v.suffix);
}

test "TmuxVersion: parse version without suffix" {
    const v = Viewer.TmuxVersion.parse("3.2").?;
    try testing.expectEqual(@as(u16, 3), v.major);
    try testing.expectEqual(@as(u16, 2), v.minor);
    try testing.expectEqual(@as(u8, 0), v.suffix);
}

test "TmuxVersion: parse next- prefix" {
    const v = Viewer.TmuxVersion.parse("next-3.5").?;
    try testing.expectEqual(@as(u16, 3), v.major);
    try testing.expectEqual(@as(u16, 5), v.minor);
    try testing.expectEqual(@as(u8, 0), v.suffix);
}

test "TmuxVersion: parse older version without suffix" {
    const v = Viewer.TmuxVersion.parse("2.9").?;
    try testing.expectEqual(@as(u16, 2), v.major);
    try testing.expectEqual(@as(u16, 9), v.minor);
    try testing.expectEqual(@as(u8, 0), v.suffix);
}

test "TmuxVersion: parse rejects empty string" {
    try testing.expect(Viewer.TmuxVersion.parse("") == null);
}

test "TmuxVersion: parse rejects no dot" {
    try testing.expect(Viewer.TmuxVersion.parse("35a") == null);
}

test "TmuxVersion: parse rejects trailing garbage" {
    try testing.expect(Viewer.TmuxVersion.parse("3.5ab") == null);
}

test "TmuxVersion: parse rejects dot only" {
    try testing.expect(Viewer.TmuxVersion.parse(".") == null);
}

test "TmuxVersion: parse rejects leading dot" {
    try testing.expect(Viewer.TmuxVersion.parse(".5") == null);
}

test "TmuxVersion: parse rejects trailing dot" {
    try testing.expect(Viewer.TmuxVersion.parse("3.") == null);
}

test "TmuxVersion: order equal versions" {
    const a = Viewer.TmuxVersion{ .major = 3, .minor = 2, .suffix = 0 };
    const b = Viewer.TmuxVersion{ .major = 3, .minor = 2, .suffix = 0 };
    try testing.expectEqual(std.math.Order.eq, a.order(b));
}

test "TmuxVersion: order major difference" {
    const a = Viewer.TmuxVersion{ .major = 2, .minor = 9, .suffix = 0 };
    const b = Viewer.TmuxVersion{ .major = 3, .minor = 0, .suffix = 0 };
    try testing.expectEqual(std.math.Order.lt, a.order(b));
    try testing.expectEqual(std.math.Order.gt, b.order(a));
}

test "TmuxVersion: order minor difference" {
    const a = Viewer.TmuxVersion{ .major = 3, .minor = 1, .suffix = 0 };
    const b = Viewer.TmuxVersion{ .major = 3, .minor = 2, .suffix = 0 };
    try testing.expectEqual(std.math.Order.lt, a.order(b));
}

test "TmuxVersion: order suffix difference" {
    const a = Viewer.TmuxVersion{ .major = 3, .minor = 5, .suffix = 0 };
    const b = Viewer.TmuxVersion{ .major = 3, .minor = 5, .suffix = 'a' };
    try testing.expectEqual(std.math.Order.lt, a.order(b));
    try testing.expectEqual(std.math.Order.gt, b.order(a));
}

test "TmuxVersion: atLeast true for equal version" {
    const v = Viewer.TmuxVersion{ .major = 3, .minor = 2, .suffix = 0 };
    try testing.expect(v.atLeast(Viewer.TmuxVersion.flow_control));
}

test "TmuxVersion: atLeast true for newer version" {
    const v = Viewer.TmuxVersion{ .major = 3, .minor = 5, .suffix = 'a' };
    try testing.expect(v.atLeast(Viewer.TmuxVersion.flow_control));
}

test "TmuxVersion: atLeast false for older version" {
    const v = Viewer.TmuxVersion{ .major = 3, .minor = 1, .suffix = 0 };
    try testing.expect(!v.atLeast(Viewer.TmuxVersion.flow_control));
}

test "TmuxVersion: atLeast false for much older version" {
    const v = Viewer.TmuxVersion{ .major = 2, .minor = 9, .suffix = 0 };
    try testing.expect(!v.atLeast(Viewer.TmuxVersion.flow_control));
}

// --- Version gating behavior tests ---

test "version gating: old tmux skips enable_flow_control" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            // First command: tmux_version (display-message)
            .contains_command = "display-message",
        },
        // Report version 2.9 — too old for flow control.
        // enable_flow_control should be skipped, list-windows sent directly.
        .{
            .input = .{ .tmux = .{ .block_end = "2.9" } },
            .contains_command = "list-windows",
        },
    });

    // Verify the parsed version was stored.
    const pv = viewer.parsed_version.?;
    try testing.expectEqual(@as(u16, 2), pv.major);
    try testing.expectEqual(@as(u16, 9), pv.minor);
}

test "version gating: new tmux sends enable_flow_control" {
    // This is essentially the same as the existing
    // "flow control: enable_flow_control in init sequence" test,
    // but explicitly verifies version gating allows it through.
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        // Report version 3.5a — flow control supported.
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "refresh-client -f wait-exit,pause-after=",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
    });

    const pv = viewer.parsed_version.?;
    try testing.expectEqual(@as(u16, 3), pv.major);
    try testing.expectEqual(@as(u16, 5), pv.minor);
    try testing.expectEqual(@as(u8, 'a'), pv.suffix);
}

test "version gating: exactly 3.2 enables flow control" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        // Exactly 3.2 — should enable flow control.
        .{
            .input = .{ .tmux = .{ .block_end = "3.2" } },
            .contains_command = "refresh-client -f wait-exit,pause-after=",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
    });
}

test "version gating: 3.1 skips flow control" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        // Version 3.1 — just below flow control threshold.
        .{
            .input = .{ .tmux = .{ .block_end = "3.1" } },
            .contains_command = "list-windows",
        },
    });
}

test "version gating: next- prefix parsed correctly" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        // Dev build: next-3.5 should enable flow control.
        .{
            .input = .{ .tmux = .{ .block_end = "next-3.5" } },
            .contains_command = "refresh-client -f wait-exit,pause-after=",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
    });
}

test "version gating: unparseable version skips flow control" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        // Garbage version string — parsed_version is null, skip flow control.
        .{
            .input = .{ .tmux = .{ .block_end = "banana" } },
            .contains_command = "list-windows",
        },
    });

    try testing.expect(viewer.parsed_version == null);
}

test "flow control: pause sets pane paused and sends continue" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "refresh-client",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
        // Single pane layout (pane 5, checksum b7e2 for "83x44,0,0,5")
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0;@0;83;44;bash;b7e2,83x44,0,0,5
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete capture-pane + pane_state
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .expect_ready = true,
        },
        // Now send %pause for pane 5
        .{
            .input = .{ .tmux = .{ .pause = .{ .pane_id = 5 } } },
            // Should set pause_continue_pane_id for the caller to handle
            .expect_pause_continue_pane = 5,
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane = v.panes.getEntry(5).?.value_ptr;
                    try testing.expect(pane.paused);
                }
            }).check,
        },
    });
}

test "flow control: continue clears pane paused state" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "refresh-client",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
        // Single pane layout (pane 5, checksum b7e2 for "83x44,0,0,5")
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0;@0;83;44;bash;b7e2,83x44,0,0,5
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete capture-pane + pane_state
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .expect_ready = true,
        },
        // Pause pane 5
        .{
            .input = .{ .tmux = .{ .pause = .{ .pane_id = 5 } } },
            .expect_pause_continue_pane = 5,
        },
        // Continue pane 5
        .{
            .input = .{ .tmux = .{ .continue_pane = .{ .pane_id = 5 } } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane = v.panes.getEntry(5).?.value_ptr;
                    try testing.expect(!pane.paused);
                }
            }).check,
        },
    });
}

test "flow control: extended output feeds terminal" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "refresh-client",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
        // Single pane layout (pane 5, checksum b7e2 for "83x44,0,0,5")
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0;@0;83;44;bash;b7e2,83x44,0,0,5
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete capture-pane + pane_state
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .expect_ready = true,
        },
        // Send extended output to pane 5
        .{
            .input = .{ .tmux = .{ .extended_output = .{
                .pane_id = 5,
                .age_ms = 100,
                .data = "extended data",
            } } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // No actions should be emitted (output goes directly to terminal)
                    try testing.expectEqual(0, actions.len);
                    // Verify data reached the terminal
                    const pane = v.panes.getEntry(5).?.value_ptr;
                    const screen: *@import("../Screen.zig") = pane.terminal.screens.active;
                    const str = try screen.dumpStringAlloc(
                        testing.allocator,
                        .{ .active = .{} },
                    );
                    defer testing.allocator.free(str);
                    try testing.expect(std.mem.containsAtLeast(u8, str, 1, "extended data"));
                }
            }).check,
        },
    });
}

test "flow control: pause unknown pane is no-op" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Startup
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "refresh-client",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
        // Single pane layout (pane 0 only)
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0;@0;83;44;bash;b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .expect_ready = true,
        },
        // Pause for non-existent pane 999 — should not crash
        .{
            .input = .{ .tmux = .{ .pause = .{ .pane_id = 999 } } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // pause_continue_pane_id should NOT be set for unknown pane
                    if (v.pause_continue_pane_id != null) {
                        return error.UnexpectedPauseContinue;
                    }
                }
            }).check,
        },
    });
}

test "pane state: mouse_all_flag sets flags.mouse_event to any" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "refresh-client",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
        // Single pane layout (pane 5)
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0;@0;83;44;bash;b7e2,83x44,0,0,5
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // 4 capture-pane responses (all empty)
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // list-panes pane_state: mouse_all_flag=1, mouse_sgr_flag=1
        //   fields: pane_id;cursor_x;cursor_y;cursor_flag;cursor_shape;
        //           cursor_colour;cursor_blinking;alternate_on;
        //           alternate_saved_x;alternate_saved_y;insert_flag;
        //           wrap_flag;keypad_flag;keypad_cursor_flag;origin_flag;
        //           mouse_all_flag;mouse_any_flag;mouse_button_flag;
        //           mouse_standard_flag;mouse_utf8_flag;mouse_sgr_flag;
        //           focus_flag;bracketed_paste;scroll_region_upper;
        //           scroll_region_lower;pane_tabs
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\%5;0;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;1;0;0;0;0;1;0;0;0;43;8,16,24,32,40,48,56,64,72,80
                ,
            } },
            .expect_ready = true,
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(5).?.value_ptr;
                    const t: *Terminal = &pane.terminal;
                    // modes should be set
                    try testing.expect(t.modes.get(.mouse_event_any));
                    try testing.expect(!t.modes.get(.mouse_event_button));
                    try testing.expect(!t.modes.get(.mouse_event_normal));
                    try testing.expect(!t.modes.get(.mouse_event_x10));
                    try testing.expect(t.modes.get(.mouse_format_sgr));
                    try testing.expect(!t.modes.get(.mouse_format_utf8));
                    // flags should be synced from modes
                    try testing.expectEqual(.any, t.flags.mouse_event);
                    try testing.expectEqual(.sgr, t.flags.mouse_format);
                }
            }).check,
        },
    });
}

test "pane state: mouse_button_flag sets flags.mouse_event to button" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "refresh-client",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0;@0;83;44;bash;b7e2,83x44,0,0,5
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // mouse_any_flag=1 (which maps to mouse_event_button), mouse_utf8_flag=1
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\%5;0;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;1;0;0;1;0;0;0;0;43;8,16,24,32,40,48,56,64,72,80
                ,
            } },
            .expect_ready = true,
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(5).?.value_ptr;
                    const t: *Terminal = &pane.terminal;
                    try testing.expect(t.modes.get(.mouse_event_button));
                    try testing.expect(t.modes.get(.mouse_format_utf8));
                    try testing.expectEqual(.button, t.flags.mouse_event);
                    try testing.expectEqual(.utf8, t.flags.mouse_format);
                }
            }).check,
        },
    });
}

test "pane state: mouse_standard_flag sets flags.mouse_event to x10" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "refresh-client",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0;@0;83;44;bash;b7e2,83x44,0,0,5
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // mouse_standard_flag=1 (x10 mode), no format flags
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\%5;0;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;1;0;0;0;0;0;43;8,16,24,32,40,48,56,64,72,80
                ,
            } },
            .expect_ready = true,
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(5).?.value_ptr;
                    const t: *Terminal = &pane.terminal;
                    try testing.expect(t.modes.get(.mouse_event_x10));
                    try testing.expectEqual(.x10, t.flags.mouse_event);
                    try testing.expectEqual(.x10, t.flags.mouse_format);
                }
            }).check,
        },
    });
}

test "pane state: no mouse flags leaves flags.mouse_event as none" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "refresh-client",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0;@0;83;44;bash;b7e2,83x44,0,0,5
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // All mouse flags = 0
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\%5;0;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;0;0;0;43;8,16,24,32,40,48,56,64,72,80
                ,
            } },
            .expect_ready = true,
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(5).?.value_ptr;
                    const t: *Terminal = &pane.terminal;
                    try testing.expectEqual(.none, t.flags.mouse_event);
                    try testing.expectEqual(.x10, t.flags.mouse_format);
                }
            }).check,
        },
    });
}

test "pane state: mouse_all_flag takes precedence over lower mouse modes" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "refresh-client",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0;@0;83;44;bash;b7e2,83x44,0,0,5
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        // All mouse event flags set — mouse_all_flag should win
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\%5;0;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;1;1;1;1;1;1;0;0;0;43;8,16,24,32,40,48,56,64,72,80
                ,
            } },
            .expect_ready = true,
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const pane: *Viewer.Pane = v.panes.getEntry(5).?.value_ptr;
                    const t: *Terminal = &pane.terminal;
                    // All modes are set, but flags.mouse_event should
                    // reflect the highest-priority one (any > button > normal > x10)
                    try testing.expectEqual(.any, t.flags.mouse_event);
                    // Both sgr and utf8 format modes set — sgr should take priority
                    try testing.expectEqual(.sgr, t.flags.mouse_format);
                }
            }).check,
        },
    });
}

test "queueUserCommand returns command when queue is empty" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Standard startup sequence
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "refresh-client",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0;@0;83;44;bash;b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Drain capture-pane + pane_state commands (5 total for 1 pane)
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .expect_ready = true,
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.command_queue.empty());
                    try testing.expectEqual(.command_queue, v.state);
                    // Queue a user command — queue is empty so should return .command
                    const action = try v.queueUserCommand("show-buffer\n");
                    try testing.expect(action != null);
                    try testing.expect(action.? == .command);
                    // The formatted command should contain "show-buffer"
                    try testing.expect(std.mem.indexOf(u8, action.?.command, "show-buffer") != null);
                    // Should end with newline
                    try testing.expect(std.mem.endsWith(u8, action.?.command, "\n"));
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = .{ .reason = "" } } },
            .contains_tags = &.{.exit},
        },
    });
}

test "detach returns detach-client command" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    const actions = viewer.detach();
    try testing.expectEqual(1, actions.len);
    try testing.expect(actions[0] == .command);
    try testing.expectEqualStrings("detach-client\n", actions[0].command);
}

test "queueUserCommand returns null when queue has in-flight command" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Standard startup sequence
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "refresh-client",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane — queue now has
        // capture-pane commands in flight.
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0;@0;83;44;bash;b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(!v.command_queue.empty());
                    // Queue a user command — queue is NOT empty, should return null
                    const action = try v.queueUserCommand("list-buffers\n");
                    try testing.expect(action == null);
                    // But the command should still be queued
                    try testing.expect(!v.command_queue.empty());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = .{ .reason = "" } } },
            .contains_tags = &.{.exit},
        },
    });
}

test "command_response emitted on user command block_end" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Standard startup sequence
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "refresh-client",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0;@0;83;44;bash;b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Drain capture-pane + pane_state commands
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .expect_ready = true,
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.command_queue.empty());
                    // Queue a user command to get the .command action
                    const action = try v.queueUserCommand("show-buffer\n");
                    try testing.expect(action != null);
                    try testing.expect(action.? == .command);
                }
            }).check,
        },
        // Now simulate the response arriving as a block_end with content
        .{
            .input = .{ .tmux = .{ .block_end = "buffer content here" } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const resp = v.last_command_response orelse
                        return error.MissingCommandResponse;
                    try testing.expectEqualStrings("buffer content here", resp.content);
                    try testing.expect(!resp.is_error);
                    v.last_command_response = null;
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = .{ .reason = "" } } },
            .contains_tags = &.{.exit},
        },
    });
}

test "command_response with is_error on block_err" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Standard startup sequence
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "refresh-client",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0;@0;83;44;bash;b7dd,83x44,0,0,0
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Drain capture-pane + pane_state commands
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .expect_ready = true,
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.command_queue.empty());
                    // Queue a user command
                    const action = try v.queueUserCommand("delete-buffer -b nonexistent\n");
                    try testing.expect(action != null);
                    try testing.expect(action.? == .command);
                }
            }).check,
        },
        // Simulate error response from tmux
        .{
            .input = .{ .tmux = .{ .block_err = "no buffer nonexistent" } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    const resp = v.last_command_response orelse
                        return error.MissingCommandResponse;
                    try testing.expectEqualStrings("no buffer nonexistent", resp.content);
                    try testing.expect(resp.is_error);
                    v.last_command_response = null;
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = .{ .reason = "" } } },
            .contains_tags = &.{.exit},
        },
    });
}

test "fire-and-forget counter tracks send-keys responses" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    // Boot through startup to command_queue state.
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "refresh-client",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0;@0;83;44;bash;b7e2,83x44,0,0,5
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Consume pane capture responses (4 captures + 1 pane_state)
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\%5;0;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;0;0;0;43;8,16,24,32,40,48,56,64,72,80
                ,
            } },
            .expect_ready = true,
        },
    });

    // Counter should start at 0.
    try testing.expectEqual(0, viewer.pending_fire_and_forget);

    // Simulate two fire-and-forget actions being dispatched.
    viewer.trackFireAndForget();
    viewer.trackFireAndForget();
    try testing.expectEqual(2, viewer.pending_fire_and_forget);

    // Now feed two block_end responses with empty queue. These should
    // be consumed by the fire-and-forget counter instead of being
    // treated as unexpected output.
    _ = viewer.next(.{ .tmux = .{ .block_end = "" } });
    try testing.expectEqual(1, viewer.pending_fire_and_forget);

    _ = viewer.next(.{ .tmux = .{ .block_end = "" } });
    try testing.expectEqual(0, viewer.pending_fire_and_forget);
}

test "error response for pane capture is skipped gracefully" {
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    // Boot to command_queue state with one pane.
    try testViewer(&viewer, &.{
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_command = "refresh-client",
        },
        // Flow control response, triggers register_subscriptions
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "refresh-client",
        },
        // Subscription registration response, triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = "" } },
            .contains_command = "list-windows",
        },
        .{
            .input = .{ .tmux = .{
                .block_end =
                \\$0;@0;83;44;bash;b7e2,83x44,0,0,5
                ,
            } },
            .contains_tags = &.{ .windows, .command },
        },
    });

    // The command queue now has pane capture commands. Feed error
    // responses — they should be handled gracefully without going defunct.
    // (pane_history error)
    const actions1 = viewer.next(.{ .tmux = .{ .block_err = "pane not found" } });
    // Should not go defunct.
    try testing.expect(viewer.state != .defunct);
    // No exit action should be emitted.
    for (actions1) |action| {
        try testing.expect(action != .exit);
    }

    // (pane_visible error)
    const actions2 = viewer.next(.{ .tmux = .{ .block_err = "pane not found" } });
    try testing.expect(viewer.state != .defunct);
    for (actions2) |action| {
        try testing.expect(action != .exit);
    }
}

test "flow control: wait-exit in enable_flow_control command" {
    // Verify that the enable_flow_control command includes wait-exit.
    // Drive the full init sequence to the point where flow control is emitted.
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup: block_end → session_changed triggers command queue
        .{ .input = .{ .tmux = .{ .block_end = "" } } },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "$0",
            } } },
            // First command in queue: tmux_version (display-message)
            .contains_command = "display-message",
        },
        // Version response completes tmux_version → triggers enable_flow_control
        .{
            .input = .{ .tmux = .{ .block_end = "3.5a" } },
            .contains_tags = &.{.command},
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    for (actions) |action| {
                        if (action == .command) {
                            if (std.mem.indexOf(u8, action.command, "refresh-client -f")) |_| {
                                // The flow control command MUST contain wait-exit
                                try testing.expect(
                                    std.mem.indexOf(u8, action.command, "wait-exit") != null,
                                );
                                return;
                            }
                        }
                    }
                    // Flow control command must be present at this point
                    return error.FlowControlCommandNotFound;
                }
            }).check,
        },
    });
}

test "session_renamed persists name across subsequent next() calls" {
    // Verify that session_name is heap-duped and survives parser buffer
    // reuse from subsequent next() calls. We use a mutable buffer to
    // simulate the real failure mode: info.name points into a parser
    // buffer that gets overwritten on the next parse.
    var viewer = try Viewer.init(testing.allocator);
    defer viewer.deinit();

    // Bootstrap the viewer into connected state.
    _ = viewer.next(.{ .tmux = .{ .block_end = "" } });
    _ = viewer.next(.{ .tmux = .{ .session_changed = .{
        .id = 1,
        .name = "initial",
    } } });

    // Create a mutable buffer simulating a parser buffer.
    var buf: [32]u8 = undefined;
    const original_name = "renamed-session";
    @memcpy(buf[0..original_name.len], original_name);
    const name_slice: []const u8 = buf[0..original_name.len];

    // Feed session_renamed with a pointer into our mutable buffer.
    _ = viewer.next(.{ .tmux = .{ .session_renamed = .{
        .id = 1,
        .name = name_slice,
    } } });

    // session_name should be duped and match the original.
    try testing.expectEqualStrings(original_name, viewer.session_name.?);

    // Overwrite the mutable buffer (simulating parser buffer reuse).
    @memset(buf[0..original_name.len], 'X');

    // If session_name was an unowned pointer, it would now read "XXXXXXXXXXXXXXX".
    // Because it was duped, it should still be "renamed-session".
    try testing.expectEqualStrings(original_name, viewer.session_name.?);
}
