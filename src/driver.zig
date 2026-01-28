// SPDX-License-Identifier: MIT
// Copyright (c) 2024-2025 CodePros
//
// Geode database driver using geode-client-zig

const std = @import("std");
const geode = @import("geode_client");
const config = @import("config.zig");

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

        var client = geode.GeodeClient.init(
            self.allocator,
            self.db_config.host,
            self.db_config.port,
            insecure,
        );

        try client.connect();

        // Send HELLO message
        try client.sendHello("graphbench", "0.2.0");

        // Wait for HELLO response
        const hello_response = try client.receiveMessage(5000);
        defer self.allocator.free(hello_response);

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
        if (!self.connected or self.client == null) return error.NotConnected;

        const start = std.time.microTimestamp();

        // For now, use null params (full param support would require JSON conversion)
        _ = params;

        // Generate request ID
        self.request_counter += 1;
        const request_id = self.request_counter;

        // Send RUN_GQL message
        try self.client.?.sendRunGql(request_id, query, null);

        // Receive SCHEMA response first
        const schema_response = self.client.?.receiveMessage(self.db_config.timeout_ms) catch |err| {
            const end = std.time.microTimestamp();
            const latency = @as(f64, @floatFromInt(end - start)) / 1000.0;

            const err_msg = try std.fmt.allocPrint(self.allocator, "Timeout or error: {}", .{err});
            return QueryResult{
                .success = false,
                .latency_ms = latency,
                .error_message = err_msg,
                .result_data = null,
            };
        };
        defer self.allocator.free(schema_response);

        // Parse SCHEMA response to check for errors
        const schema_parsed = std.json.parseFromSlice(std.json.Value, self.allocator, schema_response, .{}) catch {
            const end = std.time.microTimestamp();
            const latency = @as(f64, @floatFromInt(end - start)) / 1000.0;
            const err_msg = try std.fmt.allocPrint(self.allocator, "Invalid JSON response", .{});
            return QueryResult{
                .success = false,
                .latency_ms = latency,
                .error_message = err_msg,
                .result_data = null,
            };
        };
        defer schema_parsed.deinit();

        // Check for ERROR response
        if (schema_parsed.value.object.get("result")) |result_val| {
            if (result_val.object.get("type")) |type_val| {
                if (type_val == .string and std.mem.eql(u8, type_val.string, "ERROR")) {
                    const end = std.time.microTimestamp();
                    const latency = @as(f64, @floatFromInt(end - start)) / 1000.0;
                    const err_msg_field = result_val.object.get("message");
                    const err_str = if (err_msg_field) |f| if (f == .string) f.string else "Unknown error" else "Unknown error";
                    const err_msg = try self.allocator.dupe(u8, err_str);
                    return QueryResult{
                        .success = false,
                        .latency_ms = latency,
                        .error_message = err_msg,
                        .result_data = null,
                    };
                }
            }
        }

        // Check if BINDINGS was already received (inline/buffered)
        if (try self.client.?.tryReceiveBufferedMessage()) |bindings_response| {
            const end = std.time.microTimestamp();
            const latency = @as(f64, @floatFromInt(end - start)) / 1000.0;

            return QueryResult{
                .success = true,
                .latency_ms = latency,
                .error_message = null,
                .result_data = bindings_response,
            };
        }

        // Send PULL to request BINDINGS
        try self.client.?.sendPull(request_id, 1000);

        // Receive BINDINGS response with actual data
        const bindings_response = self.client.?.receiveMessage(self.db_config.timeout_ms) catch |err| {
            const end = std.time.microTimestamp();
            const latency = @as(f64, @floatFromInt(end - start)) / 1000.0;

            const err_msg = try std.fmt.allocPrint(self.allocator, "Timeout waiting for BINDINGS: {}", .{err});
            return QueryResult{
                .success = false,
                .latency_ms = latency,
                .error_message = err_msg,
                .result_data = null,
            };
        };

        const end = std.time.microTimestamp();
        const latency = @as(f64, @floatFromInt(end - start)) / 1000.0;

        return QueryResult{
            .success = true,
            .latency_ms = latency,
            .error_message = null,
            .result_data = bindings_response,
        };
    }

    pub fn execWithParams(self: *GeodeDriver, query: []const u8, params: std.json.Value) !QueryResult {
        if (!self.connected or self.client == null) return error.NotConnected;

        const start = std.time.microTimestamp();

        self.request_counter += 1;
        const request_id = self.request_counter;

        // Send RUN_GQL message with params
        try self.client.?.sendRunGql(request_id, query, params);

        // Receive SCHEMA response first
        const schema_response = self.client.?.receiveMessage(self.db_config.timeout_ms) catch |err| {
            const end = std.time.microTimestamp();
            const latency = @as(f64, @floatFromInt(end - start)) / 1000.0;

            const err_msg = try std.fmt.allocPrint(self.allocator, "Timeout or error: {}", .{err});
            return QueryResult{
                .success = false,
                .latency_ms = latency,
                .error_message = err_msg,
                .result_data = null,
            };
        };
        defer self.allocator.free(schema_response);

        // Parse SCHEMA response to check for errors
        const schema_parsed = std.json.parseFromSlice(std.json.Value, self.allocator, schema_response, .{}) catch {
            const end = std.time.microTimestamp();
            const latency = @as(f64, @floatFromInt(end - start)) / 1000.0;
            const err_msg = try std.fmt.allocPrint(self.allocator, "Invalid JSON response", .{});
            return QueryResult{
                .success = false,
                .latency_ms = latency,
                .error_message = err_msg,
                .result_data = null,
            };
        };
        defer schema_parsed.deinit();

        // Check for ERROR response
        if (schema_parsed.value.object.get("result")) |result_val| {
            if (result_val.object.get("type")) |type_val| {
                if (type_val == .string and std.mem.eql(u8, type_val.string, "ERROR")) {
                    const end = std.time.microTimestamp();
                    const latency = @as(f64, @floatFromInt(end - start)) / 1000.0;
                    const err_msg_field = result_val.object.get("message");
                    const err_str = if (err_msg_field) |f| if (f == .string) f.string else "Unknown error" else "Unknown error";
                    const err_msg = try self.allocator.dupe(u8, err_str);
                    return QueryResult{
                        .success = false,
                        .latency_ms = latency,
                        .error_message = err_msg,
                        .result_data = null,
                    };
                }
            }
        }

        // Check if BINDINGS was already received (inline/buffered)
        if (try self.client.?.tryReceiveBufferedMessage()) |bindings_response| {
            const end = std.time.microTimestamp();
            const latency = @as(f64, @floatFromInt(end - start)) / 1000.0;

            return QueryResult{
                .success = true,
                .latency_ms = latency,
                .error_message = null,
                .result_data = bindings_response,
            };
        }

        // Send PULL to request BINDINGS
        try self.client.?.sendPull(request_id, 1000);

        // Receive BINDINGS response with actual data
        const bindings_response = self.client.?.receiveMessage(self.db_config.timeout_ms) catch |err| {
            const end = std.time.microTimestamp();
            const latency = @as(f64, @floatFromInt(end - start)) / 1000.0;

            const err_msg = try std.fmt.allocPrint(self.allocator, "Timeout waiting for BINDINGS: {}", .{err});
            return QueryResult{
                .success = false,
                .latency_ms = latency,
                .error_message = err_msg,
                .result_data = null,
            };
        };

        const end = std.time.microTimestamp();
        const latency = @as(f64, @floatFromInt(end - start)) / 1000.0;

        return QueryResult{
            .success = true,
            .latency_ms = latency,
            .error_message = null,
            .result_data = bindings_response,
        };
    }

    pub fn deinit(self: *GeodeDriver) void {
        self.disconnect();
    }
};

// Legacy alias for backwards compatibility
pub const QuicDriver = GeodeDriver;
