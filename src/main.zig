// SPDX-License-Identifier: MIT
// Copyright (c) 2024-2025 CodePros
//
// graphbench - GDC-aligned benchmark harness for graph databases over QUIC + TLS 1.3

const std = @import("std");
const zig_cli = @import("zig_cli");
const cli = zig_cli.cli;

const runner = @import("runner.zig");
const dataset = @import("dataset.zig");
const loader = @import("loader.zig");
const config = @import("config.zig");
const benchpack = @import("benchpack.zig");

pub const version = "0.2.0";

// ============================================================================
// Command Definitions
// ============================================================================

const run_cmd = cli.Command{
    .name = "run",
    .summary = "Execute a single benchmark run",
    .long_help =
    \\Execute a benchmark against a Geode server using the specified configuration.
    \\
    \\The benchmark connects to the server, executes queries from the specified
    \\benchpack, and collects latency metrics including p50/p95/p99 percentiles.
    ,
    .examples = &.{
        "graphbench run --config bench.json --out results/",
        "graphbench run -c bench.yaml -o results/ --workers 4",
    },
    .flags = &.{
        .{
            .name = "config",
            .short = 'c',
            .help = "Path to benchmark configuration file (JSON or YAML)",
            .ftype = .path,
            .required = true,
        },
        .{
            .name = "out",
            .short = 'o',
            .help = "Output directory for results",
            .ftype = .path,
            .required = true,
        },
        .{
            .name = "workers",
            .short = 'w',
            .help = "Override number of worker threads",
            .ftype = .int,
        },
        .{
            .name = "duration",
            .short = 'd',
            .help = "Override benchmark duration in seconds",
            .ftype = .int,
        },
    },
    .run = runBenchmark,
};

const sweep_cmd = cli.Command{
    .name = "sweep",
    .summary = "Execute parameter sweep",
    .long_help =
    \\Run multiple benchmarks while varying a parameter to find optimal settings.
    \\
    \\The sweep iterates over parameter values (e.g., workers, in_flight_per_worker)
    \\and records the best valid result achieving maximum QPS.
    ,
    .examples = &.{
        "graphbench sweep --config sweep.json --out results/",
    },
    .flags = &.{
        .{
            .name = "config",
            .short = 'c',
            .help = "Path to sweep configuration file",
            .ftype = .path,
            .required = true,
        },
        .{
            .name = "out",
            .short = 'o',
            .help = "Output directory for results",
            .ftype = .path,
            .required = true,
        },
    },
    .run = runSweep,
};

const validate_cmd = cli.Command{
    .name = "validate",
    .summary = "Validate configuration file",
    .examples = &.{
        "graphbench validate --config bench.yaml",
    },
    .flags = &.{
        .{
            .name = "config",
            .short = 'c',
            .help = "Path to configuration file to validate",
            .ftype = .path,
            .required = true,
        },
    },
    .run = runValidate,
};

const dataset_prepare_cmd = cli.Command{
    .name = "prepare",
    .summary = "Prepare dataset for loading",
    .long_help =
    \\Process raw dataset files (SNB CSV, Graphalytics edgelist) into
    \\normalized JSONL format suitable for batch loading into Geode.
    ,
    .examples = &.{
        "graphbench dataset prepare --dataset snb_sf01/ --out work/ --type snb_csv",
    },
    .flags = &.{
        .{
            .name = "dataset",
            .help = "Path to dataset directory or archive",
            .ftype = .path,
            .required = true,
        },
        .{
            .name = "out",
            .short = 'o',
            .help = "Output directory for prepared data",
            .ftype = .path,
            .required = true,
        },
        .{
            .name = "type",
            .short = 't',
            .help = "Dataset type: snb_csv, graphalytics_edgelist, auto",
            .ftype = .string,
            .default_str = "auto",
        },
    },
    .run = runDatasetPrepare,
};

const dataset_load_cmd = cli.Command{
    .name = "load",
    .summary = "Load prepared dataset into Geode",
    .long_help =
    \\Load a prepared dataset into a running Geode server using batch GQL inserts.
    \\
    \\This command reads JSONL files from the work directory and executes
    \\CREATE statements in batches for efficient data loading.
    ,
    .examples = &.{
        "graphbench dataset load --config bench.json --dataset-id snb_sf01 --workdir work/",
    },
    .flags = &.{
        .{
            .name = "config",
            .short = 'c',
            .help = "Path to benchmark configuration file",
            .ftype = .path,
            .required = true,
        },
        .{
            .name = "dataset-id",
            .help = "Dataset identifier",
            .ftype = .string,
            .required = true,
        },
        .{
            .name = "workdir",
            .help = "Working directory with prepared data",
            .ftype = .path,
            .required = true,
        },
    },
    .run = runDatasetLoad,
};

const dataset_verify_cmd = cli.Command{
    .name = "verify",
    .summary = "Verify loaded dataset integrity",
    .flags = &.{
        .{
            .name = "config",
            .short = 'c',
            .help = "Path to benchmark configuration file",
            .ftype = .path,
            .required = true,
        },
        .{
            .name = "dataset-id",
            .help = "Dataset identifier",
            .ftype = .string,
            .required = true,
        },
        .{
            .name = "workdir",
            .help = "Working directory with prepared data",
            .ftype = .path,
            .required = true,
        },
    },
    .run = runDatasetVerify,
};

const dataset_cmd = cli.Command{
    .name = "dataset",
    .summary = "Dataset operations (prepare/load/verify)",
    .subcommands = &.{ &dataset_prepare_cmd, &dataset_load_cmd, &dataset_verify_cmd },
};

const benchpack_list_cmd = cli.Command{
    .name = "list",
    .summary = "List available benchmark packs",
    .flags = &.{
        .{
            .name = "dir",
            .help = "Directory containing benchmark packs",
            .ftype = .path,
            .default_str = "benchpacks",
        },
    },
    .run = runBenchpackList,
};

const benchpack_show_cmd = cli.Command{
    .name = "show",
    .summary = "Show details of a benchmark pack",
    .args = .{ .exact = 1 },
    .flags = &.{
        .{
            .name = "dir",
            .help = "Directory containing benchmark packs",
            .ftype = .path,
            .default_str = "benchpacks",
        },
    },
    .run = runBenchpackShow,
};

const benchpack_cmd = cli.Command{
    .name = "benchpack",
    .summary = "Benchmark pack operations",
    .subcommands = &.{ &benchpack_list_cmd, &benchpack_show_cmd },
};

const root_cmd = cli.Command{
    .name = "graphbench",
    .summary = "GDC-aligned benchmark harness for graph databases",
    .long_help =
    \\graphbench is a performance benchmark tool for Geode and other graph databases
    \\supporting the QUIC+TLS 1.3 protocol with GQL queries.
    \\
    \\It measures query latencies, computes percentile metrics (p50/p95/p99),
    \\validates against SLO thresholds, and generates GDC-compliant reports.
    ,
    .version = version,
    .subcommands = &.{
        &run_cmd,
        &sweep_cmd,
        &validate_cmd,
        &dataset_cmd,
        &benchpack_cmd,
    },
};

// ============================================================================
// Command Implementations
// ============================================================================

fn runBenchmark(ctx: *cli.Context) anyerror!void {
    const config_path = ctx.getString("config") orelse return error.MissingConfig;
    const out_dir = ctx.getString("out") orelse return error.MissingOutput;

    const workers_override = ctx.getInt("workers");
    const duration_override = ctx.getInt("duration");

    try runner.executeBenchmark(
        ctx.allocator,
        config_path,
        out_dir,
        if (workers_override) |w| @intCast(w) else null,
        if (duration_override) |d| @intCast(d) else null,
    );
}

fn runSweep(ctx: *cli.Context) anyerror!void {
    const config_path = ctx.getString("config") orelse return error.MissingConfig;
    const out_dir = ctx.getString("out") orelse return error.MissingOutput;

    try runner.executeSweep(ctx.allocator, config_path, out_dir);
}

fn runValidate(ctx: *cli.Context) anyerror!void {
    const config_path = ctx.getString("config") orelse return error.MissingConfig;

    var cfg = try config.loadConfig(ctx.allocator, config_path);
    defer cfg.deinit();

    try ctx.print("Configuration is valid\n", .{});
    try ctx.print("  Host: {s}:{d}\n", .{ cfg.db.host, cfg.db.port });
    try ctx.print("  Benchpack: {s}\n", .{cfg.workload.benchpack});
    try ctx.print("  Duration: {d}s\n", .{cfg.workload.duration_sec orelse 30});
    try ctx.print("  Workers: {d}\n", .{cfg.workload.workers orelse 4});
}

fn runDatasetPrepare(ctx: *cli.Context) anyerror!void {
    const dataset_path = ctx.getString("dataset") orelse return error.MissingDataset;
    const out_dir = ctx.getString("out") orelse return error.MissingOutput;
    const dataset_type = ctx.getString("type");

    try dataset.prepareDataset(ctx.allocator, dataset_path, out_dir, dataset_type);
}

fn runDatasetLoad(ctx: *cli.Context) anyerror!void {
    const config_path = ctx.getString("config") orelse return error.MissingConfig;
    const dataset_id = ctx.getString("dataset-id") orelse return error.MissingDatasetId;
    const workdir = ctx.getString("workdir") orelse return error.MissingWorkdir;

    try loader.loadDataset(ctx.allocator, config_path, dataset_id, workdir);
}

fn runDatasetVerify(ctx: *cli.Context) anyerror!void {
    const config_path = ctx.getString("config") orelse return error.MissingConfig;
    const dataset_id = ctx.getString("dataset-id") orelse return error.MissingDatasetId;
    const workdir = ctx.getString("workdir") orelse return error.MissingWorkdir;

    try dataset.verifyDataset(ctx.allocator, config_path, dataset_id, workdir);
}

fn runBenchpackList(ctx: *cli.Context) anyerror!void {
    const dir = ctx.getString("dir") orelse "benchpacks";

    var packs = try benchpack.listBenchpacks(ctx.allocator, dir);
    defer {
        for (packs.items) |pack| {
            ctx.allocator.free(pack.name);
            ctx.allocator.free(pack.description);
        }
        packs.deinit(ctx.allocator);
    }

    if (packs.items.len == 0) {
        try ctx.print("No benchmark packs found in {s}\n", .{dir});
        return;
    }

    try ctx.print("Available benchmark packs:\n\n", .{});
    for (packs.items) |pack| {
        try ctx.print("  {s}\n", .{pack.name});
        try ctx.print("    {s}\n", .{pack.description});
        try ctx.print("    Operations: {d}\n\n", .{pack.operation_count});
    }
}

fn runBenchpackShow(ctx: *cli.Context) anyerror!void {
    if (ctx.positionals.items.len == 0) {
        try ctx.err("Error: benchmark pack name required\n", .{});
        return;
    }

    const pack_name = ctx.positionals.items[0];
    const dir = ctx.getString("dir") orelse "benchpacks";

    var pack = benchpack.loadBenchpack(ctx.allocator, dir, pack_name) catch |err| {
        try ctx.err("Error loading benchpack '{s}': {}\n", .{ pack_name, err });
        return;
    };
    defer pack.deinit(ctx.allocator);

    try ctx.print("Benchmark Pack: {s}\n", .{pack.name});
    try ctx.print("Description: {s}\n", .{pack.description});
    try ctx.print("Operations:\n", .{});

    for (pack.operations, 0..) |op, i| {
        try ctx.print("\n  [{d}] {s}\n", .{ i + 1, op.name });
        try ctx.print("      Weight: {d:.2}\n", .{op.weight});
        try ctx.print("      SLO: {d}ms\n", .{op.slo_ms});
        try ctx.print("      Query: {s}\n", .{op.query});
    }
}

// ============================================================================
// Entry Point
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const exit_code = cli.run(&root_cmd, args, allocator) catch |err| {
        std.debug.print("Error: {}\n", .{err});
        std.process.exit(1);
    };

    std.process.exit(exit_code);
}

// ============================================================================
// Tests
// ============================================================================

test {
    std.testing.refAllDecls(@This());
    _ = @import("config.zig");
    _ = @import("runner.zig");
    _ = @import("stats.zig");
    _ = @import("output.zig");
    _ = @import("driver.zig");
    _ = @import("loader.zig");
    _ = @import("dataset.zig");
    _ = @import("benchpack.zig");
}
