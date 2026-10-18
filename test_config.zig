const std = @import("std");
const config = @import("config.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var cfg = try config.loadConfig(allocator, "examples/configs/geode_test.json");
    defer cfg.deinit();

    std.debug.print("Host: {s}\n", .{cfg.db.host});
    std.debug.print("Port: {d}\n", .{cfg.db.port});
    std.debug.print("Transport: {s}\n", .{@tagName(cfg.db.transport)});
}
