const std = @import("std");
const geode = @import("geode_client");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("Connecting to localhost:3141...\n", .{});
    
    var client = geode.GeodeClient.init(allocator, "127.0.0.1", 3141, true);
    defer client.deinit();
    
    try client.connect();
    std.debug.print("Connected!\n", .{});
    
    try client.sendHello("test_client", "0.1.0");
    std.debug.print("Sent HELLO\n", .{});
    
    const response = try client.receiveMessage(5000);
    defer allocator.free(response);
    
    std.debug.print("Received: {s}\n", .{response});
}
