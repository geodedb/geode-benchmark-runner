const std = @import("std");
const geode = @import("geode_client");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    std.debug.print("Connecting to localhost:3141...\n", .{});

    var client = try geode.GeodeClient.init(allocator, "127.0.0.1", 3141, true, "", "");
    defer client.deinit();

    try client.connect();
    std.debug.print("Connected!\n", .{});

    // sendHello sends HELLO and waits for the HELLO response
    try client.sendHello();
    std.debug.print("HELLO acknowledged (session: {s})\n", .{client.session_id});
}
