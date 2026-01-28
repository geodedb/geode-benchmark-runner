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

        // Substitute parameters in query
        const query = substituteParams(ctx.allocator, op.query, request_id, &rng) catch op.query;
        defer if (query.ptr != op.query.ptr) ctx.allocator.free(query);

        request_id += 1;

        var result = db_driver.exec(query, null) catch |err| {
            std.debug.print("[Worker {}] Query error: {}\n", .{ ctx.worker_id, err });
            ctx.mutex.lock();
            ctx.errors.* += 1;
            ctx.mutex.unlock();
            continue;
        };
        defer result.deinit(ctx.allocator);

        if (!result.success) {
            ctx.mutex.lock();
            ctx.errors.* += 1;
            ctx.mutex.unlock();

            if (result.error_message) |msg| {
                std.debug.print("[Worker {}] Query failed: {s}\n", .{ ctx.worker_id, msg });
            }
        } else {
            ctx.mutex.lock();
            defer ctx.mutex.unlock();

            ctx.latencies.append(ctx.allocator, result.latency_ms) catch {};

            if (result.latency_ms > @as(f64, @floatFromInt(ctx.slo_ms))) {
                ctx.violations.* += 1;
            }
        }

        ctx.mutex.lock();
        ctx.total_requests.* += 1;
        ctx.mutex.unlock();

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

fn substituteParams(allocator: std.mem.Allocator, query: []const u8, request_id: u64, rng: *std.Random.DefaultPrng) ![]const u8 {
    // Simple parameter substitution for common parameters
    var result = std.ArrayList(u8){};
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < query.len) {
        if (i + 1 < query.len and query[i] == '$') {
            // Find parameter name
            const start = i + 1;
            var end = start;
            while (end < query.len and (std.ascii.isAlphanumeric(query[end]) or query[end] == '_')) {
                end += 1;
            }

            const param_name = query[start..end];

            // Substitute common parameters
            if (std.mem.eql(u8, param_name, "id")) {
                const id = rng.random().intRangeAtMost(u32, 1, 1000);
                try result.writer(allocator).print("{d}", .{id});
            } else if (std.mem.eql(u8, param_name, "src")) {
                const id = rng.random().intRangeAtMost(u32, 1, 500);
                try result.writer(allocator).print("{d}", .{id});
            } else if (std.mem.eql(u8, param_name, "dst")) {
                const id = rng.random().intRangeAtMost(u32, 501, 1000);
                try result.writer(allocator).print("{d}", .{id});
            } else if (std.mem.eql(u8, param_name, "min_age")) {
                const age = rng.random().intRangeAtMost(u32, 18, 65);
                try result.writer(allocator).print("{d}", .{age});
            } else if (std.mem.eql(u8, param_name, "name")) {
                try result.appendSlice(allocator, "'test_");
                try result.writer(allocator).print("{d}", .{request_id});
                try result.appendSlice(allocator, "'");
            } else if (std.mem.eql(u8, param_name, "ts")) {
                try result.writer(allocator).print("{d}", .{std.time.milliTimestamp()});
            } else if (std.mem.eql(u8, param_name, "weight")) {
                const weight = rng.random().float(f64);
                try result.writer(allocator).print("{d:.2}", .{weight});
            } else {
                // Unknown parameter, keep as-is
                try result.append(allocator, '$');
                try result.appendSlice(allocator, param_name);
            }

            i = end;
        } else {
            try result.append(allocator, query[i]);
            i += 1;
        }
    }

    return try result.toOwnedSlice(allocator);
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
