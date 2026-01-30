// SPDX-License-Identifier: MIT
// Copyright (c) 2024-2025 CodePros
//
// Benchmark runner with multi-threaded worker pools

const std = @import("std");
const config = @import("config.zig");
const driver = @import("driver.zig");
const stats = @import("stats.zig");
const output = @import("output.zig");
const benchpack = @import("benchpack.zig");

const WorkerContext = struct {
    allocator: std.mem.Allocator,
    worker_id: u32,
    db_config: config.DbConfig,
    pack: benchpack.BenchPack,
    slo_ms: u32,
    duration_ms: i64,
    start_time: i64,

    // Shared state (protected by mutex in parent)
    latencies: *std.ArrayList(f64),
    errors: *u64,
    violations: *u64,
    total_requests: *u64,
    mutex: *std.Thread.Mutex,
};

fn workerThread(ctx: *WorkerContext) void {
    var db_driver = driver.GeodeDriver.init(ctx.allocator, ctx.db_config);
    defer db_driver.deinit();

    db_driver.connect() catch |err| {
        std.debug.print("[Worker {}] Connection failed: {}\n", .{ ctx.worker_id, err });
        ctx.mutex.lock();
        ctx.errors.* += 1;
        ctx.mutex.unlock();
        return;
    };

    var rng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp() +% ctx.worker_id));
    const end_time = ctx.start_time +| ctx.duration_ms; // Saturating add to prevent overflow
    var request_id: u64 = @as(u64, ctx.worker_id) * 1_000_000;

    while (std.time.milliTimestamp() < end_time) {
        // Pick random operation based on weights
        const op_idx = selectOperation(ctx.pack.operations, &rng);
        const op = ctx.pack.operations[op_idx];

        request_id += 1;

        // Build parameterized query params as JSON
        var params = buildQueryParams(ctx.allocator, op.query, request_id, &rng) catch null;
        defer if (params) |*p| {
            // Clean up allocated strings in params
            freeJsonParams(ctx.allocator, p);
        };

        // Execute with parameterized query (secure against injection)
        var result = if (params) |p|
            db_driver.execWithParams(op.query, p) catch |err| blk: {
                std.debug.print("[Worker {}] Query error: {}\n", .{ ctx.worker_id, err });
                ctx.mutex.lock();
                ctx.errors.* += 1;
                ctx.mutex.unlock();
                break :blk null;
            }
        else
            db_driver.exec(op.query, null) catch |err| blk: {
                std.debug.print("[Worker {}] Query error: {}\n", .{ ctx.worker_id, err });
                ctx.mutex.lock();
                ctx.errors.* += 1;
                ctx.mutex.unlock();
                break :blk null;
            };

        if (result) |*res| {
            defer res.deinit(ctx.allocator);

            if (!res.success) {
                ctx.mutex.lock();
                ctx.errors.* += 1;
                ctx.mutex.unlock();

                if (res.error_message) |msg| {
                    std.debug.print("[Worker {}] Query failed: {s}\n", .{ ctx.worker_id, msg });
                }
            } else {
                ctx.mutex.lock();
                defer ctx.mutex.unlock();

                ctx.latencies.append(ctx.allocator, res.latency_ms) catch {};

                if (res.latency_ms > @as(f64, @floatFromInt(ctx.slo_ms))) {
                    ctx.violations.* += 1;
                }
            }

            ctx.mutex.lock();
            ctx.total_requests.* += 1;
            ctx.mutex.unlock();
        }

        // Small delay to avoid overwhelming
        std.posix.nanosleep(0, 1 * std.time.ns_per_ms);
    }
}

fn selectOperation(operations: []const benchpack.BenchPack.Operation, rng: *std.Random.DefaultPrng) usize {
    // Calculate total weight
    var total_weight: f64 = 0;
    for (operations) |op| {
        total_weight += op.weight;
    }

    // Select based on weight
    var target = rng.random().float(f64) * total_weight;
    for (operations, 0..) |op, i| {
        target -= op.weight;
        if (target <= 0) {
            return i;
        }
    }

    return operations.len - 1;
}

/// Build query parameters as a JSON object for parameterized queries.
/// Returns null if the query has no recognized parameters.
/// This is the secure way to pass values - prevents injection attacks.
fn buildQueryParams(allocator: std.mem.Allocator, query: []const u8, request_id: u64, rng: *std.Random.DefaultPrng) !?std.json.Value {
    // Scan for $param placeholders
    var has_params = false;
    var i: usize = 0;
    while (i < query.len) : (i += 1) {
        if (i + 1 < query.len and query[i] == '$' and std.ascii.isAlphabetic(query[i + 1])) {
            has_params = true;
            break;
        }
    }

    if (!has_params) return null;

    // Build parameter map
    var params = std.json.ObjectMap.init(allocator);
    errdefer params.deinit();

    // Scan and add each parameter found in the query
    i = 0;
    while (i < query.len) {
        if (i + 1 < query.len and query[i] == '$') {
            const start = i + 1;
            var end = start;
            while (end < query.len and (std.ascii.isAlphanumeric(query[end]) or query[end] == '_')) {
                end += 1;
            }

            if (end > start) {
                const param_name = query[start..end];
                const key = try allocator.dupe(u8, param_name);

                // Generate value based on parameter name
                if (std.mem.eql(u8, param_name, "id")) {
                    const id = rng.random().intRangeAtMost(u32, 1, 1000);
                    try params.put(key, .{ .integer = @intCast(id) });
                } else if (std.mem.eql(u8, param_name, "src")) {
                    const id = rng.random().intRangeAtMost(u32, 1, 500);
                    try params.put(key, .{ .integer = @intCast(id) });
                } else if (std.mem.eql(u8, param_name, "dst")) {
                    const id = rng.random().intRangeAtMost(u32, 501, 1000);
                    try params.put(key, .{ .integer = @intCast(id) });
                } else if (std.mem.eql(u8, param_name, "min_age")) {
                    const age = rng.random().intRangeAtMost(u32, 18, 65);
                    try params.put(key, .{ .integer = @intCast(age) });
                } else if (std.mem.eql(u8, param_name, "name")) {
                    const name_str = try std.fmt.allocPrint(allocator, "test_{d}", .{request_id});
                    try params.put(key, .{ .string = name_str });
                } else if (std.mem.eql(u8, param_name, "ts")) {
                    try params.put(key, .{ .integer = std.time.milliTimestamp() });
                } else if (std.mem.eql(u8, param_name, "weight")) {
                    const weight = rng.random().float(f64);
                    try params.put(key, .{ .float = weight });
                } else {
                    // Unknown parameter - free the key since we won't use it
                    allocator.free(key);
                }

                i = end;
                continue;
            }
        }
        i += 1;
    }

    if (params.count() == 0) {
        params.deinit();
        return null;
    }

    return .{ .object = params };
}

/// Free allocated strings in JSON params object
fn freeJsonParams(allocator: std.mem.Allocator, params: *std.json.Value) void {
    if (params.* == .object) {
        var iter = params.object.iterator();
        while (iter.next()) |entry| {
            // Free the key
            allocator.free(entry.key_ptr.*);
            // Free string values
            if (entry.value_ptr.* == .string) {
                allocator.free(entry.value_ptr.string);
            }
        }
        params.object.deinit();
    }
}

pub fn executeBenchmark(
    allocator: std.mem.Allocator,
    config_path: []const u8,
    out_dir: []const u8,
    workers_override: ?u32,
    duration_override: ?u32,
) !void {
    std.debug.print("Running benchmark: {s} -> {s}\n", .{ config_path, out_dir });

    var cfg = try config.loadConfig(allocator, config_path);
    defer cfg.deinit();

    try std.fs.cwd().makePath(out_dir);

    std.debug.print("Connecting to {s}:{d} (transport={s})\n", .{
        cfg.db.host,
        cfg.db.port,
        @tagName(cfg.db.transport),
    });

    // Test connection first
    var test_driver = driver.GeodeDriver.init(allocator, cfg.db);
    defer test_driver.deinit();

    try test_driver.connect();
    std.debug.print("Connected successfully\n", .{});

    // Load benchmark pack
    var pack = try benchpack.loadBenchpack(allocator, "benchpacks", cfg.workload.benchpack);
    defer pack.deinit(allocator);

    const duration_sec = duration_override orelse cfg.workload.duration_sec orelse 30;
    const workers = workers_override orelse cfg.workload.workers orelse 4;
    const in_flight = cfg.workload.in_flight_per_worker orelse 10;

    std.debug.print("Running for {d}s with {d} workers, {d} in-flight each\n", .{ duration_sec, workers, in_flight });
    std.debug.print("Benchmark pack: {s} ({d} operations)\n", .{ pack.name, pack.operations.len });

    // Shared state
    var latencies = std.ArrayList(f64){};
    defer latencies.deinit(allocator);

    var errors: u64 = 0;
    var violations: u64 = 0;
    var total_requests: u64 = 0;
    var mutex = std.Thread.Mutex{};

    const start_time = std.time.milliTimestamp();
    const duration_ms: i64 = @intCast(duration_sec * 1000);

    // Pre-allocate contexts to avoid reallocation during thread spawn
    // (reallocation would invalidate pointers passed to already-running threads)
    const contexts = try allocator.alloc(WorkerContext, workers);
    defer allocator.free(contexts);

    for (contexts, 0..) |*ctx, idx| {
        ctx.* = WorkerContext{
            .allocator = allocator,
            .worker_id = @intCast(idx),
            .db_config = cfg.db,
            .pack = pack,
            .slo_ms = cfg.workload.slo_ms,
            .duration_ms = duration_ms,
            .start_time = start_time,
            .latencies = &latencies,
            .errors = &errors,
            .violations = &violations,
            .total_requests = &total_requests,
            .mutex = &mutex,
        };
    }

    // Now spawn threads - contexts won't move
    var threads = std.ArrayList(std.Thread){};
    defer threads.deinit(allocator);

    for (contexts, 0..) |*ctx, idx| {
        const thread = try std.Thread.spawn(.{}, workerThread, .{ctx});
        try threads.append(allocator, thread);

        // Stagger worker startup to avoid QUIC endpoint initialization race
        if (idx + 1 < workers) {
            std.Thread.sleep(50 * std.time.ns_per_ms);
        }
    }

    // Wait for all workers to complete
    for (threads.items) |thread| {
        thread.join();
    }

    const actual_duration = @as(f64, @floatFromInt(std.time.milliTimestamp() - start_time)) / 1000.0;
    const qps = @as(f64, @floatFromInt(total_requests)) / actual_duration;

    if (latencies.items.len == 0) {
        std.debug.print("No successful queries! Errors: {d}\n", .{errors});
        return error.NoSuccessfulQueries;
    }

    const percentiles = stats.Percentiles.compute(latencies.items);

    const error_rate = @as(f64, @floatFromInt(errors)) / @as(f64, @floatFromInt(total_requests));
    const violation_rate = @as(f64, @floatFromInt(violations)) / @as(f64, @floatFromInt(latencies.items.len));

    const metrics = stats.RunMetrics{
        .qps = qps,
        .latency = percentiles,
        .error_rate = error_rate,
        .violation_rate = violation_rate,
        .tail_amplification = stats.RunMetrics.computeTailAmplification(percentiles),
        .qps_ceiling_est_from_p50 = stats.RunMetrics.computeQpsCeiling(workers * in_flight, percentiles.p50),
        .required_in_flight = stats.RunMetrics.computeRequiredInFlight(qps, percentiles.p50),
    };

    var validity = try stats.ValidityCheck.check(
        allocator,
        metrics,
        @floatFromInt(cfg.workload.slo_ms),
        cfg.workload.violation_threshold,
        cfg.workload.error_threshold,
    );
    defer validity.deinit(allocator);

    // Write outputs
    try output.writeResults(allocator, out_dir, cfg, metrics, validity);
    try output.writeMeta(allocator, out_dir, cfg);
    try output.writeSummary(allocator, out_dir, cfg, metrics, validity);

    std.debug.print("\nBenchmark complete!\n", .{});
    std.debug.print("  QPS: {d:.2}, p50: {d:.2}ms, p95: {d:.2}ms, p99: {d:.2}ms\n", .{
        metrics.qps,
        percentiles.p50,
        percentiles.p95,
        percentiles.p99,
    });
    std.debug.print("  Valid: {}, Errors: {d}, Violations: {d}\n", .{ validity.is_valid, errors, violations });
}

pub fn executeSweep(
    allocator: std.mem.Allocator,
    config_path: []const u8,
    out_dir: []const u8,
) !void {
    std.debug.print("Running sweep: {s} -> {s}\n", .{ config_path, out_dir });

    var sweep_cfg = try config.loadSweepConfig(allocator, config_path);
    defer sweep_cfg.deinit();

    try std.fs.cwd().makePath(out_dir);

    var best_qps: f64 = 0;
    var best_value: u32 = 0;
    var best_valid = false;

    // Test connection once
    var test_driver = driver.GeodeDriver.init(allocator, sweep_cfg.base.db);
    test_driver.connect() catch |err| {
        std.debug.print("Connection failed: {}. Skipping sweep.\n", .{err});
        return err;
    };
    test_driver.deinit();

    std.debug.print("Testing parameter: {s}\n", .{sweep_cfg.sweep.parameter});
    std.debug.print("Values: ", .{});
    for (sweep_cfg.sweep.values) |v| {
        std.debug.print("{d} ", .{v});
    }
    std.debug.print("\n\n", .{});

    for (sweep_cfg.sweep.values) |value| {
        std.debug.print("=== Sweep point: {s}={d} ===\n", .{ sweep_cfg.sweep.parameter, value });

        // Create modified config for this sweep point
        var point_cfg = try config.loadConfig(allocator, config_path);
        defer point_cfg.deinit();

        // Modify the parameter
        if (std.mem.eql(u8, sweep_cfg.sweep.parameter, "in_flight_per_worker")) {
            point_cfg.workload.in_flight_per_worker = value;
        } else if (std.mem.eql(u8, sweep_cfg.sweep.parameter, "workers")) {
            point_cfg.workload.workers = value;
        }

        // Create point directory
        const point_dir = try std.fmt.allocPrint(allocator, "{s}/point_{d}", .{ out_dir, value });
        defer allocator.free(point_dir);

        // Execute benchmark for this point
        executeBenchmark(allocator, config_path, point_dir, point_cfg.workload.workers, point_cfg.workload.duration_sec) catch |err| {
            std.debug.print("Sweep point failed: {}\n\n", .{err});
            continue;
        };

        // Read results
        const result_path = try std.fmt.allocPrint(allocator, "{s}/result.json", .{point_dir});
        defer allocator.free(result_path);

        const result_file = std.fs.cwd().openFile(result_path, .{}) catch continue;
        defer result_file.close();

        const result_content = result_file.readToEndAlloc(allocator, 1024 * 1024) catch continue;
        defer allocator.free(result_content);

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, result_content, .{}) catch continue;
        defer parsed.deinit();

        const point_qps = parsed.value.object.get("qps").?.float;
        const point_valid = parsed.value.object.get("valid").?.bool;

        std.debug.print("  Result: QPS={d:.2}, Valid={}\n\n", .{ point_qps, point_valid });

        // Update best if this is better (only among valid runs)
        if (point_valid and point_qps > best_qps) {
            best_qps = point_qps;
            best_value = value;
            best_valid = true;
        }
    }

    std.debug.print("\n=== Sweep complete ===\n", .{});
    if (best_valid) {
        std.debug.print("Best valid result: {s}={d} -> {d:.2} QPS\n", .{
            sweep_cfg.sweep.parameter,
            best_value,
            best_qps,
        });
    } else {
        std.debug.print("No valid results found!\n", .{});
    }

    // Write sweep.json
    try output.writeSweepResults(allocator, out_dir, best_value, best_qps);
}

// ============================================================================
// Unit Tests
// ============================================================================

test "selectOperation - single operation" {
    var rng = std.Random.DefaultPrng.init(12345);

    const ops = [_]benchpack.BenchPack.Operation{
        .{ .name = "op1", .query = "MATCH (n) RETURN n", .weight = 1.0, .slo_ms = 100, .params = null },
    };

    // With only one operation, should always return 0
    const idx = selectOperation(&ops, &rng);
    try std.testing.expectEqual(@as(usize, 0), idx);
}

test "selectOperation - weighted selection" {
    var rng = std.Random.DefaultPrng.init(42);

    const ops = [_]benchpack.BenchPack.Operation{
        .{ .name = "heavy", .query = "Q1", .weight = 100.0, .slo_ms = 100, .params = null },
        .{ .name = "light", .query = "Q2", .weight = 1.0, .slo_ms = 100, .params = null },
    };

    // Run multiple times and count selections
    var heavy_count: usize = 0;
    var light_count: usize = 0;

    for (0..100) |_| {
        const idx = selectOperation(&ops, &rng);
        if (idx == 0) {
            heavy_count += 1;
        } else {
            light_count += 1;
        }
    }

    // Heavy should be selected much more often (~99x vs 1x)
    try std.testing.expect(heavy_count > light_count * 5);
}

test "buildQueryParams - no parameters" {
    const allocator = std.testing.allocator;
    var rng = std.Random.DefaultPrng.init(999);

    // Query without $placeholders
    const params = try buildQueryParams(allocator, "MATCH (n) RETURN n", 1, &rng);
    try std.testing.expect(params == null);
}

test "buildQueryParams - with id parameter" {
    const allocator = std.testing.allocator;
    var rng = std.Random.DefaultPrng.init(888);

    var params = try buildQueryParams(allocator, "MATCH (n {id: $id}) RETURN n", 1, &rng);
    try std.testing.expect(params != null);

    if (params) |*p| {
        defer freeJsonParams(allocator, p);
        try std.testing.expect(p.* == .object);
        try std.testing.expect(p.object.get("id") != null);
    }
}

test "buildQueryParams - multiple parameters" {
    const allocator = std.testing.allocator;
    var rng = std.Random.DefaultPrng.init(777);

    var params = try buildQueryParams(allocator, "MATCH (a {id: $src})-[]->(b {id: $dst}) RETURN a, b", 100, &rng);
    try std.testing.expect(params != null);

    if (params) |*p| {
        defer freeJsonParams(allocator, p);
        try std.testing.expect(p.object.get("src") != null);
        try std.testing.expect(p.object.get("dst") != null);
    }
}

test "buildQueryParams - name parameter generates string" {
    const allocator = std.testing.allocator;
    var rng = std.Random.DefaultPrng.init(666);

    var params = try buildQueryParams(allocator, "MATCH (p {name: $name}) RETURN p", 42, &rng);
    try std.testing.expect(params != null);

    if (params) |*p| {
        defer freeJsonParams(allocator, p);
        const name_val = p.object.get("name");
        try std.testing.expect(name_val != null);
        try std.testing.expect(name_val.? == .string);
    }
}

test "freeJsonParams - cleanup" {
    const allocator = std.testing.allocator;

    // Build params manually to test cleanup
    var obj = std.json.ObjectMap.init(allocator);
    const key = try allocator.dupe(u8, "test_key");
    const str_val = try allocator.dupe(u8, "test_value");
    try obj.put(key, .{ .string = str_val });

    var params = std.json.Value{ .object = obj };

    // This should free all memory without leaking
    freeJsonParams(allocator, &params);
}

test "WorkerContext struct" {
    const allocator = std.testing.allocator;

    var latencies = std.ArrayList(f64){};
    defer latencies.deinit(allocator);

    var errors: u64 = 0;
    var violations: u64 = 0;
    var total_requests: u64 = 0;
    var mutex = std.Thread.Mutex{};

    const ops = [_]benchpack.BenchPack.Operation{};
    const pack = benchpack.BenchPack{
        .allocator = allocator,
        .name = "test_pack",
        .description = "Test",
        .operations = &ops,
    };

    const db_cfg = config.DbConfig{
        .host = "localhost",
        .port = 3141,
        .transport = .quic_tls_insecure,
        .auth_token_env = null,
        .timeout_ms = 5000,
    };

    const ctx = WorkerContext{
        .allocator = allocator,
        .worker_id = 1,
        .db_config = db_cfg,
        .pack = pack,
        .slo_ms = 100,
        .duration_ms = 1000,
        .start_time = 0,
        .latencies = &latencies,
        .errors = &errors,
        .violations = &violations,
        .total_requests = &total_requests,
        .mutex = &mutex,
    };

    try std.testing.expectEqual(@as(u32, 1), ctx.worker_id);
    try std.testing.expectEqual(@as(u32, 100), ctx.slo_ms);
}
