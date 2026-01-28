const std = @import("std");

pub const BenchConfig = struct {
    db_host: []const u8,
    db_port: u16,
    slo_ms: u32,

    pub fn deinit(_: *BenchConfig) void {}
};

pub fn loadConfig(allocator: std.mem.Allocator, _: []const u8) !BenchConfig {
    return BenchConfig{
        .db_host = try allocator.dupe(u8, "127.0.0.1"),
        .db_port = 3141,
        .slo_ms = 100,
    };
}
