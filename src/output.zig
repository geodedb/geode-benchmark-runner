const std = @import("std");
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
    
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    
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
    
    try file.writeAll(content);
}

pub fn writeMeta(
    allocator: std.mem.Allocator,
    out_dir: []const u8,
    cfg: config.BenchConfig,
) !void {
    const path = try std.fs.path.join(allocator, &[_][]const u8{ out_dir, "meta.json" });
    defer allocator.free(path);
    
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    
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
    
    try file.writeAll(content);
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
    
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    
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
        try file.writeAll(part);
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
    
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    
    const content = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "best_value": {d},
        \\  "best_qps": {d:.2}
        \\}}
        \\
    , .{ best_value, best_qps });
    defer allocator.free(content);
    
    try file.writeAll(content);
}
