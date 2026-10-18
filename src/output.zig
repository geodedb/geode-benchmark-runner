const std = @import("std");
const compat = @import("compat.zig");
const config = @import("config.zig");
const stats = @import("stats.zig");

pub fn writeResults(
    allocator: std.mem.Allocator,
    out_dir: []const u8,
    cfg: config.BenchConfig,
    metrics: stats.RunMetrics,
    validity: stats.ValidityCheck,
) !void {
    const path = try std.fs.path.join(allocator, &[_][]const u8{ out_dir, "result.json" });
    defer allocator.free(path);

    const file = try compat.cwd().createFile(compat.io(), path, .{});
    defer file.close(compat.io());

    const content = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "qps": {d:.2},
        \\  "latency": {{
        \\    "p50_ms": {d:.2},
        \\    "p95_ms": {d:.2},
        \\    "p99_ms": {d:.2},
        \\    "p999_ms": {d:.2},
        \\    "min_ms": {d:.2},
        \\    "max_ms": {d:.2},
        \\    "mean_ms": {d:.2}
        \\  }},
        \\  "error_rate": {d:.4},
        \\  "violation_rate": {d:.4},
        \\  "tail_amplification": {d:.2},
        \\  "qps_ceiling_est_from_p50": {d:.2},
        \\  "required_in_flight": {d:.2},
        \\  "valid": {},
        \\  "slo_ms": {d}
        \\}}
        \\
    , .{
        metrics.qps,
        metrics.latency.p50,
        metrics.latency.p95,
        metrics.latency.p99,
        metrics.latency.p999,
        metrics.latency.min,
        metrics.latency.max,
        metrics.latency.mean,
        metrics.error_rate,
        metrics.violation_rate,
        metrics.tail_amplification,
        metrics.qps_ceiling_est_from_p50,
        metrics.required_in_flight,
        validity.is_valid,
        cfg.workload.slo_ms,
    });
    defer allocator.free(content);

    try compat.writeAll(file, content);
}

pub fn writeMeta(
    allocator: std.mem.Allocator,
    out_dir: []const u8,
    cfg: config.BenchConfig,
) !void {
    const path = try std.fs.path.join(allocator, &[_][]const u8{ out_dir, "meta.json" });
    defer allocator.free(path);

    const file = try compat.cwd().createFile(compat.io(), path, .{});
    defer file.close(compat.io());

    const content = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "network_mode": "{s}",
        \\  "transport": "{s}",
        \\  "durability": "{s}",
        \\  "consistency": "{s}",
        \\  "cache_state": "{s}",
        \\  "db_version": "{s}",
        \\  "benchpack": "{s}"
        \\}}
        \\
    , .{
        @tagName(cfg.scenario.network_mode),
        @tagName(cfg.db.transport),
        cfg.scenario.durability,
        cfg.scenario.consistency,
        cfg.scenario.cache_state,
        cfg.scenario.db_version,
        cfg.workload.benchpack,
    });
    defer allocator.free(content);

    try compat.writeAll(file, content);
}

pub fn writeSummary(
    allocator: std.mem.Allocator,
    out_dir: []const u8,
    cfg: config.BenchConfig,
    metrics: stats.RunMetrics,
    validity: stats.ValidityCheck,
) !void {
    const path = try std.fs.path.join(allocator, &[_][]const u8{ out_dir, "summary.md" });
    defer allocator.free(path);

    const file = try compat.cwd().createFile(compat.io(), path, .{});
    defer file.close(compat.io());

    var content_parts = std.array_list.AlignedManaged([]const u8, null).init(allocator);
    defer {
        for (content_parts.items) |part| allocator.free(part);
        content_parts.deinit();
    }

    try content_parts.append(try std.fmt.allocPrint(allocator,
        \\# Benchmark Summary
        \\
        \\## Configuration
        \\
        \\- **Network Mode**: {s}
        \\- **Transport**: {s}
        \\- **Benchpack**: {s}
        \\- **SLO**: {d}ms
        \\
        \\## Results
        \\
        \\- **QPS**: {d:.2}
        \\- **p50 Latency**: {d:.2}ms
        \\- **p95 Latency**: {d:.2}ms
        \\- **p99 Latency**: {d:.2}ms
        \\- **Tail Amplification (p99/p50)**: {d:.2}x
        \\
        \\## Validity
        \\
        \\- **Valid**: {}
        \\
        \\
    , .{
        @tagName(cfg.scenario.network_mode),
        @tagName(cfg.db.transport),
        cfg.workload.benchpack,
        cfg.workload.slo_ms,
        metrics.qps,
        metrics.latency.p50,
        metrics.latency.p95,
        metrics.latency.p99,
        metrics.tail_amplification,
        validity.is_valid,
    }));

    if (!validity.is_valid) {
        try content_parts.append(try allocator.dupe(u8, "**Reasons for invalidity:**\n\n"));
        for (validity.reasons) |reason| {
            try content_parts.append(try std.fmt.allocPrint(allocator, "- {s}\n", .{reason}));
        }
    }

    try content_parts.append(try std.fmt.allocPrint(allocator,
        \\
        \\## Concurrency Analysis
        \\
        \\- **QPS Ceiling (from p50)**: {d:.2}
        \\- **Required In-Flight**: {d:.2}
        \\
        \\## Important Notes
        \\
        \\This benchmark was conducted in **{s}** mode.
        \\
    , .{
        metrics.qps_ceiling_est_from_p50,
        metrics.required_in_flight,
        @tagName(cfg.scenario.network_mode),
    }));

    if (cfg.scenario.network_mode == .loopback) {
        try content_parts.append(try allocator.dupe(u8,
            \\Loopback mode includes realistic RPC overhead but not realistic network RTT.
            \\Results should not be directly compared to remote deployments.
            \\
        ));
    }

    for (content_parts.items) |part| {
        try compat.writeAll(file, part);
    }
}

pub fn writeSweepResults(
    allocator: std.mem.Allocator,
    out_dir: []const u8,
    best_value: u32,
    best_qps: f64,
) !void {
    const path = try std.fs.path.join(allocator, &[_][]const u8{ out_dir, "sweep.json" });
    defer allocator.free(path);

    const file = try compat.cwd().createFile(compat.io(), path, .{});
    defer file.close(compat.io());

    const content = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "best_value": {d},
        \\  "best_qps": {d:.2}
        \\}}
        \\
    , .{ best_value, best_qps });
    defer allocator.free(content);

    try compat.writeAll(file, content);
}

/// Compare two benchmark result files and return comparison data
pub const CompareResult = struct {
    baseline_qps: f64,
    current_qps: f64,
    qps_change_pct: f64,
    baseline_p95: f64,
    current_p95: f64,
    p95_change_pct: f64,
    regression_detected: bool,

    pub fn format(self: CompareResult, allocator: std.mem.Allocator) ![]const u8 {
        const qps_direction: []const u8 = if (self.qps_change_pct >= 0) "+" else "";
        const p95_direction: []const u8 = if (self.p95_change_pct >= 0) "+" else "";

        return std.fmt.allocPrint(allocator,
            \\Benchmark Comparison
            \\====================
            \\
            \\QPS: {d:.2} -> {d:.2} ({s}{d:.1}%)
            \\p95: {d:.2}ms -> {d:.2}ms ({s}{d:.1}%)
            \\
            \\Regression: {}
            \\
        , .{
            self.baseline_qps,
            self.current_qps,
            qps_direction,
            self.qps_change_pct,
            self.baseline_p95,
            self.current_p95,
            p95_direction,
            self.p95_change_pct,
            self.regression_detected,
        });
    }
};

pub fn compareResults(
    allocator: std.mem.Allocator,
    baseline_path: []const u8,
    current_path: []const u8,
    regression_threshold_pct: f64,
) !CompareResult {
    // Read baseline result
    const baseline_file = try compat.cwd().openFile(compat.io(), baseline_path, .{});
    defer baseline_file.close(compat.io());
    const baseline_content = try compat.readToEndAlloc(baseline_file, allocator, 1024 * 1024);
    defer allocator.free(baseline_content);

    const baseline_parsed = try std.json.parseFromSlice(std.json.Value, allocator, baseline_content, .{});
    defer baseline_parsed.deinit();

    // Read current result
    const current_file = try compat.cwd().openFile(compat.io(), current_path, .{});
    defer current_file.close(compat.io());
    const current_content = try compat.readToEndAlloc(current_file, allocator, 1024 * 1024);
    defer allocator.free(current_content);

    const current_parsed = try std.json.parseFromSlice(std.json.Value, allocator, current_content, .{});
    defer current_parsed.deinit();

    // Extract metrics
    const baseline_qps = baseline_parsed.value.object.get("qps").?.float;
    const current_qps = current_parsed.value.object.get("qps").?.float;

    const baseline_latency = baseline_parsed.value.object.get("latency").?.object;
    const current_latency = current_parsed.value.object.get("latency").?.object;

    const baseline_p95 = baseline_latency.get("p95_ms").?.float;
    const current_p95 = current_latency.get("p95_ms").?.float;

    // Compute changes
    const qps_change_pct = if (baseline_qps > 0)
        ((current_qps - baseline_qps) / baseline_qps) * 100.0
    else
        0.0;

    const p95_change_pct = if (baseline_p95 > 0)
        ((current_p95 - baseline_p95) / baseline_p95) * 100.0
    else
        0.0;

    // Detect regression: QPS dropped significantly or p95 increased significantly
    const regression_detected = (qps_change_pct < -regression_threshold_pct) or
        (p95_change_pct > regression_threshold_pct);

    return CompareResult{
        .baseline_qps = baseline_qps,
        .current_qps = current_qps,
        .qps_change_pct = qps_change_pct,
        .baseline_p95 = baseline_p95,
        .current_p95 = current_p95,
        .p95_change_pct = p95_change_pct,
        .regression_detected = regression_detected,
    };
}

// Unit Tests

fn createTestConfig(allocator: std.mem.Allocator) config.BenchConfig {
    return config.BenchConfig{
        .allocator = allocator,
        .db = config.DbConfig{
            .host = allocator.dupe(u8, "localhost") catch unreachable,
            .port = 3141,
            .transport = .quic_tls_insecure,
            .auth_token_env = null,
            .timeout_ms = 30000,
        },
        .scenario = config.ScenarioConfig{
            .network_mode = .loopback,
            .netem = null,
            .durability = allocator.dupe(u8, "fsync") catch unreachable,
            .consistency = allocator.dupe(u8, "serializable") catch unreachable,
            .cache_state = allocator.dupe(u8, "warm") catch unreachable,
            .db_version = allocator.dupe(u8, "0.1.4") catch unreachable,
        },
        .workload = config.WorkloadConfig{
            .benchpack = allocator.dupe(u8, "gdc_micro_primitives") catch unreachable,
            .mode = .closed_loop,
            .duration_sec = 10,
            .target_qps = null,
            .workers = 2,
            .in_flight_per_worker = 1,
            .slo_ms = 100,
            .violation_threshold = 0.05,
            .error_threshold = 0.0,
        },
        .dataset = null,
        .loader = null,
    };
}

fn createTestMetrics() stats.RunMetrics {
    return stats.RunMetrics{
        .qps = 1000.0,
        .latency = stats.Percentiles{
            .p50 = 10.0,
            .p95 = 50.0,
            .p99 = 80.0,
            .p999 = 95.0,
            .min = 5.0,
            .max = 100.0,
            .mean = 25.0,
        },
        .error_rate = 0.001,
        .violation_rate = 0.02,
        .tail_amplification = 8.0,
        .qps_ceiling_est_from_p50 = 2000.0,
        .required_in_flight = 10.0,
    };
}

test "writeResults - creates valid JSON" {
    const allocator = std.testing.allocator;

    // Create temp directory
    const tmp_dir = "/tmp/graphbench_test_output";
    compat.cwd().createDir(compat.io(), tmp_dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer compat.cwd().deleteTree(compat.io(), tmp_dir) catch {};

    var cfg = createTestConfig(allocator);
    defer cfg.deinit();

    const metrics = createTestMetrics();
    const validity = stats.ValidityCheck{
        .is_valid = true,
        .reasons = &[_][]const u8{},
    };

    try writeResults(allocator, tmp_dir, cfg, metrics, validity);

    // Read and verify the file
    const result_path = try std.fs.path.join(allocator, &[_][]const u8{ tmp_dir, "result.json" });
    defer allocator.free(result_path);

    const file = try compat.cwd().openFile(compat.io(), result_path, .{});
    defer file.close(compat.io());

    const content = try compat.readToEndAlloc(file, allocator, 1024 * 1024);
    defer allocator.free(content);

    // Verify it's valid JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();

    // Verify some fields
    try std.testing.expectApproxEqAbs(@as(f64, 1000.0), parsed.value.object.get("qps").?.float, 0.1);
    try std.testing.expect(parsed.value.object.get("valid").?.bool);
}

test "writeMeta - creates valid JSON" {
    const allocator = std.testing.allocator;

    // Create temp directory
    const tmp_dir = "/tmp/graphbench_test_meta";
    compat.cwd().createDir(compat.io(), tmp_dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer compat.cwd().deleteTree(compat.io(), tmp_dir) catch {};

    var cfg = createTestConfig(allocator);
    defer cfg.deinit();

    try writeMeta(allocator, tmp_dir, cfg);

    // Read and verify
    const meta_path = try std.fs.path.join(allocator, &[_][]const u8{ tmp_dir, "meta.json" });
    defer allocator.free(meta_path);

    const file = try compat.cwd().openFile(compat.io(), meta_path, .{});
    defer file.close(compat.io());

    const content = try compat.readToEndAlloc(file, allocator, 1024 * 1024);
    defer allocator.free(content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("loopback", parsed.value.object.get("network_mode").?.string);
    try std.testing.expectEqualStrings("quic_tls_insecure", parsed.value.object.get("transport").?.string);
}

test "writeSummary - creates markdown file" {
    const allocator = std.testing.allocator;

    // Create temp directory
    const tmp_dir = "/tmp/graphbench_test_summary";
    compat.cwd().createDir(compat.io(), tmp_dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer compat.cwd().deleteTree(compat.io(), tmp_dir) catch {};

    var cfg = createTestConfig(allocator);
    defer cfg.deinit();

    const metrics = createTestMetrics();
    const validity = stats.ValidityCheck{
        .is_valid = true,
        .reasons = &[_][]const u8{},
    };

    try writeSummary(allocator, tmp_dir, cfg, metrics, validity);

    // Read and verify
    const summary_path = try std.fs.path.join(allocator, &[_][]const u8{ tmp_dir, "summary.md" });
    defer allocator.free(summary_path);

    const file = try compat.cwd().openFile(compat.io(), summary_path, .{});
    defer file.close(compat.io());

    const content = try compat.readToEndAlloc(file, allocator, 1024 * 1024);
    defer allocator.free(content);

    // Verify it contains expected markdown content
    try std.testing.expect(std.mem.indexOf(u8, content, "# Benchmark Summary") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "## Configuration") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "## Results") != null);
}

test "writeSweepResults - creates valid JSON" {
    const allocator = std.testing.allocator;

    // Create temp directory
    const tmp_dir = "/tmp/graphbench_test_sweep";
    compat.cwd().createDir(compat.io(), tmp_dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer compat.cwd().deleteTree(compat.io(), tmp_dir) catch {};

    try writeSweepResults(allocator, tmp_dir, 10, 1500.0);

    // Read and verify
    const sweep_path = try std.fs.path.join(allocator, &[_][]const u8{ tmp_dir, "sweep.json" });
    defer allocator.free(sweep_path);

    const file = try compat.cwd().openFile(compat.io(), sweep_path, .{});
    defer file.close(compat.io());

    const content = try compat.readToEndAlloc(file, allocator, 1024 * 1024);
    defer allocator.free(content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i64, 10), parsed.value.object.get("best_value").?.integer);
    try std.testing.expectApproxEqAbs(@as(f64, 1500.0), parsed.value.object.get("best_qps").?.float, 0.1);
}

test "compareResults - detects regression" {
    const allocator = std.testing.allocator;

    // Create temp directory
    const tmp_dir = "/tmp/graphbench_test_compare";
    compat.cwd().createDir(compat.io(), tmp_dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer compat.cwd().deleteTree(compat.io(), tmp_dir) catch {};

    // Create baseline result
    const baseline_path = try std.fs.path.join(allocator, &[_][]const u8{ tmp_dir, "baseline.json" });
    defer allocator.free(baseline_path);

    const baseline_content =
        \\{
        \\  "qps": 1000.00,
        \\  "latency": {
        \\    "p50_ms": 10.00,
        \\    "p95_ms": 50.00,
        \\    "p99_ms": 80.00,
        \\    "p999_ms": 95.00,
        \\    "min_ms": 5.00,
        \\    "max_ms": 100.00,
        \\    "mean_ms": 25.00
        \\  },
        \\  "error_rate": 0.0,
        \\  "violation_rate": 0.0,
        \\  "tail_amplification": 8.0,
        \\  "qps_ceiling_est_from_p50": 2000.0,
        \\  "required_in_flight": 10.0,
        \\  "valid": true,
        \\  "slo_ms": 100
        \\}
    ;

    const baseline_file = try compat.cwd().createFile(compat.io(), baseline_path, .{});
    try compat.writeAll(baseline_file, baseline_content);
    baseline_file.close(compat.io());

    // Create current result with regression (lower QPS, higher p95)
    const current_path = try std.fs.path.join(allocator, &[_][]const u8{ tmp_dir, "current.json" });
    defer allocator.free(current_path);

    const current_content =
        \\{
        \\  "qps": 800.00,
        \\  "latency": {
        \\    "p50_ms": 15.00,
        \\    "p95_ms": 75.00,
        \\    "p99_ms": 120.00,
        \\    "p999_ms": 150.00,
        \\    "min_ms": 8.00,
        \\    "max_ms": 200.00,
        \\    "mean_ms": 35.00
        \\  },
        \\  "error_rate": 0.01,
        \\  "violation_rate": 0.05,
        \\  "tail_amplification": 8.0,
        \\  "qps_ceiling_est_from_p50": 1600.0,
        \\  "required_in_flight": 12.0,
        \\  "valid": false,
        \\  "slo_ms": 100
        \\}
    ;

    const current_file = try compat.cwd().createFile(compat.io(), current_path, .{});
    try compat.writeAll(current_file, current_content);
    current_file.close(compat.io());

    // Compare with 10% threshold
    const result = try compareResults(allocator, baseline_path, current_path, 10.0);

    try std.testing.expectApproxEqAbs(@as(f64, 1000.0), result.baseline_qps, 0.1);
    try std.testing.expectApproxEqAbs(@as(f64, 800.0), result.current_qps, 0.1);
    try std.testing.expectApproxEqAbs(@as(f64, -20.0), result.qps_change_pct, 0.1);
    try std.testing.expect(result.regression_detected);
}

test "compareResults - no regression" {
    const allocator = std.testing.allocator;

    // Create temp directory
    const tmp_dir = "/tmp/graphbench_test_compare2";
    compat.cwd().createDir(compat.io(), tmp_dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer compat.cwd().deleteTree(compat.io(), tmp_dir) catch {};

    // Create baseline result
    const baseline_path = try std.fs.path.join(allocator, &[_][]const u8{ tmp_dir, "baseline.json" });
    defer allocator.free(baseline_path);

    const baseline_content =
        \\{
        \\  "qps": 1000.00,
        \\  "latency": {
        \\    "p50_ms": 10.00,
        \\    "p95_ms": 50.00,
        \\    "p99_ms": 80.00,
        \\    "p999_ms": 95.00,
        \\    "min_ms": 5.00,
        \\    "max_ms": 100.00,
        \\    "mean_ms": 25.00
        \\  },
        \\  "error_rate": 0.0,
        \\  "violation_rate": 0.0,
        \\  "tail_amplification": 8.0,
        \\  "qps_ceiling_est_from_p50": 2000.0,
        \\  "required_in_flight": 10.0,
        \\  "valid": true,
        \\  "slo_ms": 100
        \\}
    ;

    const baseline_file = try compat.cwd().createFile(compat.io(), baseline_path, .{});
    try compat.writeAll(baseline_file, baseline_content);
    baseline_file.close(compat.io());

    // Create current result with improvement
    const current_path = try std.fs.path.join(allocator, &[_][]const u8{ tmp_dir, "current.json" });
    defer allocator.free(current_path);

    const current_content =
        \\{
        \\  "qps": 1100.00,
        \\  "latency": {
        \\    "p50_ms": 9.00,
        \\    "p95_ms": 45.00,
        \\    "p99_ms": 70.00,
        \\    "p999_ms": 85.00,
        \\    "min_ms": 4.00,
        \\    "max_ms": 90.00,
        \\    "mean_ms": 22.00
        \\  },
        \\  "error_rate": 0.0,
        \\  "violation_rate": 0.0,
        \\  "tail_amplification": 7.8,
        \\  "qps_ceiling_est_from_p50": 2200.0,
        \\  "required_in_flight": 9.9,
        \\  "valid": true,
        \\  "slo_ms": 100
        \\}
    ;

    const current_file = try compat.cwd().createFile(compat.io(), current_path, .{});
    try compat.writeAll(current_file, current_content);
    current_file.close(compat.io());

    // Compare with 10% threshold
    const result = try compareResults(allocator, baseline_path, current_path, 10.0);

    try std.testing.expectApproxEqAbs(@as(f64, 10.0), result.qps_change_pct, 0.1);
    try std.testing.expect(!result.regression_detected);
}

test "CompareResult.format - generates readable output" {
    const allocator = std.testing.allocator;

    const result = CompareResult{
        .baseline_qps = 1000.0,
        .current_qps = 900.0,
        .qps_change_pct = -10.0,
        .baseline_p95 = 50.0,
        .current_p95 = 60.0,
        .p95_change_pct = 20.0,
        .regression_detected = true,
    };

    const formatted = try result.format(allocator);
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "Benchmark Comparison") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "Regression: true") != null);
}
