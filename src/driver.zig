// SPDX-License-Identifier: MIT
// Copyright (c) 2024-2025 CodePros
//
// Geode database driver using geode-client-zig

const std = @import("std");
const geode = @import("geode_client");
const config = @import("config.zig");
const compat = @import("compat.zig");

const proto = geode.proto;

pub const QueryResult = struct {
    success: bool,
    latency_ms: f64,
    error_message: ?[]const u8,
    result_data: ?[]const u8,

    pub fn deinit(self: *QueryResult, allocator: std.mem.Allocator) void {
        if (self.error_message) |msg| allocator.free(msg);
        if (self.result_data) |data| allocator.free(data);
    }
};

pub const GeodeDriver = struct {
    allocator: std.mem.Allocator,
    db_config: config.DbConfig,
    client: ?geode.GeodeClient,
    connected: bool,
    request_counter: u64,

    pub fn init(allocator: std.mem.Allocator, db_config: config.DbConfig) GeodeDriver {
        return GeodeDriver{
            .allocator = allocator,
            .db_config = db_config,
            .client = null,
            .connected = false,
            .request_counter = 0,
        };
    }

    pub fn connect(self: *GeodeDriver) !void {
        const insecure = self.db_config.transport == .quic_tls_insecure;

        var client = try geode.GeodeClient.init(
            self.allocator,
            self.db_config.host,
            self.db_config.port,
            insecure,
            "",
            "",
        );
        errdefer client.deinit();

        try client.connect();

        // Send HELLO message and wait for the HELLO response
        try client.sendHello();

        self.client = client;
        self.connected = true;
    }

    pub fn disconnect(self: *GeodeDriver) void {
        if (self.connected and self.client != null) {
            self.client.?.deinit();
            self.client = null;
            self.connected = false;
        }
    }

    pub fn exec(self: *GeodeDriver, query: []const u8, params: ?std.StringHashMap([]const u8)) !QueryResult {
        // For now, use null params (full param support would require JSON conversion)
        _ = params;
        return self.execute(query, null);
    }

    pub fn execWithParams(self: *GeodeDriver, query: []const u8, params: std.json.Value) !QueryResult {
        return self.execute(query, params);
    }

    fn elapsedMs(start: i64) f64 {
        const end = compat.microTimestamp();
        return @as(f64, @floatFromInt(end - start)) / 1000.0;
    }

    fn failure(self: *GeodeDriver, start: i64, comptime fmt: []const u8, args: anytype) !QueryResult {
        const latency = elapsedMs(start);
        const err_msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        return QueryResult{
            .success = false,
            .latency_ms = latency,
            .error_message = err_msg,
            .result_data = null,
        };
    }

    /// Execute a GQL query (optionally with JSON-object parameters) and wait
    /// for the complete result (schema + all data pages).
    fn execute(self: *GeodeDriver, query: []const u8, params: ?std.json.Value) !QueryResult {
        if (!self.connected or self.client == null) return error.NotConnected;
        const client = &self.client.?;

        const start = compat.microTimestamp();

        self.request_counter += 1;

        var request = proto.ExecuteRequest{
            .session_id = client.session_id,
            .query = query,
            .request_id = try client.generateRequestId(),
        };
        defer request.deinit(self.allocator);

        if (params) |p| {
            if (p == .object) {
                var iter = p.object.iterator();
                while (iter.next()) |entry| {
                    const value: proto.Value = switch (entry.value_ptr.*) {
                        .string => |s| .{ .string_val = s },
                        .integer => |i| proto.Value.initInt(i),
                        .float => |f| proto.Value.initDouble(f),
                        .bool => |b| proto.Value.initBool(b),
                        else => proto.Value.initNull(),
                    };
                    try request.addParam(self.allocator, entry.key_ptr.*, value);
                }
            }
        }

        // Send EXECUTE message
        try client.sendProto(.{ .execute = request });

        var row_count: usize = 0;
        var column_count: usize = 0;
        var timeout_ms: u64 = self.db_config.timeout_ms;

        while (true) {
            var response = client.receiveProto(timeout_ms) catch |err| {
                return self.failure(start, "Timeout or error: {}", .{err});
            };
            defer response.deinit(self.allocator);

            const exec_resp: proto.ExecutionResponse = if (response.execute) |e|
                e
            else if (response.pull) |pull| blk: {
                if (pull.response) |e| break :blk e;
                break;
            } else {
                return self.failure(start, "Invalid response", .{});
            };

            // Check for ERROR response
            if (exec_resp.err) |e| {
                const msg = if (e.message.len > 0) e.message else "Unknown error";
                return self.failure(start, "{s}", .{msg});
            }

            if (exec_resp.schema) |schema| column_count = schema.columns.items.len;

            if (exec_resp.page) |page| {
                row_count += page.rows.items.len;
                if (page.final) break;
            } else if (exec_resp.schema == null) {
                // Status-only responses (e.g. CREATE/UPDATE) complete on the first frame.
                break;
            }

            // Follow-up frames for the same query should arrive quickly.
            timeout_ms = @min(timeout_ms, 5000);
        }

        const latency = elapsedMs(start);
        const result_data = try std.fmt.allocPrint(
            self.allocator,
            "{{\"columns\":{d},\"rows\":{d}}}",
            .{ column_count, row_count },
        );

        return QueryResult{
            .success = true,
            .latency_ms = latency,
            .error_message = null,
            .result_data = result_data,
        };
    }

    pub fn deinit(self: *GeodeDriver) void {
        self.disconnect();
    }
};

// Legacy alias for backwards compatibility
pub const QuicDriver = GeodeDriver;

// ============================================================================
// Unit Tests
// ============================================================================

test "QueryResult struct" {
    const allocator = std.testing.allocator;

    // Test successful result
    var result = QueryResult{
        .success = true,
        .latency_ms = 5.5,
        .error_message = null,
        .result_data = try allocator.dupe(u8, "{\"data\": \"test\"}"),
    };
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(f64, 5.5), result.latency_ms);
    try std.testing.expect(result.error_message == null);
    try std.testing.expect(result.result_data != null);
}

test "QueryResult with error" {
    const allocator = std.testing.allocator;

    var result = QueryResult{
        .success = false,
        .latency_ms = 10.0,
        .error_message = try allocator.dupe(u8, "Connection timeout"),
        .result_data = null,
    };
    defer result.deinit(allocator);

    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("Connection timeout", result.error_message.?);
    try std.testing.expect(result.result_data == null);
}

test "GeodeDriver init" {
    const allocator = std.testing.allocator;

    const db_cfg = config.DbConfig{
        .host = "localhost",
        .port = 3141,
        .transport = .quic_tls_insecure,
        .auth_token_env = null,
        .timeout_ms = 5000,
    };

    var drv = GeodeDriver.init(allocator, db_cfg);
    defer drv.deinit();

    try std.testing.expect(!drv.connected);
    try std.testing.expect(drv.client == null);
    try std.testing.expectEqual(@as(u64, 0), drv.request_counter);
    try std.testing.expectEqual(@as(u16, 3141), drv.db_config.port);
}

test "GeodeDriver QuicDriver alias" {
    // Verify the legacy alias works
    const allocator = std.testing.allocator;

    const db_cfg = config.DbConfig{
        .host = "127.0.0.1",
        .port = 8443,
        .transport = .quic_tls_strict,
        .auth_token_env = null,
        .timeout_ms = 10000,
    };

    var drv = QuicDriver.init(allocator, db_cfg);
    defer drv.deinit();

    try std.testing.expect(!drv.connected);
    try std.testing.expectEqual(@as(u16, 8443), drv.db_config.port);
}
