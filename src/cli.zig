const std = @import("std");

pub fn printUsage(file: std.fs.File) !void {
    try file.writeAll(
        \\graphbench - GDC-aligned graph database benchmark harness
        \\
        \\USAGE:
        \\  graphbench <command> [options]
        \\
        \\COMMANDS:
        \\  run         Execute a single benchmark run
        \\  sweep       Execute parameter sweep
        \\  validate    Validate configuration
        \\  dataset     Dataset operations (prepare/load/verify)
        \\  params      Parameter pack operations
        \\
        \\EXAMPLES:
        \\  graphbench run --config bench.json --out results/
        \\  graphbench sweep --config sweep.json --out results/
        \\  graphbench dataset prepare --dataset snb.tar.zst --out work/ --type snb_csv
        \\  graphbench dataset load --config bench.json --dataset-id snb_sf01 --workdir work/
        \\
    );
}

pub fn runCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var config_path: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;
    
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--config") and i + 1 < args.len) {
            config_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--out") and i + 1 < args.len) {
            out_dir = args[i + 1];
            i += 1;
        }
    }
    
    if (config_path == null or out_dir == null) {
        std.debug.print("Error: --config and --out are required\n", .{});
        std.process.exit(1);
    }
    
    const runner = @import("runner.zig");
    try runner.executeBenchmark(allocator, config_path.?, out_dir.?);
}

pub fn sweepCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var config_path: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;
    
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--config") and i + 1 < args.len) {
            config_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--out") and i + 1 < args.len) {
            out_dir = args[i + 1];
            i += 1;
        }
    }
    
    if (config_path == null or out_dir == null) {
        std.debug.print("Error: --config and --out are required\n", .{});
        std.process.exit(1);
    }
    
    const runner = @import("runner.zig");
    try runner.executeSweep(allocator, config_path.?, out_dir.?);
}

pub fn validateCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var config_path: ?[]const u8 = null;
    
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--config") and i + 1 < args.len) {
            config_path = args[i + 1];
            i += 1;
        }
    }
    
    if (config_path == null) {
        std.debug.print("Error: --config is required\n", .{});
        std.process.exit(1);
    }
    
    const config = @import("config.zig");
    var cfg = try config.loadConfig(allocator, config_path.?);
    defer cfg.deinit();
    
    std.debug.print("Configuration is valid\n", .{});
}

pub fn datasetCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Error: dataset subcommand required (prepare/load/verify)\n", .{});
        std.process.exit(1);
    }
    
    const subcommand = args[0];
    
    if (std.mem.eql(u8, subcommand, "prepare")) {
        try datasetPrepareCommand(allocator, args[1..]);
    } else if (std.mem.eql(u8, subcommand, "load")) {
        try datasetLoadCommand(allocator, args[1..]);
    } else if (std.mem.eql(u8, subcommand, "verify")) {
        try datasetVerifyCommand(allocator, args[1..]);
    } else {
        std.debug.print("Unknown dataset subcommand: {s}\n", .{subcommand});
        std.process.exit(1);
    }
}

fn datasetPrepareCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var dataset_path: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;
    var dataset_type: ?[]const u8 = null;
    
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--dataset") and i + 1 < args.len) {
            dataset_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--out") and i + 1 < args.len) {
            out_dir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--type") and i + 1 < args.len) {
            dataset_type = args[i + 1];
            i += 1;
        }
    }
    
    if (dataset_path == null or out_dir == null) {
        std.debug.print("Error: --dataset and --out are required\n", .{});
        std.process.exit(1);
    }
    
    const dataset = @import("dataset.zig");
    try dataset.prepareDataset(allocator, dataset_path.?, out_dir.?, dataset_type);
}

fn datasetLoadCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var config_path: ?[]const u8 = null;
    var dataset_id: ?[]const u8 = null;
    var workdir: ?[]const u8 = null;
    
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--config") and i + 1 < args.len) {
            config_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--dataset-id") and i + 1 < args.len) {
            dataset_id = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--workdir") and i + 1 < args.len) {
            workdir = args[i + 1];
            i += 1;
        }
    }
    
    if (config_path == null or dataset_id == null or workdir == null) {
        std.debug.print("Error: --config, --dataset-id, and --workdir are required\n", .{});
        std.process.exit(1);
    }
    
    const loader = @import("loader.zig");
    try loader.loadDataset(allocator, config_path.?, dataset_id.?, workdir.?);
}

fn datasetVerifyCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var config_path: ?[]const u8 = null;
    var dataset_id: ?[]const u8 = null;
    var workdir: ?[]const u8 = null;
    
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--config") and i + 1 < args.len) {
            config_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--dataset-id") and i + 1 < args.len) {
            dataset_id = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--workdir") and i + 1 < args.len) {
            workdir = args[i + 1];
            i += 1;
        }
    }
    
    if (config_path == null or dataset_id == null or workdir == null) {
        std.debug.print("Error: --config, --dataset-id, and --workdir are required\n", .{});
        std.process.exit(1);
    }
    
    const dataset = @import("dataset.zig");
    try dataset.verifyDataset(allocator, config_path.?, dataset_id.?, workdir.?);
}

pub fn paramsCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Error: params subcommand required (prepare)\n", .{});
        std.process.exit(1);
    }
    
    const subcommand = args[0];
    
    if (std.mem.eql(u8, subcommand, "prepare")) {
        try paramsPrepareCommand(allocator, args[1..]);
    } else {
        std.debug.print("Unknown params subcommand: {s}\n", .{subcommand});
        std.process.exit(1);
    }
}

fn paramsPrepareCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var params_path: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;
    
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--params") and i + 1 < args.len) {
            params_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--out") and i + 1 < args.len) {
            out_dir = args[i + 1];
            i += 1;
        }
    }
    
    if (params_path == null or out_dir == null) {
        std.debug.print("Error: --params and --out are required\n", .{});
        std.process.exit(1);
    }
    
    const dataset = @import("dataset.zig");
    try dataset.prepareParams(allocator, params_path.?, out_dir.?);
}
