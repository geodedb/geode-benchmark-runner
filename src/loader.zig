// SPDX-License-Identifier: MIT
// Copyright (c) 2024-2025 CodePros
//
// Dataset loader using GeodeClient batch operations

const std = @import("std");
const geode = @import("geode_client");
const config = @import("config.zig");

pub const LoadReport = struct {
    dataset_id: []const u8,
    load_time_sec: f64,
    node_count: u64,
    edge_count: u64,
    batch_count: u64,
    errors: u64,

    pub fn deinit(_: *LoadReport, _: std.mem.Allocator) void {}
};

pub const Loader = struct {
    allocator: std.mem.Allocator,
    loader_config: config.LoaderConfig,
    client: ?geode.GeodeClient,
    connected: bool,

    pub fn init(allocator: std.mem.Allocator, loader_config: config.LoaderConfig) Loader {
        return Loader{
            .allocator = allocator,
            .loader_config = loader_config,
            .client = null,
            .connected = false,
        };
    }

    pub fn connect(self: *Loader, db_config: config.DbConfig) !void {
        const insecure = db_config.transport == .quic_tls_insecure;

        var client = geode.GeodeClient.init(
            self.allocator,
            db_config.host,
            db_config.port,
            insecure,
        );

        try client.connect();
        try client.sendHello("graphbench-loader", "0.2.0");

        const hello_response = try client.receiveMessage(5000);
        defer self.allocator.free(hello_response);

        self.client = client;
        self.connected = true;

        std.debug.print("Loader connected to {s}:{d}\n", .{ db_config.host, db_config.port });
    }

    pub fn disconnect(self: *Loader) void {
        if (self.connected and self.client != null) {
            self.client.?.deinit();
            self.client = null;
            self.connected = false;
        }
    }

    pub fn deinit(self: *Loader) void {
        self.disconnect();
    }

    pub fn loadDatasetFromDir(self: *Loader, workdir: []const u8) !LoadReport {
        if (!self.connected or self.client == null) return error.NotConnected;

        const start = std.time.milliTimestamp();

        var node_count: u64 = 0;
        var edge_count: u64 = 0;
        var batch_count: u64 = 0;
        var errors: u64 = 0;

        // Load nodes
        const nodes_dir = try std.fs.path.join(self.allocator, &[_][]const u8{ workdir, "nodes" });
        defer self.allocator.free(nodes_dir);

        const nodes_result = self.loadNodesFromDir(nodes_dir) catch |err| {
            std.debug.print("Error loading nodes: {}\n", .{err});
            return LoadReport{
                .dataset_id = "",
                .load_time_sec = 0,
                .node_count = 0,
                .edge_count = 0,
                .batch_count = 0,
                .errors = 1,
            };
        };
        node_count = nodes_result.count;
        batch_count += nodes_result.batches;
        errors += nodes_result.errors;

        // Load edges
        const edges_dir = try std.fs.path.join(self.allocator, &[_][]const u8{ workdir, "edges" });
        defer self.allocator.free(edges_dir);

        const edges_result = self.loadEdgesFromDir(edges_dir) catch |err| {
            std.debug.print("Error loading edges: {}\n", .{err});
            return LoadReport{
                .dataset_id = "",
                .load_time_sec = 0,
                .node_count = node_count,
                .edge_count = 0,
                .batch_count = batch_count,
                .errors = errors + 1,
            };
        };
        edge_count = edges_result.count;
        batch_count += edges_result.batches;
        errors += edges_result.errors;

        const end = std.time.milliTimestamp();
        const duration = @as(f64, @floatFromInt(end - start)) / 1000.0;

        std.debug.print("Load complete: {d} nodes, {d} edges in {d:.2}s ({d} batches, {d} errors)\n", .{
            node_count,
            edge_count,
            duration,
            batch_count,
            errors,
        });

        return LoadReport{
            .dataset_id = "",
            .load_time_sec = duration,
            .node_count = node_count,
            .edge_count = edge_count,
            .batch_count = batch_count,
            .errors = errors,
        };
    }

    const LoadResult = struct {
        count: u64,
        batches: u64,
        errors: u64,
    };

    fn loadNodesFromDir(self: *Loader, dir_path: []const u8) !LoadResult {
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) {
                return LoadResult{ .count = 0, .batches = 0, .errors = 0 };
            }
            return err;
        };
        defer dir.close();

        var total_count: u64 = 0;
        var total_batches: u64 = 0;
        var total_errors: u64 = 0;

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;

            // Extract label from filename (e.g., "Person.jsonl" -> "Person")
            const label = entry.name[0 .. entry.name.len - 6];

            const result = try self.loadNodesFromFile(dir, entry.name, label);
            total_count += result.count;
            total_batches += result.batches;
            total_errors += result.errors;

            std.debug.print("  Loaded {d} {s} nodes\n", .{ result.count, label });
        }

        return LoadResult{
            .count = total_count,
            .batches = total_batches,
            .errors = total_errors,
        };
    }

    fn loadNodesFromFile(self: *Loader, dir: std.fs.Dir, filename: []const u8, label: []const u8) !LoadResult {
        const file = try dir.openFile(filename, .{});
        defer file.close();

        var count: u64 = 0;
        var batches: u64 = 0;
        var errors_count: u64 = 0;

        var batch = std.ArrayList([]const u8){};
        defer {
            for (batch.items) |item| self.allocator.free(item);
            batch.deinit(self.allocator);
        }

        const reader = file.deprecatedReader();
        var line_buf: [16384]u8 = undefined;

        while (reader.readUntilDelimiterOrEof(&line_buf, '\n')) |maybe_line| {
            const line = maybe_line orelse break;
            if (line.len == 0) continue;

            // Parse JSON line to extract properties
            const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch continue;
            defer parsed.deinit();

            // Build CREATE statement
            const query = try buildCreateNodeQuery(self.allocator, label, parsed.value);
            try batch.append(self.allocator, query);
            count += 1;

            // Execute batch when it reaches batch size
            if (batch.items.len >= self.loader_config.batch_size) {
                const batch_errors = try self.executeBatch(batch.items);
                errors_count += batch_errors;
                batches += 1;

                // Clear batch
                for (batch.items) |item| self.allocator.free(item);
                batch.clearRetainingCapacity();
            }
        } else |err| {
            std.debug.print("Error reading line: {}\n", .{err});
        }

        // Execute remaining items
        if (batch.items.len > 0) {
            const batch_errors = try self.executeBatch(batch.items);
            errors_count += batch_errors;
            batches += 1;
        }

        return LoadResult{
            .count = count,
            .batches = batches,
            .errors = errors_count,
        };
    }

    fn loadEdgesFromDir(self: *Loader, dir_path: []const u8) !LoadResult {
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) {
                return LoadResult{ .count = 0, .batches = 0, .errors = 0 };
            }
            return err;
        };
        defer dir.close();

        var total_count: u64 = 0;
        var total_batches: u64 = 0;
        var total_errors: u64 = 0;

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;

            // Extract relationship type from filename
            const rel_type = entry.name[0 .. entry.name.len - 6];

            const result = try self.loadEdgesFromFile(dir, entry.name, rel_type);
            total_count += result.count;
            total_batches += result.batches;
            total_errors += result.errors;

            std.debug.print("  Loaded {d} {s} edges\n", .{ result.count, rel_type });
        }

        return LoadResult{
            .count = total_count,
            .batches = total_batches,
            .errors = total_errors,
        };
    }

    fn loadEdgesFromFile(self: *Loader, dir: std.fs.Dir, filename: []const u8, rel_type: []const u8) !LoadResult {
        const file = try dir.openFile(filename, .{});
        defer file.close();

        var count: u64 = 0;
        var batches: u64 = 0;
        var errors_count: u64 = 0;

        var batch = std.ArrayList([]const u8){};
        defer {
            for (batch.items) |item| self.allocator.free(item);
            batch.deinit(self.allocator);
        }

        const reader = file.deprecatedReader();
        var line_buf: [16384]u8 = undefined;

        while (reader.readUntilDelimiterOrEof(&line_buf, '\n')) |maybe_line| {
            const line = maybe_line orelse break;
            if (line.len == 0) continue;

            // Parse JSON line
            const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch continue;
            defer parsed.deinit();

            // Build CREATE relationship statement
            const query = try buildCreateEdgeQuery(self.allocator, rel_type, parsed.value);
            try batch.append(self.allocator, query);
            count += 1;

            // Execute batch when it reaches batch size
            if (batch.items.len >= self.loader_config.batch_size) {
                const batch_errors = try self.executeBatch(batch.items);
                errors_count += batch_errors;
                batches += 1;

                // Clear batch
                for (batch.items) |item| self.allocator.free(item);
                batch.clearRetainingCapacity();
            }
        } else |err| {
            std.debug.print("Error reading line: {}\n", .{err});
        }

        // Execute remaining items
        if (batch.items.len > 0) {
            const batch_errors = try self.executeBatch(batch.items);
            errors_count += batch_errors;
            batches += 1;
        }

        return LoadResult{
            .count = count,
            .batches = batches,
            .errors = errors_count,
        };
    }

    fn executeBatch(self: *Loader, queries: []const []const u8) !u64 {
        if (self.client == null) return error.NotConnected;

        var errors: u64 = 0;

        // Execute queries individually (could be optimized with batch protocol)
        for (queries) |query| {
            const request_id = @as(u64, @intCast(std.time.milliTimestamp()));

            self.client.?.sendRunGql(request_id, query, null) catch |err| {
                std.debug.print("Send error: {}\n", .{err});
                errors += 1;
                continue;
            };

            const response = self.client.?.receiveMessage(30000) catch |err| {
                std.debug.print("Receive error: {}\n", .{err});
                errors += 1;
                continue;
            };
            defer self.allocator.free(response);

            // Check for error in response
            const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response, .{}) catch {
                errors += 1;
                continue;
            };
            defer parsed.deinit();

            if (parsed.value.object.get("type")) |type_val| {
                if (type_val == .string and std.mem.eql(u8, type_val.string, "ERROR")) {
                    errors += 1;
                }
            }
        }

        return errors;
    }
};

fn buildCreateNodeQuery(allocator: std.mem.Allocator, label: []const u8, json: std.json.Value) ![]const u8 {
    var props = std.ArrayList(u8){};
    defer props.deinit(allocator);

    try props.appendSlice(allocator, "{");

    var first = true;
    if (json.object.count() > 0) {
        var iter = json.object.iterator();
        while (iter.next()) |entry| {
            if (!first) try props.appendSlice(allocator, ", ");
            first = false;

            try props.writer(allocator).print("{s}: ", .{entry.key_ptr.*});

            switch (entry.value_ptr.*) {
                .string => |s| try props.writer(allocator).print("'{s}'", .{s}),
                .integer => |i| try props.writer(allocator).print("{d}", .{i}),
                .float => |f| try props.writer(allocator).print("{d}", .{f}),
                .bool => |b| try props.writer(allocator).print("{}", .{b}),
                .null => try props.appendSlice(allocator, "null"),
                else => try props.appendSlice(allocator, "null"),
            }
        }
    }

    try props.appendSlice(allocator, "}");

    return try std.fmt.allocPrint(allocator, "CREATE (n:{s} {s})", .{ label, props.items });
}

fn buildCreateEdgeQuery(allocator: std.mem.Allocator, rel_type: []const u8, json: std.json.Value) ![]const u8 {
    // Get source and destination IDs (can be string or integer)
    const src_val = json.object.get("src") orelse return error.MissingSrc;
    const dst_val = json.object.get("dst") orelse return error.MissingDst;

    // Get labels if present (for FinBench format)
    const src_label = if (json.object.get("src_label")) |v| v.string else null;
    const dst_label = if (json.object.get("dst_label")) |v| v.string else null;

    // Get relationship type from JSON if present, otherwise use filename-derived type
    const edge_type = if (json.object.get("type")) |v| v.string else rel_type;

    // Build properties if any (excluding src/dst/labels/type metadata)
    var props = std.ArrayList(u8){};
    defer props.deinit(allocator);

    try props.appendSlice(allocator, "{");

    var first = true;
    var iter = json.object.iterator();
    while (iter.next()) |entry| {
        // Skip metadata fields
        if (std.mem.eql(u8, entry.key_ptr.*, "src") or
            std.mem.eql(u8, entry.key_ptr.*, "dst") or
            std.mem.eql(u8, entry.key_ptr.*, "src_label") or
            std.mem.eql(u8, entry.key_ptr.*, "dst_label") or
            std.mem.eql(u8, entry.key_ptr.*, "type"))
        {
            continue;
        }

        if (!first) try props.appendSlice(allocator, ", ");
        first = false;

        try props.writer(allocator).print("{s}: ", .{entry.key_ptr.*});

        switch (entry.value_ptr.*) {
            .string => |s| try props.writer(allocator).print("'{s}'", .{s}),
            .integer => |i| try props.writer(allocator).print("{d}", .{i}),
            .float => |f| try props.writer(allocator).print("{d}", .{f}),
            .bool => |b| try props.writer(allocator).print("{}", .{b}),
            .null => try props.appendSlice(allocator, "null"),
            else => try props.appendSlice(allocator, "null"),
        }
    }

    try props.appendSlice(allocator, "}");

    const props_str = if (props.items.len > 2) props.items else "";

    // Format src/dst values based on type
    var src_str: []const u8 = undefined;
    var dst_str: []const u8 = undefined;
    var src_buf: [32]u8 = undefined;
    var dst_buf: [32]u8 = undefined;

    switch (src_val) {
        .string => |s| src_str = s,
        .integer => |i| {
            src_str = std.fmt.bufPrint(&src_buf, "{d}", .{i}) catch return error.InvalidSrcType;
        },
        else => return error.InvalidSrcType,
    }

    switch (dst_val) {
        .string => |s| dst_str = s,
        .integer => |i| {
            dst_str = std.fmt.bufPrint(&dst_buf, "{d}", .{i}) catch return error.InvalidDstType;
        },
        else => return error.InvalidDstType,
    }

    // Build MATCH clause with labels if available
    if (src_label != null and dst_label != null) {
        return try std.fmt.allocPrint(
            allocator,
            "MATCH (a:{s} {{id: {s}}}), (b:{s} {{id: {s}}}) CREATE (a)-[:{s} {s}]->(b)",
            .{ src_label.?, src_str, dst_label.?, dst_str, edge_type, props_str },
        );
    } else {
        return try std.fmt.allocPrint(
            allocator,
            "MATCH (a {{id: {s}}}), (b {{id: {s}}}) CREATE (a)-[:{s} {s}]->(b)",
            .{ src_str, dst_str, edge_type, props_str },
        );
    }
}

pub fn loadDataset(
    allocator: std.mem.Allocator,
    config_path: []const u8,
    dataset_id: []const u8,
    workdir: []const u8,
) !void {
    std.debug.print("Loading dataset '{s}' from {s}\n", .{ dataset_id, workdir });

    var cfg = try config.loadConfig(allocator, config_path);
    defer cfg.deinit();

    if (cfg.loader == null) {
        std.debug.print("No loader configured\n", .{});
        return error.NoLoader;
    }

    var ldr = Loader.init(allocator, cfg.loader.?);
    defer ldr.deinit();

    try ldr.connect(cfg.db);

    var report = try ldr.loadDatasetFromDir(workdir);
    defer report.deinit(allocator);

    std.debug.print("\nLoad complete:\n", .{});
    std.debug.print("  Dataset: {s}\n", .{dataset_id});
    std.debug.print("  Duration: {d:.2}s\n", .{report.load_time_sec});
    std.debug.print("  Nodes: {d}\n", .{report.node_count});
    std.debug.print("  Edges: {d}\n", .{report.edge_count});
    std.debug.print("  Batches: {d}\n", .{report.batch_count});
    std.debug.print("  Errors: {d}\n", .{report.errors});
}
