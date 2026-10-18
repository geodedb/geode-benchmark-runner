// SPDX-License-Identifier: MIT
// Copyright (c) 2024-2025 CodePros
//
// Zig 0.16 compatibility helpers.
//
// Zig 0.16 routes filesystem, clock, and sleep operations through an
// explicit `std.Io` instance. The zig_cli command callbacks do not carry an
// Io handle, so the process-wide instance received in `main()` is stashed
// here (`compat.setIo(init.io)`) and used by the helpers below.

const std = @import("std");
const builtin = @import("builtin");

var io_instance: ?std.Io = null;

/// Install the process-wide Io instance (call first thing in main()).
pub fn setIo(new_io: std.Io) void {
    io_instance = new_io;
}

/// Return the process-wide Io instance. Falls back to the test runner's Io in
/// test builds, and to the global blocking instance otherwise.
pub fn io() std.Io {
    if (io_instance) |i| return i;
    if (builtin.is_test) return std.testing.io;
    const t = std.Io.Threaded.global_single_threaded;
    t.allocator = std.heap.page_allocator;
    return t.io();
}

/// Replacement for the removed std.fs.cwd().
pub fn cwd() std.Io.Dir {
    return std.Io.Dir.cwd();
}

/// Replacement for the removed std.time.milliTimestamp (wall clock).
pub fn milliTimestamp() i64 {
    return std.Io.Clock.real.now(io()).toMilliseconds();
}

/// Replacement for the removed std.time.microTimestamp (wall clock).
pub fn microTimestamp() i64 {
    return std.Io.Clock.real.now(io()).toMicroseconds();
}

/// Replacement for the removed std.Thread.sleep / std.posix.nanosleep.
pub fn sleepNs(ns: u64) void {
    io().sleep(.fromNanoseconds(@intCast(ns)), .awake) catch {};
}

/// Read a whole file relative to the cwd (replacement for
/// `openFile` + `readToEndAlloc`). Returns error.FileTooBig when `max_bytes`
/// is exceeded, matching the 0.15 readToEndAlloc behaviour.
pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    return cwd().readFileAlloc(io(), path, allocator, .limited(max_bytes)) catch |err| switch (err) {
        error.StreamTooLong => error.FileTooBig,
        else => |e| e,
    };
}

/// Read a whole already-open file (replacement for File.readToEndAlloc).
pub fn readToEndAlloc(file: std.Io.File, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
    var buf: [4096]u8 = undefined;
    var reader = file.readerStreaming(io(), &buf);
    return reader.interface.allocRemaining(allocator, .limited(max_bytes)) catch |err| switch (err) {
        error.StreamTooLong => error.FileTooBig,
        error.ReadFailed => reader.err orelse error.ReadFailed,
        else => |e| e,
    };
}

/// Write all bytes to an already-open file (replacement for File.writeAll).
pub fn writeAll(file: std.Io.File, bytes: []const u8) !void {
    try file.writeStreamingAll(io(), bytes);
}

/// Create (or truncate) a file relative to the cwd and write `bytes` to it.
pub fn writeFile(path: []const u8, bytes: []const u8) !void {
    try cwd().writeFile(io(), .{ .sub_path = path, .data = bytes });
}

/// Replacement for std.fs.cwd().makePath.
pub fn makePath(path: []const u8) !void {
    try cwd().createDirPath(io(), path);
}

test "compat timestamps are monotonic-ish and positive" {
    const a = milliTimestamp();
    const b = microTimestamp();
    try std.testing.expect(a > 0);
    try std.testing.expect(b > 0);
}

/// Appends to a file using positional writes (replacement for the removed
/// `File.seekFromEnd(0)` + `File.writeAll` pattern).
pub const Appender = struct {
    file: std.Io.File,
    pos: u64,

    pub fn writeAll(self: *Appender, bytes: []const u8) !void {
        try self.file.writePositionalAll(io(), bytes, self.pos);
        self.pos += bytes.len;
    }
};

/// Start appending at the current end of `file`.
pub fn appender(file: std.Io.File) !Appender {
    return .{ .file = file, .pos = try file.length(io()) };
}
