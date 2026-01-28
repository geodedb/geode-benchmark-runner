// SPDX-License-Identifier: MIT
// Copyright (c) 2024-2025 CodePros
//
// Dataset preparation from SNB CSV and Graphalytics formats

const std = @import("std");

pub const DatasetType = enum {
    auto,
    snb_csv,
    graphalytics_edgelist,
    finbench,
};

pub const Manifest = struct {
    dataset_id: []const u8,
    dataset_type: DatasetType,
    source_file: []const u8,
    node_labels: []const []const u8,
    edge_types: []const []const u8,
};

pub const Stats = struct {
    node_count: u64,
    edge_count: u64,
};

pub fn prepareDataset(
    allocator: std.mem.Allocator,
    dataset_path: []const u8,
    out_dir: []const u8,
    dataset_type_hint: ?[]const u8,
) !void {
    std.debug.print("Preparing dataset: {s} -> {s}\n", .{ dataset_path, out_dir });

    const dataset_type = if (dataset_type_hint) |hint| blk: {
        if (std.mem.eql(u8, hint, "snb_csv")) break :blk DatasetType.snb_csv;
        if (std.mem.eql(u8, hint, "graphalytics_edgelist")) break :blk DatasetType.graphalytics_edgelist;
        if (std.mem.eql(u8, hint, "finbench")) break :blk DatasetType.finbench;
        break :blk DatasetType.auto;
    } else DatasetType.auto;

    const detected_type = if (dataset_type == .auto)
        try detectDatasetType(allocator, dataset_path)
    else
        dataset_type;

    try std.fs.cwd().makePath(out_dir);

    if (detected_type == .snb_csv) {
        try prepareSNBCSV(allocator, dataset_path, out_dir);
    } else if (detected_type == .graphalytics_edgelist) {
        try prepareGraphalytics(allocator, dataset_path, out_dir);
    } else if (detected_type == .finbench) {
        try prepareFinBench(allocator, dataset_path, out_dir);
    }

    std.debug.print("Dataset prepared successfully\n", .{});
}

fn detectDatasetType(allocator: std.mem.Allocator, path: []const u8) !DatasetType {
    // Check if it's a directory
    const stat = std.fs.cwd().statFile(path) catch |err| {
        if (err == error.FileNotFound) {
            // Try as directory
            var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch {
                return error.DatasetNotFound;
            };
            defer dir.close();

            // Check for FinBench (has snapshot/ subdirectory with Account.csv, Person.csv, etc.)
            if (dir.openDir("snapshot", .{ .iterate = true })) |snapshot_dir_val| {
                var snapshot_dir = snapshot_dir_val;
                defer snapshot_dir.close();
                var snap_iter = snapshot_dir.iterate();
                while (try snap_iter.next()) |entry| {
                    if (entry.kind == .file) {
                        if (std.mem.eql(u8, entry.name, "Account.csv") or
                            std.mem.eql(u8, entry.name, "Person.csv") or
                            std.mem.eql(u8, entry.name, "Company.csv"))
                        {
                            return .finbench;
                        }
                    }
                }
            } else |_| {}

            var iter = dir.iterate();
            while (try iter.next()) |entry| {
                if (entry.kind == .file) {
                    if (std.mem.indexOf(u8, entry.name, "person_") != null or
                        std.mem.indexOf(u8, entry.name, "post_") != null)
                    {
                        return .snb_csv;
                    }
                }
            }

            return .graphalytics_edgelist;
        }
        return err;
    };

    if (stat.kind == .directory) {
        var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
        defer dir.close();

        // Check for FinBench (has snapshot/ subdirectory)
        if (dir.openDir("snapshot", .{ .iterate = true })) |snapshot_dir_val| {
            var snapshot_dir = snapshot_dir_val;
            defer snapshot_dir.close();
            var snap_iter = snapshot_dir.iterate();
            while (try snap_iter.next()) |entry| {
                if (entry.kind == .file) {
                    if (std.mem.eql(u8, entry.name, "Account.csv") or
                        std.mem.eql(u8, entry.name, "Person.csv") or
                        std.mem.eql(u8, entry.name, "Company.csv"))
                    {
                        return .finbench;
                    }
                }
            }
        } else |_| {}

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file) {
                if (std.mem.indexOf(u8, entry.name, "person_") != null or
                    std.mem.indexOf(u8, entry.name, "post_") != null)
                {
                    return .snb_csv;
                }
            }
        }
    }

    _ = allocator;
    return .graphalytics_edgelist;
}

fn prepareSNBCSV(allocator: std.mem.Allocator, dataset_path: []const u8, out_dir: []const u8) !void {
    std.debug.print("Preparing SNB CSV dataset\n", .{});

    const nodes_dir = try std.fs.path.join(allocator, &[_][]const u8{ out_dir, "nodes" });
    defer allocator.free(nodes_dir);
    try std.fs.cwd().makePath(nodes_dir);

    const edges_dir = try std.fs.path.join(allocator, &[_][]const u8{ out_dir, "edges" });
    defer allocator.free(edges_dir);
    try std.fs.cwd().makePath(edges_dir);

    // Open dataset directory
    var dataset_dir = try std.fs.cwd().openDir(dataset_path, .{ .iterate = true });
    defer dataset_dir.close();

    var node_count: u64 = 0;
    var edge_count: u64 = 0;

    // Process CSV files
    var iter = dataset_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".csv")) continue;

        // Determine if node or edge file
        const is_edge = std.mem.indexOf(u8, entry.name, "_knows_") != null or
            std.mem.indexOf(u8, entry.name, "_hasCreator_") != null or
            std.mem.indexOf(u8, entry.name, "_likes_") != null or
            std.mem.indexOf(u8, entry.name, "_isLocatedIn_") != null or
            std.mem.indexOf(u8, entry.name, "_containerOf_") != null;

        if (is_edge) {
            edge_count += try processEdgeFile(allocator, dataset_dir, entry.name, edges_dir);
        } else {
            node_count += try processNodeFile(allocator, dataset_dir, entry.name, nodes_dir);
        }
    }

    // Write stats
    const stats_path = try std.fs.path.join(allocator, &[_][]const u8{ out_dir, "stats.json" });
    defer allocator.free(stats_path);

    const stats_file = try std.fs.cwd().createFile(stats_path, .{});
    defer stats_file.close();

    const stats_content = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "node_count": {d},
        \\  "edge_count": {d}
        \\}}
        \\
    , .{ node_count, edge_count });
    defer allocator.free(stats_content);

    try stats_file.writeAll(stats_content);

    std.debug.print("Processed {d} nodes, {d} edges\n", .{ node_count, edge_count });
}

fn processNodeFile(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    filename: []const u8,
    out_dir: []const u8,
) !u64 {
    // Extract label from filename (e.g., "person_0_0.csv" -> "Person")
    const label_end = std.mem.indexOf(u8, filename, "_") orelse filename.len;
    const label_lower = filename[0..label_end];

    var label_buf: [64]u8 = undefined;
    @memcpy(label_buf[0..label_lower.len], label_lower);
    if (label_lower.len > 0) {
        label_buf[0] = std.ascii.toUpper(label_buf[0]);
    }
    const label = label_buf[0..label_lower.len];

    const out_filename = try std.fmt.allocPrint(allocator, "{s}/{s}.jsonl", .{ out_dir, label });
    defer allocator.free(out_filename);

    const in_file = try dir.openFile(filename, .{});
    defer in_file.close();

    var out_file = try std.fs.cwd().createFile(out_filename, .{ .truncate = false });
    defer out_file.close();

    // Seek to end for appending
    try out_file.seekFromEnd(0);

    var count: u64 = 0;
    const reader = in_file.deprecatedReader();
    var line_buf: [8192]u8 = undefined;

    // Skip header
    _ = try reader.readUntilDelimiterOrEof(&line_buf, '\n');

    // Process data lines
    while (try reader.readUntilDelimiterOrEof(&line_buf, '\n')) |line| {
        if (line.len == 0) continue;

        // Simple conversion: treat first field as ID
        var fields = std.mem.tokenizeScalar(u8, line, '|');
        const id_field = fields.next() orelse continue;

        // Write JSONL (simplified - just store ID for now)
        const jsonl = try std.fmt.allocPrint(allocator,
            \\{{"id":"{s}"}}
            \\
        , .{id_field});
        defer allocator.free(jsonl);

        try out_file.writeAll(jsonl);
        count += 1;
    }

    return count;
}

fn processEdgeFile(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    filename: []const u8,
    out_dir: []const u8,
) !u64 {
    // Extract edge type from filename
    const type_name = filename[0 .. filename.len - 4]; // Remove .csv

    // Find the relationship type (between underscores)
    var parts = std.mem.tokenizeScalar(u8, type_name, '_');
    _ = parts.next(); // source type
    const rel_type = parts.next() orelse "RELATED";

    const out_filename = try std.fmt.allocPrint(allocator, "{s}/{s}.jsonl", .{ out_dir, rel_type });
    defer allocator.free(out_filename);

    const in_file = try dir.openFile(filename, .{});
    defer in_file.close();

    var out_file = try std.fs.cwd().createFile(out_filename, .{ .truncate = false });
    defer out_file.close();

    try out_file.seekFromEnd(0);

    var count: u64 = 0;
    const reader = in_file.deprecatedReader();
    var line_buf: [8192]u8 = undefined;

    // Skip header
    _ = try reader.readUntilDelimiterOrEof(&line_buf, '\n');

    // Process data lines
    while (try reader.readUntilDelimiterOrEof(&line_buf, '\n')) |line| {
        if (line.len == 0) continue;

        var fields = std.mem.tokenizeScalar(u8, line, '|');
        const src = fields.next() orelse continue;
        const dst = fields.next() orelse continue;

        const jsonl = try std.fmt.allocPrint(allocator,
            \\{{"src":"{s}","dst":"{s}"}}
            \\
        , .{ src, dst });
        defer allocator.free(jsonl);

        try out_file.writeAll(jsonl);
        count += 1;
    }

    return count;
}

fn prepareGraphalytics(allocator: std.mem.Allocator, dataset_path: []const u8, out_dir: []const u8) !void {
    std.debug.print("Preparing Graphalytics dataset\n", .{});

    const nodes_dir = try std.fs.path.join(allocator, &[_][]const u8{ out_dir, "nodes" });
    defer allocator.free(nodes_dir);
    try std.fs.cwd().makePath(nodes_dir);

    const edges_dir = try std.fs.path.join(allocator, &[_][]const u8{ out_dir, "edges" });
    defer allocator.free(edges_dir);
    try std.fs.cwd().makePath(edges_dir);

    // Graphalytics uses edge list format: src dst [weight]
    // Extract unique nodes and edges

    var node_set = std.StringHashMap(void).init(allocator);
    defer {
        var iter = node_set.keyIterator();
        while (iter.next()) |key| {
            allocator.free(key.*);
        }
        node_set.deinit();
    }

    // Process main edge file
    const stat = std.fs.cwd().statFile(dataset_path) catch |err| {
        std.debug.print("Cannot access {s}: {}\n", .{ dataset_path, err });
        return err;
    };

    var edge_count: u64 = 0;

    if (stat.kind == .file) {
        // Single file - process as edge list
        const edges_file_path = try std.fmt.allocPrint(allocator, "{s}/EDGE.jsonl", .{edges_dir});
        defer allocator.free(edges_file_path);

        var edges_file = try std.fs.cwd().createFile(edges_file_path, .{});
        defer edges_file.close();

        const in_file = try std.fs.cwd().openFile(dataset_path, .{});
        defer in_file.close();

        const reader = in_file.deprecatedReader();
        var line_buf: [1024]u8 = undefined;

        while (try reader.readUntilDelimiterOrEof(&line_buf, '\n')) |line| {
            if (line.len == 0) continue;
            if (line[0] == '#') continue; // Skip comments

            var parts = std.mem.tokenizeAny(u8, line, " \t");
            const src = parts.next() orelse continue;
            const dst = parts.next() orelse continue;

            // Track unique nodes
            if (!node_set.contains(src)) {
                try node_set.put(try allocator.dupe(u8, src), {});
            }
            if (!node_set.contains(dst)) {
                try node_set.put(try allocator.dupe(u8, dst), {});
            }

            // Write edge
            const jsonl = try std.fmt.allocPrint(allocator,
                \\{{"src":"{s}","dst":"{s}"}}
                \\
            , .{ src, dst });
            defer allocator.free(jsonl);

            try edges_file.writeAll(jsonl);
            edge_count += 1;
        }
    } else {
        // Directory - look for .e or .edges file
        var dir = try std.fs.cwd().openDir(dataset_path, .{ .iterate = true });
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".e") and
                !std.mem.endsWith(u8, entry.name, ".edges"))
            {
                continue;
            }

            const edges_file_path = try std.fmt.allocPrint(allocator, "{s}/EDGE.jsonl", .{edges_dir});
            defer allocator.free(edges_file_path);

            var edges_file = try std.fs.cwd().createFile(edges_file_path, .{});
            defer edges_file.close();

            const in_file = try dir.openFile(entry.name, .{});
            defer in_file.close();

            const reader = in_file.deprecatedReader();
            var line_buf: [1024]u8 = undefined;

            while (try reader.readUntilDelimiterOrEof(&line_buf, '\n')) |line| {
                if (line.len == 0) continue;
                if (line[0] == '#') continue;

                var parts = std.mem.tokenizeAny(u8, line, " \t");
                const src = parts.next() orelse continue;
                const dst = parts.next() orelse continue;

                if (!node_set.contains(src)) {
                    try node_set.put(try allocator.dupe(u8, src), {});
                }
                if (!node_set.contains(dst)) {
                    try node_set.put(try allocator.dupe(u8, dst), {});
                }

                const jsonl = try std.fmt.allocPrint(allocator,
                    \\{{"src":"{s}","dst":"{s}"}}
                    \\
                , .{ src, dst });
                defer allocator.free(jsonl);

                try edges_file.writeAll(jsonl);
                edge_count += 1;
            }
        }
    }

    // Write nodes
    const nodes_file_path = try std.fmt.allocPrint(allocator, "{s}/Node.jsonl", .{nodes_dir});
    defer allocator.free(nodes_file_path);

    var nodes_file = try std.fs.cwd().createFile(nodes_file_path, .{});
    defer nodes_file.close();

    var node_iter = node_set.keyIterator();
    while (node_iter.next()) |key| {
        const jsonl = try std.fmt.allocPrint(allocator,
            \\{{"id":"{s}"}}
            \\
        , .{key.*});
        defer allocator.free(jsonl);

        try nodes_file.writeAll(jsonl);
    }

    const node_count = node_set.count();

    // Write stats
    const stats_path = try std.fmt.allocPrint(allocator, "{s}/stats.json", .{out_dir});
    defer allocator.free(stats_path);

    const stats_file = try std.fs.cwd().createFile(stats_path, .{});
    defer stats_file.close();

    const stats_content = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "node_count": {d},
        \\  "edge_count": {d}
        \\}}
        \\
    , .{ node_count, edge_count });
    defer allocator.free(stats_content);

    try stats_file.writeAll(stats_content);

    std.debug.print("Processed {d} nodes, {d} edges\n", .{ node_count, edge_count });
}

// ============================================================================
// FinBench Dataset Preparation (LDBC Financial Benchmark)
// ============================================================================

const FinBenchNodeSchema = struct {
    filename: []const u8,
    label: []const u8,
    id_field: []const u8,
    properties: []const struct { csv_col: []const u8, json_name: []const u8, is_numeric: bool },
};

const finbench_node_schemas = [_]FinBenchNodeSchema{
    .{
        .filename = "Person.csv",
        .label = "Person",
        .id_field = "personId",
        .properties = &.{
            .{ .csv_col = "personName", .json_name = "name", .is_numeric = false },
            .{ .csv_col = "isBlocked", .json_name = "isBlocked", .is_numeric = false },
            .{ .csv_col = "gender", .json_name = "gender", .is_numeric = false },
            .{ .csv_col = "country", .json_name = "country", .is_numeric = false },
            .{ .csv_col = "city", .json_name = "city", .is_numeric = false },
        },
    },
    .{
        .filename = "Company.csv",
        .label = "Company",
        .id_field = "companyId",
        .properties = &.{
            .{ .csv_col = "companyName", .json_name = "name", .is_numeric = false },
            .{ .csv_col = "isBlocked", .json_name = "isBlocked", .is_numeric = false },
            .{ .csv_col = "country", .json_name = "country", .is_numeric = false },
            .{ .csv_col = "city", .json_name = "city", .is_numeric = false },
            .{ .csv_col = "business", .json_name = "business", .is_numeric = false },
        },
    },
    .{
        .filename = "Account.csv",
        .label = "Account",
        .id_field = "accountId",
        .properties = &.{
            .{ .csv_col = "isBlocked", .json_name = "isBlocked", .is_numeric = false },
            .{ .csv_col = "accoutType", .json_name = "type", .is_numeric = false },
            .{ .csv_col = "nickname", .json_name = "nickname", .is_numeric = false },
            .{ .csv_col = "accountLevel", .json_name = "level", .is_numeric = false },
        },
    },
    .{
        .filename = "Loan.csv",
        .label = "Loan",
        .id_field = "loanId",
        .properties = &.{
            .{ .csv_col = "loanAmount", .json_name = "amount", .is_numeric = true },
            .{ .csv_col = "balance", .json_name = "balance", .is_numeric = true },
            .{ .csv_col = "loanUsage", .json_name = "usage", .is_numeric = false },
            .{ .csv_col = "interestRate", .json_name = "interestRate", .is_numeric = true },
        },
    },
    .{
        .filename = "Medium.csv",
        .label = "Medium",
        .id_field = "mediumId",
        .properties = &.{
            .{ .csv_col = "mediumType", .json_name = "type", .is_numeric = false },
            .{ .csv_col = "isBlocked", .json_name = "isBlocked", .is_numeric = false },
            .{ .csv_col = "riskLevel", .json_name = "riskLevel", .is_numeric = false },
        },
    },
};

const FinBenchEdgeSchema = struct {
    filename: []const u8,
    rel_type: []const u8,
    from_label: []const u8,
    to_label: []const u8,
    from_id_col: []const u8,
    to_id_col: []const u8,
    properties: []const struct { csv_col: []const u8, json_name: []const u8, is_numeric: bool },
};

const finbench_edge_schemas = [_]FinBenchEdgeSchema{
    .{ .filename = "PersonOwnAccount.csv", .rel_type = "OWN", .from_label = "Person", .to_label = "Account", .from_id_col = "personId", .to_id_col = "accountId", .properties = &.{} },
    .{ .filename = "CompanyOwnAccount.csv", .rel_type = "OWN", .from_label = "Company", .to_label = "Account", .from_id_col = "companyId", .to_id_col = "accountId", .properties = &.{} },
    .{ .filename = "PersonApplyLoan.csv", .rel_type = "APPLY", .from_label = "Person", .to_label = "Loan", .from_id_col = "personId", .to_id_col = "loanId", .properties = &.{} },
    .{ .filename = "CompanyApplyLoan.csv", .rel_type = "APPLY", .from_label = "Company", .to_label = "Loan", .from_id_col = "companyId", .to_id_col = "loanId", .properties = &.{} },
    .{ .filename = "PersonInvestCompany.csv", .rel_type = "INVEST", .from_label = "Person", .to_label = "Company", .from_id_col = "investorId", .to_id_col = "companyId", .properties = &.{ .{ .csv_col = "ratio", .json_name = "ratio", .is_numeric = true } } },
    .{ .filename = "CompanyInvestCompany.csv", .rel_type = "INVEST", .from_label = "Company", .to_label = "Company", .from_id_col = "investorId", .to_id_col = "companyId", .properties = &.{ .{ .csv_col = "ratio", .json_name = "ratio", .is_numeric = true } } },
    .{ .filename = "PersonGuaranteePerson.csv", .rel_type = "GUARANTEE", .from_label = "Person", .to_label = "Person", .from_id_col = "fromId", .to_id_col = "toId", .properties = &.{} },
    .{ .filename = "CompanyGuaranteeCompany.csv", .rel_type = "GUARANTEE", .from_label = "Company", .to_label = "Company", .from_id_col = "fromId", .to_id_col = "toId", .properties = &.{} },
    .{ .filename = "AccountTransferAccount.csv", .rel_type = "TRANSFER", .from_label = "Account", .to_label = "Account", .from_id_col = "fromId", .to_id_col = "toId", .properties = &.{ .{ .csv_col = "amount", .json_name = "amount", .is_numeric = true } } },
    .{ .filename = "AccountWithdrawAccount.csv", .rel_type = "WITHDRAW", .from_label = "Account", .to_label = "Account", .from_id_col = "fromId", .to_id_col = "toId", .properties = &.{ .{ .csv_col = "amount", .json_name = "amount", .is_numeric = true } } },
    .{ .filename = "LoanDepositAccount.csv", .rel_type = "DEPOSIT", .from_label = "Loan", .to_label = "Account", .from_id_col = "loanId", .to_id_col = "accountId", .properties = &.{ .{ .csv_col = "amount", .json_name = "amount", .is_numeric = true } } },
    .{ .filename = "AccountRepayLoan.csv", .rel_type = "REPAY", .from_label = "Account", .to_label = "Loan", .from_id_col = "accountId", .to_id_col = "loanId", .properties = &.{ .{ .csv_col = "amount", .json_name = "amount", .is_numeric = true } } },
    .{ .filename = "MediumSignInAccount.csv", .rel_type = "SIGN_IN", .from_label = "Medium", .to_label = "Account", .from_id_col = "mediumId", .to_id_col = "accountId", .properties = &.{} },
};

fn prepareFinBench(allocator: std.mem.Allocator, dataset_path: []const u8, out_dir: []const u8) !void {
    std.debug.print("Preparing FinBench dataset from {s}\n", .{dataset_path});

    // Create output directories
    const nodes_dir = try std.fs.path.join(allocator, &[_][]const u8{ out_dir, "nodes" });
    defer allocator.free(nodes_dir);
    try std.fs.cwd().makePath(nodes_dir);

    const edges_dir = try std.fs.path.join(allocator, &[_][]const u8{ out_dir, "edges" });
    defer allocator.free(edges_dir);
    try std.fs.cwd().makePath(edges_dir);

    // Open snapshot directory
    const snapshot_path = try std.fs.path.join(allocator, &[_][]const u8{ dataset_path, "snapshot" });
    defer allocator.free(snapshot_path);

    var snapshot_dir = std.fs.cwd().openDir(snapshot_path, .{}) catch |err| {
        std.debug.print("Cannot open snapshot directory: {}\n", .{err});
        return err;
    };
    defer snapshot_dir.close();

    var total_nodes: u64 = 0;
    var total_edges: u64 = 0;

    // Process node files
    std.debug.print("Processing node files...\n", .{});
    for (finbench_node_schemas) |schema| {
        const count = processFinBenchNodeFile(allocator, snapshot_dir, schema, nodes_dir) catch |err| {
            std.debug.print("  Warning: Could not process {s}: {}\n", .{ schema.filename, err });
            continue;
        };
        total_nodes += count;
        std.debug.print("  {s}: {d} nodes\n", .{ schema.label, count });
    }

    // Process edge files
    std.debug.print("Processing edge files...\n", .{});
    for (finbench_edge_schemas) |schema| {
        const count = processFinBenchEdgeFile(allocator, snapshot_dir, schema, edges_dir) catch |err| {
            std.debug.print("  Warning: Could not process {s}: {}\n", .{ schema.filename, err });
            continue;
        };
        total_edges += count;
        std.debug.print("  {s}: {d} edges\n", .{ schema.rel_type, count });
    }

    // Write stats
    const stats_path = try std.fs.path.join(allocator, &[_][]const u8{ out_dir, "stats.json" });
    defer allocator.free(stats_path);

    const stats_file = try std.fs.cwd().createFile(stats_path, .{});
    defer stats_file.close();

    const stats_content = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "dataset_type": "finbench",
        \\  "node_count": {d},
        \\  "edge_count": {d}
        \\}}
        \\
    , .{ total_nodes, total_edges });
    defer allocator.free(stats_content);

    try stats_file.writeAll(stats_content);

    std.debug.print("\nFinBench preparation complete: {d} nodes, {d} edges\n", .{ total_nodes, total_edges });
}

fn processFinBenchNodeFile(
    allocator: std.mem.Allocator,
    snapshot_dir: std.fs.Dir,
    schema: FinBenchNodeSchema,
    out_dir: []const u8,
) !u64 {
    const in_file = try snapshot_dir.openFile(schema.filename, .{});
    defer in_file.close();

    const out_filename = try std.fmt.allocPrint(allocator, "{s}/{s}.jsonl", .{ out_dir, schema.label });
    defer allocator.free(out_filename);

    var out_file = try std.fs.cwd().createFile(out_filename, .{});
    defer out_file.close();

    const reader = in_file.deprecatedReader();
    var line_buf: [16384]u8 = undefined;

    // Read header to get column indices
    const header_line = try reader.readUntilDelimiterOrEof(&line_buf, '\n') orelse return 0;

    // Build column name to index map (need to copy strings as buffer will be reused)
    var header_names = std.ArrayList([]const u8){};
    defer {
        for (header_names.items) |name| allocator.free(name);
        header_names.deinit(allocator);
    }

    var header_iter = std.mem.splitScalar(u8, header_line, '|');
    while (header_iter.next()) |col_name| {
        try header_names.append(allocator, try allocator.dupe(u8, col_name));
    }

    // Find column indices for schema fields
    var id_col_idx: ?usize = null;
    for (header_names.items, 0..) |name, idx| {
        if (std.mem.eql(u8, name, schema.id_field)) {
            id_col_idx = idx;
            break;
        }
    }
    const id_idx = id_col_idx orelse return error.MissingIdColumn;

    // Pre-compute property column indices
    var prop_indices: [16]?usize = [_]?usize{null} ** 16;
    for (schema.properties, 0..) |prop, prop_i| {
        for (header_names.items, 0..) |name, col_i| {
            if (std.mem.eql(u8, name, prop.csv_col)) {
                prop_indices[prop_i] = col_i;
                break;
            }
        }
    }

    var count: u64 = 0;

    // Process data lines
    while (try reader.readUntilDelimiterOrEof(&line_buf, '\n')) |line| {
        if (line.len == 0) continue;

        // Split into fields
        var fields = std.ArrayList([]const u8){};
        defer fields.deinit(allocator);

        var field_iter = std.mem.splitScalar(u8, line, '|');
        while (field_iter.next()) |field| {
            try fields.append(allocator, field);
        }

        if (fields.items.len <= id_idx) continue;

        // Build JSON object
        var json_buf = std.ArrayList(u8){};
        defer json_buf.deinit(allocator);

        try json_buf.appendSlice(allocator, "{\"id\":");
        try json_buf.appendSlice(allocator, fields.items[id_idx]);

        // Add properties using pre-computed indices
        for (schema.properties, 0..) |prop, prop_i| {
            if (prop_indices[prop_i]) |prop_idx| {
                if (prop_idx < fields.items.len) {
                    const value = fields.items[prop_idx];
                    if (value.len > 0) {
                        try json_buf.appendSlice(allocator, ",\"");
                        try json_buf.appendSlice(allocator, prop.json_name);
                        try json_buf.appendSlice(allocator, "\":");
                        if (prop.is_numeric) {
                            try json_buf.appendSlice(allocator, value);
                        } else {
                            try json_buf.append(allocator, '"');
                            // Escape special characters
                            for (value) |c| {
                                switch (c) {
                                    '"' => try json_buf.appendSlice(allocator, "\\\""),
                                    '\\' => try json_buf.appendSlice(allocator, "\\\\"),
                                    '\n' => try json_buf.appendSlice(allocator, "\\n"),
                                    '\r' => try json_buf.appendSlice(allocator, "\\r"),
                                    '\t' => try json_buf.appendSlice(allocator, "\\t"),
                                    else => try json_buf.append(allocator, c),
                                }
                            }
                            try json_buf.append(allocator, '"');
                        }
                    }
                }
            }
        }

        try json_buf.appendSlice(allocator, "}\n");
        try out_file.writeAll(json_buf.items);
        count += 1;
    }

    return count;
}

fn processFinBenchEdgeFile(
    allocator: std.mem.Allocator,
    snapshot_dir: std.fs.Dir,
    schema: FinBenchEdgeSchema,
    out_dir: []const u8,
) !u64 {
    const in_file = try snapshot_dir.openFile(schema.filename, .{});
    defer in_file.close();

    // Output filename includes from/to labels for clarity
    const out_filename = try std.fmt.allocPrint(allocator, "{s}/{s}_{s}_{s}.jsonl", .{
        out_dir,
        schema.from_label,
        schema.rel_type,
        schema.to_label,
    });
    defer allocator.free(out_filename);

    var out_file = try std.fs.cwd().createFile(out_filename, .{ .truncate = false });
    defer out_file.close();
    try out_file.seekFromEnd(0);

    const reader = in_file.deprecatedReader();
    var line_buf: [16384]u8 = undefined;

    // Read header and copy column names (buffer will be reused)
    const header_line = try reader.readUntilDelimiterOrEof(&line_buf, '\n') orelse return 0;

    var header_names = std.ArrayList([]const u8){};
    defer {
        for (header_names.items) |name| allocator.free(name);
        header_names.deinit(allocator);
    }

    var header_iter = std.mem.splitScalar(u8, header_line, '|');
    while (header_iter.next()) |col_name| {
        try header_names.append(allocator, try allocator.dupe(u8, col_name));
    }

    // Find from/to column indices
    var from_col_idx: ?usize = null;
    var to_col_idx: ?usize = null;
    for (header_names.items, 0..) |name, idx| {
        if (std.mem.eql(u8, name, schema.from_id_col)) from_col_idx = idx;
        if (std.mem.eql(u8, name, schema.to_id_col)) to_col_idx = idx;
    }
    const from_idx = from_col_idx orelse return error.MissingFromColumn;
    const to_idx = to_col_idx orelse return error.MissingToColumn;

    // Pre-compute property column indices
    var prop_indices: [16]?usize = [_]?usize{null} ** 16;
    for (schema.properties, 0..) |prop, prop_i| {
        for (header_names.items, 0..) |name, col_i| {
            if (std.mem.eql(u8, name, prop.csv_col)) {
                prop_indices[prop_i] = col_i;
                break;
            }
        }
    }

    var count: u64 = 0;

    // Process data lines
    while (try reader.readUntilDelimiterOrEof(&line_buf, '\n')) |line| {
        if (line.len == 0) continue;

        var fields = std.ArrayList([]const u8){};
        defer fields.deinit(allocator);

        var field_iter = std.mem.splitScalar(u8, line, '|');
        while (field_iter.next()) |field| {
            try fields.append(allocator, field);
        }

        if (fields.items.len <= from_idx or fields.items.len <= to_idx) continue;

        // Build JSON object
        var json_buf = std.ArrayList(u8){};
        defer json_buf.deinit(allocator);

        try json_buf.appendSlice(allocator, "{\"src\":");
        try json_buf.appendSlice(allocator, fields.items[from_idx]);
        try json_buf.appendSlice(allocator, ",\"src_label\":\"");
        try json_buf.appendSlice(allocator, schema.from_label);
        try json_buf.appendSlice(allocator, "\",\"dst\":");
        try json_buf.appendSlice(allocator, fields.items[to_idx]);
        try json_buf.appendSlice(allocator, ",\"dst_label\":\"");
        try json_buf.appendSlice(allocator, schema.to_label);
        try json_buf.appendSlice(allocator, "\",\"type\":\"");
        try json_buf.appendSlice(allocator, schema.rel_type);
        try json_buf.append(allocator, '"');

        // Add properties using pre-computed indices
        for (schema.properties, 0..) |prop, prop_i| {
            if (prop_indices[prop_i]) |prop_idx| {
                if (prop_idx < fields.items.len) {
                    const value = fields.items[prop_idx];
                    if (value.len > 0) {
                        try json_buf.appendSlice(allocator, ",\"");
                        try json_buf.appendSlice(allocator, prop.json_name);
                        try json_buf.appendSlice(allocator, "\":");
                        if (prop.is_numeric) {
                            try json_buf.appendSlice(allocator, value);
                        } else {
                            try json_buf.append(allocator, '"');
                            try json_buf.appendSlice(allocator, value);
                            try json_buf.append(allocator, '"');
                        }
                    }
                }
            }
        }

        try json_buf.appendSlice(allocator, "}\n");
        try out_file.writeAll(json_buf.items);
        count += 1;
    }

    return count;
}

pub fn prepareParams(allocator: std.mem.Allocator, params_path: []const u8, out_dir: []const u8) !void {
    std.debug.print("Preparing parameter pack: {s} -> {s}\n", .{ params_path, out_dir });

    _ = allocator;

    try std.fs.cwd().makePath(out_dir);

    std.debug.print("Parameter pack prepared\n", .{});
}

pub fn verifyDataset(
    allocator: std.mem.Allocator,
    config_path: []const u8,
    dataset_id: []const u8,
    workdir: []const u8,
) !void {
    std.debug.print("Verifying dataset: {s} in {s}\n", .{ dataset_id, workdir });

    _ = config_path;

    // Read stats.json
    const stats_path = try std.fs.path.join(allocator, &[_][]const u8{ workdir, "stats.json" });
    defer allocator.free(stats_path);

    const stats_file = std.fs.cwd().openFile(stats_path, .{}) catch |err| {
        std.debug.print("Cannot read stats.json: {}\n", .{err});
        return err;
    };
    defer stats_file.close();

    const stats_content = try stats_file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stats_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, stats_content, .{});
    defer parsed.deinit();

    const node_count = parsed.value.object.get("node_count").?.integer;
    const edge_count = parsed.value.object.get("edge_count").?.integer;

    std.debug.print("Dataset statistics:\n", .{});
    std.debug.print("  Nodes: {d}\n", .{node_count});
    std.debug.print("  Edges: {d}\n", .{edge_count});

    // Verify files exist
    const nodes_dir = try std.fs.path.join(allocator, &[_][]const u8{ workdir, "nodes" });
    defer allocator.free(nodes_dir);

    const edges_dir = try std.fs.path.join(allocator, &[_][]const u8{ workdir, "edges" });
    defer allocator.free(edges_dir);

    var nodes_files: u32 = 0;
    var edges_files: u32 = 0;

    if (std.fs.cwd().openDir(nodes_dir, .{ .iterate = true })) |dir_val| {
        var dir = dir_val;
        defer dir.close();
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".jsonl")) {
                nodes_files += 1;
            }
        }
    } else |_| {}

    if (std.fs.cwd().openDir(edges_dir, .{ .iterate = true })) |dir_val| {
        var dir = dir_val;
        defer dir.close();
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".jsonl")) {
                edges_files += 1;
            }
        }
    } else |_| {}

    std.debug.print("  Node files: {d}\n", .{nodes_files});
    std.debug.print("  Edge files: {d}\n", .{edges_files});

    std.debug.print("Dataset verification complete\n", .{});
}
