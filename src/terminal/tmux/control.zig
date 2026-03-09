//! This file contains the implementation for tmux control mode. See
//! tmux(1) for more information on control mode. Some basics are documented
//! here but this is not meant to be a comprehensive source of protocol
//! documentation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../../quirks.zig").inlineAssert;

const log = std.log.scoped(.terminal_tmux);

/// A tmux control mode parser. This takes in output from tmux control
/// mode and parses it into a structured notifications.
///
/// It is up to the caller to establish the connection to the tmux
/// control mode session in some way (e.g. via exec, a network socket,
/// whatever). This is fully agnostic to how the data is received and sent.
pub const Parser = struct {
    /// Current state of the client.
    state: State = .idle,

    /// The buffer used to store in-progress notifications, output, etc.
    buffer: std.Io.Writer.Allocating,

    /// The maximum size in bytes of the buffer. This is used to limit
    /// memory usage. If the buffer exceeds this size, the client will
    /// enter a broken state (the control mode session will be forcibly
    /// exited and future data dropped).
    max_bytes: usize = 1024 * 1024,

    /// The block ID from the most recent %begin line. Used to validate
    /// that %end/%error matches the corresponding %begin. The format is
    /// the raw suffix after "%begin " (e.g. "1234 56 0"). Stored in a
    /// fixed buffer because the parser's main buffer is cleared between
    /// %begin and %end/%error.
    block_id_buf: [64]u8 = undefined,
    block_id_len: u8 = 0,

    /// Returns the stored block ID, or null if none is stored.
    pub fn blockId(self: *const Parser) ?[]const u8 {
        return if (self.block_id_len > 0)
            self.block_id_buf[0..self.block_id_len]
        else
            null;
    }

    const State = enum {
        /// Outside of any active notifications. This should drop any output
        /// unless it is '%' on the first byte of a line. The buffer will be
        /// cleared when it sees '%', this is so that the previous notification
        /// data is valid until we receive/process new data.
        idle,

        /// We experienced unexpected input and are in a broken state
        /// so we cannot continue processing. When this state is set,
        /// the buffer has been deinited and must not be accessed.
        broken,

        /// Inside an active notification (started with '%').
        notification,

        /// Inside a begin/end block.
        block,
    };

    pub fn deinit(self: *Parser) void {
        // If we're in a broken state, we already deinited
        // the buffer, so we don't need to do anything.
        if (self.state == .broken) return;

        self.buffer.deinit();
    }

    /// Unescape tmux control mode octal escapes in-place.
    /// tmux encodes bytes <32 and backslash as \NNN (3 octal digits).
    /// Returns the decoded slice (which is a prefix of the input).
    pub fn unescapeOctal(data: []u8) []u8 {
        var read: usize = 0;
        var write: usize = 0;
        while (read < data.len) {
            if (data[read] == '\\' and read + 3 < data.len and
                isOctalDigit(data[read + 1]) and
                isOctalDigit(data[read + 2]) and
                isOctalDigit(data[read + 3]))
            {
                // Compute the octal value using u16 to avoid overflow.
                // Values above 255 (\400+) cannot represent a byte, so
                // treat them as literal characters.
                const val: u16 = (@as(u16, data[read + 1] - '0') << 6) |
                    (@as(u16, data[read + 2] - '0') << 3) |
                    (data[read + 3] - '0');
                if (val <= std.math.maxInt(u8)) {
                    data[write] = @intCast(val);
                    read += 4;
                } else {
                    data[write] = data[read];
                    read += 1;
                }
            } else {
                data[write] = data[read];
                read += 1;
            }
            write += 1;
        }
        return data[0..write];
    }

    fn isOctalDigit(c: u8) bool {
        return c >= '0' and c <= '7';
    }

    // Handle a byte of input.
    //
    // If we reach our byte limit this will return OutOfMemory. It only
    // does this on the first time we exceed the limit; subsequent calls
    // will return null as we drop all input in a broken state.
    pub fn put(self: *Parser, byte: u8) Allocator.Error!?Notification {
        // If we're in a broken state, just do nothing.
        //
        // We have to do this check here before we check the buffer, because if
        // we're in a broken state then we'd have already deinited the buffer.
        if (self.state == .broken) return null;

        if (self.buffer.written().len >= self.max_bytes) {
            self.broken();
            return error.OutOfMemory;
        }

        switch (self.state) {
            // Drop because we're in a broken state.
            .broken => return null,

            // Waiting for a notification so if the byte is not '%' then
            // we're in a broken state. Control mode output should always
            // be wrapped in '%begin/%end' orelse we expect a notification.
            // Return an exit notification.
            .idle => if (byte != '%') {
                self.broken();
                return .{ .exit = .{ .reason = "" } };
            } else {
                self.buffer.clearRetainingCapacity();
                self.state = .notification;
            },

            // If we're in a notification and its not a newline then
            // we accumulate. If it is a newline then we have a
            // complete notification we need to parse.
            .notification => if (byte == '\n') {
                // We have a complete notification, parse it.
                return self.parseNotification();
            },

            // If we're in a block then we accumulate until we see a newline
            // and then we check to see if that line ended the block.
            .block => if (byte == '\n') {
                const written = self.buffer.written();
                const idx = if (std.mem.lastIndexOfScalar(
                    u8,
                    written,
                    '\n',
                )) |v| v + 1 else 0;
                const line = written[idx..];

                if (std.mem.startsWith(u8, line, "%end") or
                    std.mem.startsWith(u8, line, "%error"))
                {
                    const err = std.mem.startsWith(u8, line, "%error");
                    const output = std.mem.trimRight(u8, written[0..idx], "\r\n");

                    // Validate that the block ID matches the corresponding %begin.
                    // Format: "%end <id>" or "%error <id>" where <id> should match
                    // the <id> from the "%begin <id>" that opened this block.
                    const tag = if (err) "%error" else "%end";
                    const end_id = std.mem.trim(u8, line[tag.len..], " \r\n\t");
                    if (self.blockId()) |begin_id| {
                        if (!std.mem.eql(u8, begin_id, end_id)) {
                            log.warn(
                                "tmux block ID mismatch: begin={s} end={s}",
                                .{ begin_id, end_id },
                            );
                        }
                    }
                    self.block_id_len = 0;

                    // If it is an error then log it.
                    if (err) log.warn("tmux control mode error={s}", .{output});

                    // Important: do not clear buffer since the notification
                    // contains it.
                    self.state = .idle;
                    return if (err) .{ .block_err = output } else .{ .block_end = output };
                }

                // Didn't end the block, continue accumulating.
            },
        }

        self.buffer.writer.writeByte(byte) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
        };

        return null;
    }

    fn parseNotification(self: *Parser) ?Notification {
        assert(self.state == .notification);

        const line = line: {
            var line = self.buffer.written();
            if (line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            break :line line;
        };
        const space_pos = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
        const cmd = line[0..space_pos];
        // Payload after the command token (empty if no space follows the command).
        const payload = if (space_pos < line.len) line[space_pos + 1 ..] else "";

        // The notification MUST exist because we guard entering the notification
        // state on seeing at least a '%'.
        if (std.mem.eql(u8, cmd, "%begin")) {
            // Store the block ID (everything after "%begin ") so we can
            // validate that the corresponding %end/%error has a matching ID.
            // The format is: %begin <timestamp> <command_number> <flags>
            const id = std.mem.trim(u8, payload, " \r\n\t");
            if (id.len > 0 and id.len <= self.block_id_buf.len) {
                @memcpy(self.block_id_buf[0..id.len], id);
                self.block_id_len = @intCast(id.len);
            } else {
                self.block_id_len = 0;
            }

            // Move to block state because we expect a corresponding end/error
            // and want to accumulate the data.
            self.state = .block;
            self.buffer.clearRetainingCapacity();
            return null;
        } else if (std.mem.eql(u8, cmd, "%output")) cmd: {
            // Format: %output %<pane_id> <data>
            const rest = payload;
            if (rest.len == 0 or rest[0] != '%') break :cmd;
            const space_idx = std.mem.indexOfScalar(u8, rest[1..], ' ') orelse break :cmd;
            const id = std.fmt.parseInt(usize, rest[1..][0..space_idx], 10) catch {
                break :cmd;
            };

            // Data is returned raw — still octal-escaped per tmux's
            // control.c encoding (bytes <32 and backslash as \NNN).
            // Decoding is deferred to the consumer (viewer.zig) to
            // avoid work for untracked or discarded pane output.
            const data = rest[1 + space_idx + 1 ..];

            // Important: do not clear buffer here since data points to it
            self.state = .idle;
            return .{ .output = .{ .pane_id = id, .data = data } };
        } else if (std.mem.eql(u8, cmd, "%session-changed")) cmd: {
            // Format: %session-changed $<session_id> <name>
            const rest = payload;
            if (rest.len == 0 or rest[0] != '$') break :cmd;
            const space_idx = std.mem.indexOfScalar(u8, rest[1..], ' ') orelse break :cmd;
            const id = std.fmt.parseInt(usize, rest[1..][0..space_idx], 10) catch {
                break :cmd;
            };
            const name = rest[1 + space_idx + 1 ..];
            if (name.len == 0) break :cmd;

            // Important: do not clear buffer here since name points to it
            self.state = .idle;
            return .{ .session_changed = .{ .id = id, .name = name } };
        } else if (std.mem.eql(u8, cmd, "%sessions-changed")) {
            // %sessions-changed has no payload. Ignore any trailing content.

            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return .{ .sessions_changed = {} };
        } else if (std.mem.eql(u8, cmd, "%layout-change")) cmd: {
            // Format: %layout-change @<window_id> <layout> <visible_layout> <raw_flags>
            // Parse left-to-right: window_id, layout, and visible_layout are
            // space-delimited tokens that never contain spaces. Everything
            // after the third space is raw_flags (which may be empty or
            // contain spaces).
            const rest = payload;
            if (rest.len == 0 or rest[0] != '@') break :cmd;

            // Find the space after the window ID.
            const id_end = std.mem.indexOfScalar(u8, rest[1..], ' ') orelse break :cmd;
            const id = std.fmt.parseInt(usize, rest[1..][0..id_end], 10) catch {
                break :cmd;
            };

            // Remainder after "@<id> " is "<layout> <visible_layout> <raw_flags>"
            const after_id = rest[1 + id_end + 1 ..];
            const layout_end = std.mem.indexOfScalar(u8, after_id, ' ') orelse break :cmd;
            const layout = after_id[0..layout_end];

            const after_layout = after_id[layout_end + 1 ..];
            const vis_end = std.mem.indexOfScalar(u8, after_layout, ' ') orelse break :cmd;
            const visible_layout = after_layout[0..vis_end];
            const raw_flags = after_layout[vis_end + 1 ..];

            // Important: do not clear buffer here since layout strings point to it
            self.state = .idle;
            return .{ .layout_change = .{
                .window_id = id,
                .layout = layout,
                .visible_layout = visible_layout,
                .raw_flags = raw_flags,
            } };
        } else if (std.mem.eql(u8, cmd, "%window-add")) cmd: {
            // Format: %window-add @<window_id>
            const rest = payload;
            if (rest.len == 0 or rest[0] != '@') break :cmd;
            const id = std.fmt.parseInt(usize, rest[1..], 10) catch {
                break :cmd;
            };

            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return .{ .window_add = .{ .id = id } };
        } else if (std.mem.eql(u8, cmd, "%window-renamed")) cmd: {
            // Format: %window-renamed @<window_id> <name>
            const rest = payload;
            if (rest.len == 0 or rest[0] != '@') break :cmd;
            const space_idx = std.mem.indexOfScalar(u8, rest[1..], ' ') orelse break :cmd;
            const id = std.fmt.parseInt(usize, rest[1..][0..space_idx], 10) catch {
                break :cmd;
            };
            const name = rest[1 + space_idx + 1 ..];
            if (name.len == 0) break :cmd;

            // Important: do not clear buffer here since name points to it
            self.state = .idle;
            return .{ .window_renamed = .{ .id = id, .name = name } };
        } else if (std.mem.eql(u8, cmd, "%window-pane-changed")) cmd: {
            // Format: %window-pane-changed @<window_id> %<pane_id>
            const rest = payload;
            if (rest.len == 0 or rest[0] != '@') break :cmd;
            const space_idx = std.mem.indexOfScalar(u8, rest[1..], ' ') orelse break :cmd;
            const window_id = std.fmt.parseInt(usize, rest[1..][0..space_idx], 10) catch {
                break :cmd;
            };
            const pane_part = rest[1 + space_idx + 1 ..];
            if (pane_part.len == 0 or pane_part[0] != '%') break :cmd;
            const pane_id = std.fmt.parseInt(usize, pane_part[1..], 10) catch {
                break :cmd;
            };

            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return .{ .window_pane_changed = .{ .window_id = window_id, .pane_id = pane_id } };
        } else if (std.mem.eql(u8, cmd, "%client-detached")) cmd: {
            // Format: %client-detached <client>
            const client = payload;
            if (client.len == 0) break :cmd;

            // Important: do not clear buffer here since client points to it
            self.state = .idle;
            return .{ .client_detached = .{ .client = client } };
        } else if (std.mem.eql(u8, cmd, "%client-session-changed")) cmd: {
            // Format: %client-session-changed <client> $<session_id> <name>
            // Parse right-to-left: find the last " $" to split client from
            // session, avoiding ambiguity when client names contain spaces.
            const rest = payload;

            // Find " $" — the session ID delimiter. Search from the end
            // to handle client names that might contain spaces.
            const dollar_pos = std.mem.lastIndexOf(u8, rest, " $") orelse break :cmd;
            const client = rest[0..dollar_pos];
            if (client.len == 0) break :cmd;

            const after_dollar = rest[dollar_pos + 2 ..]; // skip " $"
            const space_idx = std.mem.indexOfScalar(u8, after_dollar, ' ') orelse break :cmd;
            const session_id = std.fmt.parseInt(usize, after_dollar[0..space_idx], 10) catch {
                break :cmd;
            };
            const name = after_dollar[space_idx + 1 ..];
            if (name.len == 0) break :cmd;

            // Important: do not clear buffer here since client/name point to it
            self.state = .idle;
            return .{ .client_session_changed = .{ .client = client, .session_id = session_id, .name = name } };
        } else if (std.mem.eql(u8, cmd, "%pause")) cmd: {
            // Flow control: %pause %<pane_id>
            const rest = payload;
            if (rest.len == 0 or rest[0] != '%') break :cmd;
            const id = std.fmt.parseInt(usize, rest[1..], 10) catch {
                break :cmd;
            };

            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return .{ .pause = .{ .pane_id = id } };
        } else if (std.mem.eql(u8, cmd, "%continue")) cmd: {
            // Flow control: %continue %<pane_id>
            const rest = payload;
            if (rest.len == 0 or rest[0] != '%') break :cmd;
            const id = std.fmt.parseInt(usize, rest[1..], 10) catch {
                break :cmd;
            };

            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return .{ .continue_pane = .{ .pane_id = id } };
        } else if (std.mem.eql(u8, cmd, "%extended-output")) cmd: {
            // Flow control: %extended-output %<pane_id> <age_ms> : <data>
            // The " : " separator separates metadata from the actual output data.
            const rest = payload;
            if (rest.len == 0 or rest[0] != '%') break :cmd;
            const space1 = std.mem.indexOfScalar(u8, rest[1..], ' ') orelse break :cmd;
            const id = std.fmt.parseInt(usize, rest[1..][0..space1], 10) catch {
                break :cmd;
            };

            const after_id = rest[1 + space1 + 1 ..];
            // Find the " : " separator between age_ms and data.
            const sep = std.mem.indexOf(u8, after_id, " : ") orelse break :cmd;
            const age_ms = std.fmt.parseInt(usize, after_id[0..sep], 10) catch {
                break :cmd;
            };

            // Data is returned raw (still octal-escaped), same as %output.
            // Consumer is responsible for decoding.
            const data = after_id[sep + " : ".len ..];

            // Important: do not clear buffer here since data points to it
            self.state = .idle;
            return .{ .extended_output = .{ .pane_id = id, .age_ms = age_ms, .data = data } };
        } else if (std.mem.eql(u8, cmd, "%window-close")) cmd: {
            // Format: %window-close @<window_id>
            const rest = payload;
            if (rest.len == 0 or rest[0] != '@') break :cmd;
            const id = std.fmt.parseInt(usize, rest[1..], 10) catch {
                break :cmd;
            };

            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return .{ .window_close = .{ .id = id } };
        } else if (std.mem.eql(u8, cmd, "%session-window-changed")) cmd: {
            // Format: %session-window-changed $<session_id> @<window_id>
            const rest = payload;
            if (rest.len == 0 or rest[0] != '$') break :cmd;
            const space_idx = std.mem.indexOfScalar(u8, rest[1..], ' ') orelse break :cmd;
            const session_id = std.fmt.parseInt(usize, rest[1..][0..space_idx], 10) catch {
                break :cmd;
            };
            const win_part = rest[1 + space_idx + 1 ..];
            if (win_part.len == 0 or win_part[0] != '@') break :cmd;
            const window_id = std.fmt.parseInt(usize, win_part[1..], 10) catch {
                break :cmd;
            };

            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return .{ .session_window_changed = .{ .session_id = session_id, .window_id = window_id } };
        } else if (std.mem.eql(u8, cmd, "%subscription-changed")) cmd: {
            // Format from tmux source (control.c):
            //   %subscription-changed name $session @window idx %pane : value
            // or for session-scope subscriptions:
            //   %subscription-changed name $session - - - : value
            // We extract the subscription name and the value after " : ".
            const rest = payload;

            // The name is the first space-delimited token.
            const name_end = std.mem.indexOfScalar(u8, rest, ' ') orelse break :cmd;
            const name = rest[0..name_end];
            if (name.len == 0) break :cmd;

            // The value comes after " : ". Search for the separator in the
            // remainder of the line. The value may be empty.
            const after_name = rest[name_end..];
            const sep = std.mem.indexOf(u8, after_name, " : ") orelse break :cmd;

            // Validate the metadata between name and " : ". Expected format:
            //   " $session @window idx %pane"  or  " $session - - -"
            // i.e., a leading space followed by exactly 4 space-delimited
            // tokens, with the first starting with '$'.
            if (sep == 0) break :cmd; // must have at least the leading space and metadata
            const meta = after_name[1..sep]; // skip the leading space
            if (meta.len == 0 or meta[0] != '$') break :cmd;
            var space_count: usize = 0;
            for (meta) |ch| {
                if (ch == ' ') space_count += 1;
            }
            if (space_count != 3) break :cmd;

            const value = after_name[sep + " : ".len ..];

            // Important: do not clear buffer here since name and value point to it
            self.state = .idle;
            return .{ .subscription_changed = .{ .name = name, .value = value } };
        } else if (std.mem.eql(u8, cmd, "%pane-mode-changed")) cmd: {
            // Format: %pane-mode-changed %<pane_id>
            const rest = payload;
            if (rest.len == 0 or rest[0] != '%') break :cmd;
            const pane_id = std.fmt.parseInt(usize, rest[1..], 10) catch {
                break :cmd;
            };

            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return .{ .pane_mode_changed = .{ .pane_id = pane_id } };
        } else if (std.mem.eql(u8, cmd, "%session-renamed")) cmd: {
            // Format: %session-renamed $<session_id> <name>
            const rest = payload;
            if (rest.len == 0 or rest[0] != '$') break :cmd;
            const space_idx = std.mem.indexOfScalar(u8, rest[1..], ' ') orelse break :cmd;
            const id = std.fmt.parseInt(usize, rest[1..][0..space_idx], 10) catch {
                break :cmd;
            };
            const name = rest[1 + space_idx + 1 ..];
            if (name.len == 0) break :cmd;

            // Do not clear buffer — name points into it.
            self.state = .idle;
            return .{ .session_renamed = .{ .id = id, .name = name } };
        } else if (std.mem.eql(u8, cmd, "%unlinked-window-add")) cmd: {
            // Format: %unlinked-window-add @<window_id>
            const rest = payload;
            if (rest.len == 0 or rest[0] != '@') break :cmd;
            const id = std.fmt.parseInt(usize, rest[1..], 10) catch {
                break :cmd;
            };

            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return .{ .unlinked_window_add = .{ .id = id } };
        } else if (std.mem.eql(u8, cmd, "%unlinked-window-close")) cmd: {
            // Format: %unlinked-window-close @<window_id>
            const rest = payload;
            if (rest.len == 0 or rest[0] != '@') break :cmd;
            const id = std.fmt.parseInt(usize, rest[1..], 10) catch {
                break :cmd;
            };

            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return .{ .unlinked_window_close = .{ .id = id } };
        } else if (std.mem.eql(u8, cmd, "%unlinked-window-renamed")) cmd: {
            // Format: %unlinked-window-renamed @<window_id> <name>
            const rest = payload;
            if (rest.len == 0 or rest[0] != '@') break :cmd;
            const space_idx = std.mem.indexOfScalar(u8, rest[1..], ' ') orelse break :cmd;
            const id = std.fmt.parseInt(usize, rest[1..][0..space_idx], 10) catch {
                break :cmd;
            };
            const name = rest[1 + space_idx + 1 ..];
            if (name.len == 0) break :cmd;

            // Do not clear buffer — name points into it.
            self.state = .idle;
            return .{ .unlinked_window_renamed = .{ .id = id, .name = name } };
        } else if (std.mem.eql(u8, cmd, "%paste-buffer-changed")) {
            // %paste-buffer-changed <name>
            // Sent when a paste buffer is created or changed.

            // Do not clear buffer — payload points into it.
            self.state = .idle;
            return .{ .paste_buffer_changed = payload };
        } else if (std.mem.eql(u8, cmd, "%paste-buffer-deleted")) {
            // %paste-buffer-deleted <name>
            // Sent when a paste buffer is deleted.

            // Do not clear buffer — payload points into it.
            self.state = .idle;
            return .{ .paste_buffer_deleted = payload };
        } else if (std.mem.eql(u8, cmd, "%config-error")) {
            // %config-error <error>
            // Sent when an error occurs in a configuration file.
            // Added in tmux 3.4.

            // Do not clear buffer — payload points into it.
            self.state = .idle;
            return .{ .config_error = payload };
        } else if (std.mem.eql(u8, cmd, "%message")) {
            // %message <text>
            // Sent when tmux generates a display-message. The payload is
            // the remainder of the line after the command name.

            // Do not clear buffer — payload points into it.
            self.state = .idle;
            return .{ .message = payload };
        } else if (std.mem.eql(u8, cmd, "%exit")) {
            // tmux sends %exit when the control mode client is exiting.
            // The optional reason string follows the command (e.g.,
            // "%exit detached", "%exit server-exited").

            // Important: do not clear buffer here since reason points to it
            self.state = .idle;
            return .{ .exit = .{ .reason = payload } };
        } else {
            // Unknown notification, log it and return to idle state.
            log.warn("unknown tmux control mode notification={s}", .{cmd});
        }

        // Unknown command. Clear the buffer and return to idle state.
        self.buffer.clearRetainingCapacity();
        self.state = .idle;

        return null;
    }

    // Mark the tmux state as broken.
    fn broken(self: *Parser) void {
        self.state = .broken;
        self.buffer.deinit();
    }
};

/// Possible notification types from tmux control mode. These are documented
/// in tmux(1). A lot of the simple documentation was copied from that man
/// page here.
pub const Notification = union(enum) {
    /// Entering tmux control mode. This isn't an actual event sent by
    /// tmux but is one sent by us to indicate that we have detected that
    /// tmux control mode is starting.
    enter,

    /// Exit.
    ///
    /// The reason field contains the human-readable reason string from
    /// tmux (e.g., "detached", "server-exited"), or an empty string if
    /// no reason was provided.
    exit: struct {
        reason: []const u8,
    },

    /// Dispatched at the end of a begin/end block with the raw data.
    /// The control mode parser can't parse the data because it is unaware
    /// of the command that was sent to trigger this output.
    block_end: []const u8,
    block_err: []const u8,

    /// Raw output from a pane. Data is still octal-escaped per tmux's
    /// control.c encoding (bytes <32 and backslash as \NNN). The consumer
    /// is responsible for calling unescapeOctal() before interpretation.
    output: struct {
        pane_id: usize,
        data: []const u8, // raw, octal-escaped per tmux control.c
    },

    /// The client is now attached to the session with ID session-id, which is
    /// named name.
    session_changed: struct {
        id: usize,
        name: []const u8,
    },

    /// A session was created or destroyed.
    sessions_changed,

    /// The layout of the window with ID window-id changed.
    layout_change: struct {
        window_id: usize,
        layout: []const u8,
        visible_layout: []const u8,
        raw_flags: []const u8,
    },

    /// The window with ID window-id was linked to the current session.
    window_add: struct {
        id: usize,
    },

    /// The window with ID window-id was renamed to name.
    window_renamed: struct {
        id: usize,
        name: []const u8,
    },

    /// The active pane in the window with ID window-id changed to the pane
    /// with ID pane-id.
    window_pane_changed: struct {
        window_id: usize,
        pane_id: usize,
    },

    /// The window with ID window-id was closed.
    window_close: struct {
        id: usize,
    },

    /// The session's current window changed to window-id in session-id.
    session_window_changed: struct {
        session_id: usize,
        window_id: usize,
    },

    /// The client has detached.
    client_detached: struct {
        client: []const u8,
    },

    /// The client is now attached to the session with ID session-id, which is
    /// named name.
    client_session_changed: struct {
        client: []const u8,
        session_id: usize,
        name: []const u8,
    },

    /// Flow control: a pane has been paused because the client fell behind.
    /// Sent when flow control is enabled via `refresh-client -f pause-after=N`.
    pause: struct {
        pane_id: usize,
    },

    /// Flow control: a previously paused pane has been continued.
    continue_pane: struct {
        pane_id: usize,
    },

    /// Flow control: extended output from a pane. Replaces `%output` when
    /// flow control is enabled. Includes the number of milliseconds by which
    /// the pane output is behind.
    extended_output: struct {
        pane_id: usize,
        age_ms: usize,
        data: []const u8,
    },

    /// A pane entered or exited a special mode (copy mode, choose mode, etc.).
    pane_mode_changed: struct {
        pane_id: usize,
    },

    /// A session was renamed (by any client).
    session_renamed: struct {
        id: usize,
        name: []const u8,
    },

    /// A window was added in a session other than the attached one.
    unlinked_window_add: struct {
        id: usize,
    },

    /// A window was closed in a session other than the attached one.
    unlinked_window_close: struct {
        id: usize,
    },

    /// A window was renamed in a session other than the attached one.
    unlinked_window_renamed: struct {
        id: usize,
        name: []const u8,
    },

    /// A format subscription value has changed. Sent when a subscription
    /// registered via `refresh-client -B` detects that the expanded format
    /// value has changed. The format is:
    ///   %subscription-changed name $session @window idx %pane : value
    /// where @window, idx, and %pane may be "-" if the subscription scope
    /// is session-level. See tmux(1) Control Mode — Format subscriptions.
    subscription_changed: struct {
        name: []const u8,
        value: []const u8,
    },

    /// A message sent by `display-message`. tmux emits this notification
    /// when a message is generated by the `display-message` command or by
    /// tmux internally (e.g., "no previous window"). The format is:
    ///   %message <text>
    message: []const u8,

    /// A paste buffer was created or modified. The format is:
    ///   %paste-buffer-changed <name>
    paste_buffer_changed: []const u8,

    /// A paste buffer was deleted. The format is:
    ///   %paste-buffer-deleted <name>
    paste_buffer_deleted: []const u8,

    /// A configuration file error occurred. Added in tmux 3.4.
    /// The format is:
    ///   %config-error <error>
    config_error: []const u8,

    pub fn format(self: Notification, writer: *std.Io.Writer) !void {
        const T = Notification;
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

test "tmux begin/end empty" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1578922740 269 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1578922740 269 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("", n.block_end);
}

test "tmux begin/error empty" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1578922740 269 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%error 1578922740 269 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_err);
    try testing.expectEqualStrings("", n.block_err);
}

test "tmux begin/end data" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1578922740 269 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("hello\nworld\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1578922740 269 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("hello\nworld", n.block_end);
}

test "tmux output" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%output %42 foo bar baz") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .output);
    try testing.expectEqual(42, n.output.pane_id);
    try testing.expectEqualStrings("foo bar baz", n.output.data);
}

test "tmux output empty data" {
    // %output with an empty data field (just pane ID and trailing space)
    // should be parsed as output with empty data, not rejected.
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%output %7 ") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .output);
    try testing.expectEqual(7, n.output.pane_id);
    try testing.expectEqualStrings("", n.output.data);
}

test "tmux output truncated no payload" {
    // Malformed: "%output" with no space or payload should not panic.
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%output") |byte| try testing.expect(try c.put(byte) == null);
    const n = try c.put('\n');
    // Should return null (failed to parse), not panic.
    try testing.expect(n == null);
}

test "tmux session-changed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%session-changed $42 foo") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .session_changed);
    try testing.expectEqual(42, n.session_changed.id);
    try testing.expectEqualStrings("foo", n.session_changed.name);
}

test "tmux sessions-changed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%sessions-changed") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .sessions_changed);
}

test "tmux sessions-changed carriage return" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%sessions-changed\r") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .sessions_changed);
}

test "tmux layout-change" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%layout-change @2 1234x791,0,0{617x791,0,0,0,617x791,618,0,1} 1234x791,0,0{617x791,0,0,0,617x791,618,0,1} *-") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .layout_change);
    try testing.expectEqual(2, n.layout_change.window_id);
    try testing.expectEqualStrings("1234x791,0,0{617x791,0,0,0,617x791,618,0,1}", n.layout_change.layout);
    try testing.expectEqualStrings("1234x791,0,0{617x791,0,0,0,617x791,618,0,1}", n.layout_change.visible_layout);
    try testing.expectEqualStrings("*-", n.layout_change.raw_flags);
}

test "tmux window-add" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%window-add @14") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .window_add);
    try testing.expectEqual(14, n.window_add.id);
}

test "tmux window-renamed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%window-renamed @42 bar") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .window_renamed);
    try testing.expectEqual(42, n.window_renamed.id);
    try testing.expectEqualStrings("bar", n.window_renamed.name);
}

test "tmux window-pane-changed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%window-pane-changed @42 %2") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .window_pane_changed);
    try testing.expectEqual(42, n.window_pane_changed.window_id);
    try testing.expectEqual(2, n.window_pane_changed.pane_id);
}

test "tmux client-detached" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%client-detached /dev/pts/1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .client_detached);
    try testing.expectEqualStrings("/dev/pts/1", n.client_detached.client);
}

test "tmux client-session-changed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%client-session-changed /dev/pts/1 $2 mysession") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .client_session_changed);
    try testing.expectEqualStrings("/dev/pts/1", n.client_session_changed.client);
    try testing.expectEqual(2, n.client_session_changed.session_id);
    try testing.expectEqualStrings("mysession", n.client_session_changed.name);
}

test "unescape octal: no escapes passthrough" {
    var data = "hello world".*;
    const result = Parser.unescapeOctal(&data);
    try std.testing.expectEqualStrings("hello world", result);
}

test "unescape octal: single ESC" {
    // \033 = ESC (0x1B)
    var data = "\\033".*;
    const result = Parser.unescapeOctal(&data);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqual(@as(u8, 0x1B), result[0]);
}

test "unescape octal: CR LF sequence" {
    // \015\012 = CR LF
    var data = "\\015\\012".*;
    const result = Parser.unescapeOctal(&data);
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqual(@as(u8, 0x0D), result[0]);
    try std.testing.expectEqual(@as(u8, 0x0A), result[1]);
}

test "unescape octal: escaped backslash" {
    // \134 = backslash
    var data = "\\134".*;
    const result = Parser.unescapeOctal(&data);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqual(@as(u8, '\\'), result[0]);
}

test "unescape octal: mixed escaped and literal" {
    // "hello\033[31mworld" = "hello" + ESC + "[31mworld"
    var data = "hello\\033[31mworld".*;
    const result = Parser.unescapeOctal(&data);
    try std.testing.expectEqual(@as(usize, 15), result.len);
    try std.testing.expectEqualStrings("hello", result[0..5]);
    try std.testing.expectEqual(@as(u8, 0x1B), result[5]);
    try std.testing.expectEqualStrings("[31mworld", result[6..]);
}

test "unescape octal: multiple escapes in sequence" {
    // \033\033 = ESC ESC
    var data = "\\033\\033".*;
    const result = Parser.unescapeOctal(&data);
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqual(@as(u8, 0x1B), result[0]);
    try std.testing.expectEqual(@as(u8, 0x1B), result[1]);
}

test "unescape octal: backspace encoding from device" {
    // \010ls = BS + "ls" (the exact pattern seen in device logs)
    var data = "\\010ls".*;
    const result = Parser.unescapeOctal(&data);
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqual(@as(u8, 0x08), result[0]);
    try std.testing.expectEqualStrings("ls", result[1..]);
}

test "unescape octal: trailing backslash not enough digits" {
    // Backslash at end without 3 digits should pass through
    var data = "abc\\".*;
    const result = Parser.unescapeOctal(&data);
    try std.testing.expectEqualStrings("abc\\", result);
}

test "unescape octal: backslash with non-octal digits" {
    // \8 is not octal, should pass through
    var data = "\\899".*;
    const result = Parser.unescapeOctal(&data);
    try std.testing.expectEqualStrings("\\899", result);
}

test "tmux output with octal escapes" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Simulate: %output %2 hello\033[31mworld
    // tmux sends ESC as \033 in %output data.
    // Parser now returns raw (still-escaped) data; decoding is
    // deferred to the consumer (viewer.zig).
    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%output %2 hello\\033[31mworld") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .output);
    try testing.expectEqual(2, n.output.pane_id);
    // Data is raw: literal "hello\033[31mworld" (backslash + digits, not ESC byte)
    try testing.expectEqualStrings("hello\\033[31mworld", n.output.data);
}

test "tmux output with escaped backslash" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // %output %5 path\134file — raw data, not decoded
    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%output %5 path\\134file") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .output);
    try testing.expectEqual(5, n.output.pane_id);
    try testing.expectEqualStrings("path\\134file", n.output.data);
}

test "tmux output with CR LF" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // %output %1 line1\015\012line2 — raw data, not decoded
    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%output %1 line1\\015\\012line2") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .output);
    try testing.expectEqual(1, n.output.pane_id);
    // Data is raw: literal "line1\015\012line2" (backslash + digits, not CR/LF bytes)
    try testing.expectEqualStrings("line1\\015\\012line2", n.output.data);
}

test "tmux output with raw UTF-8 box drawing" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // tmux sends UTF-8 bytes >= 0x80 raw (unescaped) in %output.
    // ┄ = U+2504 = e2 94 84
    // • = U+2022 = e2 80 a2
    // ━ = U+2501 = e2 94 81
    // ═ = U+2550 = e2 95 90
    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();

    // Build the %output line with raw UTF-8 bytes
    const prefix = "%output %3 ";
    const box_chars = "\xe2\x94\x84\xe2\x80\xa2\xe2\x94\x81\xe2\x95\x90";
    const line = prefix ++ box_chars;

    for (line) |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .output);
    try testing.expectEqual(3, n.output.pane_id);
    // Data should be the raw UTF-8 bytes, unchanged
    try testing.expectEqual(@as(usize, 12), n.output.data.len);
    try testing.expectEqualStrings(box_chars, n.output.data);
}

test "tmux output with mixed UTF-8 and octal escapes" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Octal-escaped ESC sequences + raw UTF-8 — parser returns raw data
    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();

    const input = "%output %1 \\033[31m\xe2\x94\x84\\033[0m";
    for (input) |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .output);
    try testing.expectEqual(1, n.output.pane_id);
    // Data is raw: literal "\033[31m" + raw UTF-8 ┄ + literal "\033[0m"
    try testing.expectEqualStrings("\\033[31m\xe2\x94\x84\\033[0m", n.output.data);
}

test "tmux output with 4-byte emoji pass-through" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // tmux sends UTF-8 bytes >= 0x80 raw (unescaped) in %output.
    // 4-byte emoji must pass through unchanged.
    // 😀 = U+1F600 = f0 9f 98 80
    // 🎉 = U+1F389 = f0 9f 8e 89
    // 🚀 = U+1F680 = f0 9f 9a 80
    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();

    const prefix = "%output %5 ";
    const emoji = "\xf0\x9f\x98\x80\xf0\x9f\x8e\x89\xf0\x9f\x9a\x80";
    const line = prefix ++ emoji;

    for (line) |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .output);
    try testing.expectEqual(5, n.output.pane_id);
    // Data should be the raw UTF-8 bytes, unchanged (12 bytes: 3 x 4-byte)
    try testing.expectEqual(@as(usize, 12), n.output.data.len);
    try testing.expectEqualStrings(emoji, n.output.data);
}

test "tmux output with CJK characters pass-through" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // CJK ideographs are 3-byte UTF-8, sent raw by tmux.
    // 中 = U+4E2D = e4 b8 ad
    // 文 = U+6587 = e6 96 87
    // 字 = U+5B57 = e5 ad 97
    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();

    const prefix = "%output %2 ";
    const cjk = "\xe4\xb8\xad\xe6\x96\x87\xe5\xad\x97";
    const line = prefix ++ cjk;

    for (line) |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .output);
    try testing.expectEqual(2, n.output.pane_id);
    // 9 bytes: 3 x 3-byte CJK characters
    try testing.expectEqual(@as(usize, 9), n.output.data.len);
    try testing.expectEqualStrings(cjk, n.output.data);
}

test "tmux output with mixed 3-byte and 4-byte UTF-8" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Mixed: box-drawing (3-byte) + emoji (4-byte) + CJK (3-byte)
    // ┄ = U+2504 = e2 94 84  (3 bytes)
    // 🚀 = U+1F680 = f0 9f 9a 80  (4 bytes)
    // 中 = U+4E2D = e4 b8 ad  (3 bytes)
    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();

    const prefix = "%output %0 ";
    const mixed = "\xe2\x94\x84\xf0\x9f\x9a\x80\xe4\xb8\xad";
    const line = prefix ++ mixed;

    for (line) |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .output);
    try testing.expectEqual(0, n.output.pane_id);
    // 10 bytes: 3 + 4 + 3
    try testing.expectEqual(@as(usize, 10), n.output.data.len);
    try testing.expectEqualStrings("\xe2\x94\x84", n.output.data[0..3]); // ┄
    try testing.expectEqualStrings("\xf0\x9f\x9a\x80", n.output.data[3..7]); // 🚀
    try testing.expectEqualStrings("\xe4\xb8\xad", n.output.data[7..10]); // 中
}

test "tmux output with 4-byte emoji and octal-escaped SGR" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Octal-escaped ESC sequences + raw 4-byte emoji — parser returns raw data
    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();

    const input = "%output %4 \\033[31m\xf0\x9f\x98\x80\\033[0m";
    for (input) |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .output);
    try testing.expectEqual(4, n.output.pane_id);
    // Data is raw: literal "\033[31m" + raw UTF-8 😀 + literal "\033[0m"
    try testing.expectEqualStrings("\\033[31m\xf0\x9f\x98\x80\\033[0m", n.output.data);
}

test "tmux window-close" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%window-close @7") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .window_close);
    try testing.expectEqual(7, n.window_close.id);
}

test "tmux session-window-changed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%session-window-changed $3 @5") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .session_window_changed);
    try testing.expectEqual(3, n.session_window_changed.session_id);
    try testing.expectEqual(5, n.session_window_changed.window_id);
}

test "tmux pause" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%pause %7") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .pause);
    try testing.expectEqual(7, n.pause.pane_id);
}

test "tmux continue" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%continue %12") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .continue_pane);
    try testing.expectEqual(12, n.continue_pane.pane_id);
}

test "tmux extended-output" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%extended-output %3 500 : hello world") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .extended_output);
    try testing.expectEqual(3, n.extended_output.pane_id);
    try testing.expectEqual(500, n.extended_output.age_ms);
    try testing.expectEqualStrings("hello world", n.extended_output.data);
}

test "tmux extended-output with octal escapes" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    // \033[31m = octal-escaped ESC — parser returns raw data
    for ("%extended-output %5 1200 : \\033[31mred") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .extended_output);
    try testing.expectEqual(5, n.extended_output.pane_id);
    try testing.expectEqual(1200, n.extended_output.age_ms);
    try testing.expectEqualStrings("\\033[31mred", n.extended_output.data);
}

test "tmux extended-output zero age" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%extended-output %0 0 : $") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .extended_output);
    try testing.expectEqual(0, n.extended_output.pane_id);
    try testing.expectEqual(0, n.extended_output.age_ms);
    try testing.expectEqualStrings("$", n.extended_output.data);
}

test "tmux extended-output empty data" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%extended-output %1 0 : ") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .extended_output);
    try testing.expectEqual(1, n.extended_output.pane_id);
    try testing.expectEqual(0, n.extended_output.age_ms);
    try testing.expectEqualStrings("", n.extended_output.data);
}

test "tmux subscription-changed session scope" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%subscription-changed pane_title $0 - - - : my title") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .subscription_changed);
    try testing.expectEqualStrings("pane_title", n.subscription_changed.name);
    try testing.expectEqualStrings("my title", n.subscription_changed.value);
}

test "tmux subscription-changed pane scope" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%subscription-changed mytitle $1 @0 0 %3 : hello world") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .subscription_changed);
    try testing.expectEqualStrings("mytitle", n.subscription_changed.name);
    try testing.expectEqualStrings("hello world", n.subscription_changed.value);
}

test "tmux subscription-changed empty value" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%subscription-changed watch $2 - - - : ") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .subscription_changed);
    try testing.expectEqualStrings("watch", n.subscription_changed.name);
    try testing.expectEqualStrings("", n.subscription_changed.value);
}

test "tmux pane-mode-changed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%pane-mode-changed %7") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .pane_mode_changed);
    try testing.expectEqual(7, n.pane_mode_changed.pane_id);
}

test "tmux session-renamed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%session-renamed $3 my new name") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .session_renamed);
    try testing.expectEqual(3, n.session_renamed.id);
    try testing.expectEqualStrings("my new name", n.session_renamed.name);
}

test "tmux unlinked-window-add" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%unlinked-window-add @5") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .unlinked_window_add);
    try testing.expectEqual(5, n.unlinked_window_add.id);
}

test "tmux unlinked-window-close" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%unlinked-window-close @12") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .unlinked_window_close);
    try testing.expectEqual(12, n.unlinked_window_close.id);
}

test "tmux unlinked-window-renamed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%unlinked-window-renamed @8 vim main.zig") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .unlinked_window_renamed);
    try testing.expectEqual(8, n.unlinked_window_renamed.id);
    try testing.expectEqualStrings("vim main.zig", n.unlinked_window_renamed.name);
}

test "tmux block_id stored on begin and cleared on end" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();

    // After %begin, block_id should be set.
    for ("%begin 1578922740 269 1\n") |byte| try testing.expect(try c.put(byte) == null);
    try testing.expectEqualStrings("1578922740 269 1", c.blockId().?);

    // After matching %end, block_id should be cleared.
    for ("%end 1578922740 269 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expect(c.blockId() == null);
}

test "tmux block_id mismatch still returns notification" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();

    // Begin with one ID.
    for ("%begin 1578922740 269 1\n") |byte| try testing.expect(try c.put(byte) == null);
    try testing.expectEqualStrings("1578922740 269 1", c.blockId().?);

    // End with a different ID — should still produce notification (warning
    // is logged but we don't go defunct). This exercises the code path where
    // a send-keys response interleaves with a queued command.
    for ("hello\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 9999999999 999 0") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("hello", n.block_end);
    // block_id should be cleared even on mismatch.
    try testing.expect(c.blockId() == null);
}

test "tmux block_id mismatch on error still returns notification" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();

    for ("%begin 1000 1 0\n") |byte| try testing.expect(try c.put(byte) == null);
    try testing.expectEqualStrings("1000 1 0", c.blockId().?);

    // Error with mismatched ID.
    for ("bad command\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%error 2000 2 0") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_err);
    try testing.expectEqualStrings("bad command", n.block_err);
    try testing.expect(c.blockId() == null);
}

test "tmux exit without reason" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%exit") |byte| try testing.expect(try c.put(byte) == null);
    const n2 = (try c.put('\n')).?;
    try testing.expect(n2 == .exit);
    try testing.expectEqualStrings("", n2.exit.reason);
}

test "tmux exit with reason" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%exit detached") |byte| try testing.expect(try c.put(byte) == null);
    const n2 = (try c.put('\n')).?;
    try testing.expect(n2 == .exit);
    try testing.expectEqualStrings("detached", n2.exit.reason);
}

test "tmux exit with server-exited reason" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%exit server-exited") |byte| try testing.expect(try c.put(byte) == null);
    const n2 = (try c.put('\n')).?;
    try testing.expect(n2 == .exit);
    try testing.expectEqualStrings("server-exited", n2.exit.reason);
}
