// SPDX-License-Identifier: MIT
// Copyright (c) 2024-2025 CodePros
//
// Benchmark pack loading from YAML/JSON files

const std = @import("std");
const yaml = @import("yaml");

pub const BenchPack = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    description: []const u8,
    operations: []Operation,

    pub const Operation = struct {
        name: []const u8,
        query: []const u8,
        weight: f64,
        slo_ms: u32,
        params: ?[]const Parameter,

        pub const Parameter = struct {
            name: []const u8,
            type: ParamType,
            values: ?[]const []const u8, // For enum types
            min: ?i64, // For int types
            max: ?i64, // For int types
        };

        pub const ParamType = enum {
            string,
            int,
            float,
            bool,
            enum_value,
        };
    };

    pub fn deinit(self: *BenchPack, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);

        for (self.operations) |op| {
            allocator.free(op.name);
            allocator.free(op.query);
            if (op.params) |params| {
                for (params) |p| {
                    allocator.free(p.name);
                    if (p.values) |vals| {
                        for (vals) |v| allocator.free(v);
                        allocator.free(vals);
                    }
                }
                allocator.free(params);
            }
        }
        allocator.free(self.operations);
    }
};

pub const BenchPackInfo = struct {
    name: []const u8,
    description: []const u8,
    operation_count: usize,
};

/// List available benchmark packs in a directory
pub fn listBenchpacks(allocator: std.mem.Allocator, dir_path: []const u8) !std.ArrayList(BenchPackInfo) {
    var result = std.ArrayList(BenchPackInfo){};
    errdefer {
        for (result.items) |item| {
            allocator.free(item.name);
            allocator.free(item.description);
        }
        result.deinit(allocator);
    }

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            return result; // Return empty list if dir doesn't exist
        }
        return err;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;

        const is_yaml = std.mem.endsWith(u8, entry.name, ".yaml") or
            std.mem.endsWith(u8, entry.name, ".yml");
        const is_json = std.mem.endsWith(u8, entry.name, ".json");

        if (!is_yaml and !is_json) continue;

        // Extract name without extension
        const name_end = if (is_yaml)
            if (std.mem.endsWith(u8, entry.name, ".yaml"))
                entry.name.len - 5
            else
                entry.name.len - 4
        else
            entry.name.len - 5;

        const name = try allocator.dupe(u8, entry.name[0..name_end]);
        errdefer allocator.free(name);

        // Try to load the pack to get info
        var pack = loadBenchpack(allocator, dir_path, name) catch {
            allocator.free(name);
            continue;
        };
        defer pack.deinit(allocator);

        const desc = try allocator.dupe(u8, pack.description);

        try result.append(allocator, .{
            .name = name,
            .description = desc,
            .operation_count = pack.operations.len,
        });
    }

    return result;
}

/// Load a benchmark pack from file
pub fn loadBenchpack(allocator: std.mem.Allocator, dir_path: []const u8, name: []const u8) !BenchPack {
    // Try YAML first, then JSON
    const yaml_path = try std.fmt.allocPrint(allocator, "{s}/{s}.yaml", .{ dir_path, name });
    defer allocator.free(yaml_path);

    const yml_path = try std.fmt.allocPrint(allocator, "{s}/{s}.yml", .{ dir_path, name });
    defer allocator.free(yml_path);

    const json_path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ dir_path, name });
    defer allocator.free(json_path);

    // Try loading in order: .yaml, .yml, .json
    if (loadBenchpackFromFile(allocator, yaml_path)) |pack| {
        return pack;
    } else |_| {}

    if (loadBenchpackFromFile(allocator, yml_path)) |pack| {
        return pack;
    } else |_| {}

    if (loadBenchpackFromFile(allocator, json_path)) |pack| {
        return pack;
    } else |_| {}

    // Try built-in packs
    return loadBuiltinPack(allocator, name);
}

fn loadBenchpackFromFile(allocator: std.mem.Allocator, path: []const u8) !BenchPack {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024); // 10MB max
    defer allocator.free(content);

    if (std.mem.endsWith(u8, path, ".json")) {
        return parseJsonBenchpack(allocator, content);
    } else {
        return parseYamlBenchpack(allocator, content);
    }
}

fn parseYamlBenchpack(allocator: std.mem.Allocator, content: []const u8) !BenchPack {
    var docs = try yaml.loadAll(allocator, content, .{});
    defer {
        for (docs) |*d| d.deinit();
        allocator.free(docs);
    }

    if (docs.len == 0) {
        return error.EmptyDocument;
    }

    // Resolve document to value tree
    const value = try yaml.resolveToValue(allocator, &docs[0], .{});
    defer yaml.freeValue(allocator, &value);

    const root_map = value.map;

    // Get name
    const name = try getMapString(allocator, root_map, "name") orelse return error.MissingName;
    errdefer allocator.free(name);

    // Get description
    const description = try getMapString(allocator, root_map, "description") orelse try allocator.dupe(u8, "");
    errdefer allocator.free(description);

    // Get operations
    const ops_seq = getMapSeq(root_map, "operations") orelse return error.MissingOperations;

    var operations = std.ArrayList(BenchPack.Operation){};
    errdefer {
        for (operations.items) |op| {
            allocator.free(op.name);
            allocator.free(op.query);
        }
        operations.deinit(allocator);
    }

    for (ops_seq) |op_value| {
        const op_map = op_value.map;

        const op_name = try getMapString(allocator, op_map, "name") orelse try allocator.dupe(u8, "");
        const op_query = try getMapString(allocator, op_map, "query") orelse try allocator.dupe(u8, "");
        const op_weight = getMapFloat(op_map, "weight") orelse 1.0;
        const op_slo: u32 = @intCast(getMapInt(op_map, "slo_ms") orelse 100);

        try operations.append(allocator, .{
            .name = op_name,
            .query = op_query,
            .weight = op_weight,
            .slo_ms = op_slo,
            .params = null,
        });
    }

    return BenchPack{
        .allocator = allocator,
        .name = name,
        .description = description,
        .operations = try operations.toOwnedSlice(allocator),
    };
}

// Helper functions for accessing YAML map values
fn getMapString(allocator: std.mem.Allocator, map: []const yaml.ValueKVPair, key: []const u8) !?[]const u8 {
    for (map) |pair| {
        if (pair.k == .str and std.mem.eql(u8, pair.k.str, key)) {
            if (pair.v == .str) {
                return try allocator.dupe(u8, pair.v.str);
            }
        }
    }
    return null;
}

fn getMapSeq(map: []const yaml.ValueKVPair, key: []const u8) ?[]const yaml.Value {
    for (map) |pair| {
        if (pair.k == .str and std.mem.eql(u8, pair.k.str, key)) {
            if (pair.v == .seq) {
                return pair.v.seq;
            }
        }
    }
    return null;
}

fn getMapFloat(map: []const yaml.ValueKVPair, key: []const u8) ?f64 {
    for (map) |pair| {
        if (pair.k == .str and std.mem.eql(u8, pair.k.str, key)) {
            return switch (pair.v) {
                .float => pair.v.float,
                .int => @floatFromInt(pair.v.int),
                else => null,
            };
        }
    }
    return null;
}

fn getMapInt(map: []const yaml.ValueKVPair, key: []const u8) ?i64 {
    for (map) |pair| {
        if (pair.k == .str and std.mem.eql(u8, pair.k.str, key)) {
            if (pair.v == .int) {
                return pair.v.int;
            }
        }
    }
    return null;
}

fn getMapBool(map: []const yaml.ValueKVPair, key: []const u8) ?bool {
    for (map) |pair| {
        if (pair.k == .str and std.mem.eql(u8, pair.k.str, key)) {
            if (pair.v == .bool) {
                return pair.v.bool;
            }
        }
    }
    return null;
}

fn parseJsonBenchpack(allocator: std.mem.Allocator, content: []const u8) !BenchPack {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    // Get name
    const name_val = root.get("name") orelse return error.MissingName;
    const name = try allocator.dupe(u8, name_val.string);
    errdefer allocator.free(name);

    // Get description
    const description = if (root.get("description")) |d|
        try allocator.dupe(u8, d.string)
    else
        try allocator.dupe(u8, "");
    errdefer allocator.free(description);

    // Get operations
    const ops_val = root.get("operations") orelse return error.MissingOperations;
    const ops_arr = ops_val.array;

    var operations = std.ArrayList(BenchPack.Operation){};
    errdefer {
        for (operations.items) |op| {
            allocator.free(op.name);
            allocator.free(op.query);
        }
        operations.deinit(allocator);
    }

    for (ops_arr.items) |op_val| {
        const op_obj = op_val.object;

        const op_name = if (op_obj.get("name")) |n|
            try allocator.dupe(u8, n.string)
        else
            try allocator.dupe(u8, "");

        const op_query = if (op_obj.get("query")) |q|
            try allocator.dupe(u8, q.string)
        else
            try allocator.dupe(u8, "");

        const op_weight: f64 = if (op_obj.get("weight")) |w|
            switch (w) {
                .float => w.float,
                .integer => @floatFromInt(w.integer),
                else => 1.0,
            }
        else
            1.0;

        const op_slo: u32 = if (op_obj.get("slo_ms")) |s|
            @intCast(s.integer)
        else
            100;

        try operations.append(allocator, .{
            .name = op_name,
            .query = op_query,
            .weight = op_weight,
            .slo_ms = op_slo,
            .params = null,
        });
    }

    return BenchPack{
        .allocator = allocator,
        .name = name,
        .description = description,
        .operations = try operations.toOwnedSlice(allocator),
    };
}

/// Load built-in benchmark packs
fn loadBuiltinPack(allocator: std.mem.Allocator, name: []const u8) !BenchPack {
    if (std.mem.eql(u8, name, "gdc_micro_primitives")) {
        return loadGdcMicroPrimitives(allocator);
    } else if (std.mem.eql(u8, name, "gdc_graph_algorithms")) {
        return loadGdcGraphAlgorithms(allocator);
    } else if (std.mem.eql(u8, name, "gdc_crud_operations")) {
        return loadGdcCrudOperations(allocator);
    } else if (std.mem.eql(u8, name, "finbench") or std.mem.eql(u8, name, "ldbc_finbench")) {
        return loadFinBench(allocator);
    }

    return error.BenchPackNotFound;
}

fn loadGdcMicroPrimitives(allocator: std.mem.Allocator) !BenchPack {
    var operations = std.ArrayList(BenchPack.Operation){};
    errdefer operations.deinit(allocator);

    try operations.append(allocator, .{
        .name = try allocator.dupe(u8, "point_lookup"),
        .query = try allocator.dupe(u8, "MATCH (n) WHERE id(n) = $id RETURN n"),
        .weight = 1.0,
        .slo_ms = 50,
        .params = null,
    });

    try operations.append(allocator, .{
        .name = try allocator.dupe(u8, "k_hop_traversal_1"),
        .query = try allocator.dupe(u8, "MATCH (start)-[*1..1]-(neighbor) WHERE id(start) = $id RETURN neighbor LIMIT 10"),
        .weight = 1.0,
        .slo_ms = 100,
        .params = null,
    });

    try operations.append(allocator, .{
        .name = try allocator.dupe(u8, "k_hop_traversal_2"),
        .query = try allocator.dupe(u8, "MATCH (start)-[*1..2]-(neighbor) WHERE id(start) = $id RETURN neighbor LIMIT 10"),
        .weight = 1.0,
        .slo_ms = 150,
        .params = null,
    });

    try operations.append(allocator, .{
        .name = try allocator.dupe(u8, "property_filter"),
        .query = try allocator.dupe(u8, "MATCH (n) WHERE n.age > $min_age RETURN n LIMIT 100"),
        .weight = 0.5,
        .slo_ms = 100,
        .params = null,
    });

    try operations.append(allocator, .{
        .name = try allocator.dupe(u8, "count_nodes"),
        .query = try allocator.dupe(u8, "MATCH (n) RETURN count(n)"),
        .weight = 0.25,
        .slo_ms = 200,
        .params = null,
    });

    return BenchPack{
        .allocator = allocator,
        .name = try allocator.dupe(u8, "gdc_micro_primitives"),
        .description = try allocator.dupe(u8, "GDC-aligned micro-benchmark primitives for graph operations"),
        .operations = try operations.toOwnedSlice(allocator),
    };
}

fn loadGdcGraphAlgorithms(allocator: std.mem.Allocator) !BenchPack {
    var operations = std.ArrayList(BenchPack.Operation){};
    errdefer operations.deinit(allocator);

    try operations.append(allocator, .{
        .name = try allocator.dupe(u8, "shortest_path"),
        .query = try allocator.dupe(u8, "MATCH path = shortestPath((a)-[*]-(b)) WHERE id(a) = $src AND id(b) = $dst RETURN path"),
        .weight = 1.0,
        .slo_ms = 500,
        .params = null,
    });

    try operations.append(allocator, .{
        .name = try allocator.dupe(u8, "all_shortest_paths"),
        .query = try allocator.dupe(u8, "MATCH path = allShortestPaths((a)-[*]-(b)) WHERE id(a) = $src AND id(b) = $dst RETURN path"),
        .weight = 0.5,
        .slo_ms = 1000,
        .params = null,
    });

    try operations.append(allocator, .{
        .name = try allocator.dupe(u8, "connected_components"),
        .query = try allocator.dupe(u8, "CALL gql.connectedComponents() YIELD nodeId, componentId RETURN componentId, count(*) AS size ORDER BY size DESC LIMIT 10"),
        .weight = 0.25,
        .slo_ms = 5000,
        .params = null,
    });

    return BenchPack{
        .allocator = allocator,
        .name = try allocator.dupe(u8, "gdc_graph_algorithms"),
        .description = try allocator.dupe(u8, "GDC-aligned graph algorithm benchmarks"),
        .operations = try operations.toOwnedSlice(allocator),
    };
}

fn loadGdcCrudOperations(allocator: std.mem.Allocator) !BenchPack {
    var operations = std.ArrayList(BenchPack.Operation){};
    errdefer operations.deinit(allocator);

    try operations.append(allocator, .{
        .name = try allocator.dupe(u8, "create_node"),
        .query = try allocator.dupe(u8, "CREATE (n:TestNode {id: $id, name: $name, timestamp: $ts}) RETURN n"),
        .weight = 1.0,
        .slo_ms = 50,
        .params = null,
    });

    try operations.append(allocator, .{
        .name = try allocator.dupe(u8, "update_node"),
        .query = try allocator.dupe(u8, "MATCH (n) WHERE id(n) = $id SET n.updated = $ts RETURN n"),
        .weight = 1.0,
        .slo_ms = 50,
        .params = null,
    });

    try operations.append(allocator, .{
        .name = try allocator.dupe(u8, "delete_node"),
        .query = try allocator.dupe(u8, "MATCH (n:TestNode) WHERE n.id = $id DETACH DELETE n"),
        .weight = 0.5,
        .slo_ms = 100,
        .params = null,
    });

    try operations.append(allocator, .{
        .name = try allocator.dupe(u8, "create_relationship"),
        .query = try allocator.dupe(u8, "MATCH (a), (b) WHERE id(a) = $src AND id(b) = $dst CREATE (a)-[r:TEST_REL {weight: $weight}]->(b) RETURN r"),
        .weight = 1.0,
        .slo_ms = 75,
        .params = null,
    });

    return BenchPack{
        .allocator = allocator,
        .name = try allocator.dupe(u8, "gdc_crud_operations"),
        .description = try allocator.dupe(u8, "GDC-aligned CRUD operation benchmarks"),
        .operations = try operations.toOwnedSlice(allocator),
    };
}

fn loadFinBench(allocator: std.mem.Allocator) !BenchPack {
    var operations = std.ArrayList(BenchPack.Operation){};
    errdefer operations.deinit(allocator);

    // Simple read queries
    try operations.append(allocator, .{
        .name = try allocator.dupe(u8, "count_persons"),
        .query = try allocator.dupe(u8, "MATCH (p:Person) RETURN count(p) as count"),
        .weight = 1.0,
        .slo_ms = 100,
        .params = null,
    });

    try operations.append(allocator, .{
        .name = try allocator.dupe(u8, "count_accounts"),
        .query = try allocator.dupe(u8, "MATCH (a:Account) RETURN count(a) as count"),
        .weight = 1.0,
        .slo_ms = 100,
        .params = null,
    });

    try operations.append(allocator, .{
        .name = try allocator.dupe(u8, "find_person_by_id"),
        .query = try allocator.dupe(u8, "MATCH (p:Person {id: $id}) RETURN p.name, p.country"),
        .weight = 2.0,
        .slo_ms = 50,
        .params = null,
    });

    try operations.append(allocator, .{
        .name = try allocator.dupe(u8, "person_accounts"),
        .query = try allocator.dupe(u8, "MATCH (p:Person {id: $id})-[:OWN]->(a:Account) RETURN p.name, a.id LIMIT 10"),
        .weight = 2.0,
        .slo_ms = 100,
        .params = null,
    });

    try operations.append(allocator, .{
        .name = try allocator.dupe(u8, "account_transfers"),
        .query = try allocator.dupe(u8, "MATCH (a1:Account {id: $id})-[t:TRANSFER]->(a2:Account) RETURN a1.id, t.amount, a2.id LIMIT 10"),
        .weight = 2.0,
        .slo_ms = 100,
        .params = null,
    });

    try operations.append(allocator, .{
        .name = try allocator.dupe(u8, "persons_by_country"),
        .query = try allocator.dupe(u8, "MATCH (p:Person) WHERE p.country = $name RETURN p.name, p.city LIMIT 20"),
        .weight = 1.5,
        .slo_ms = 100,
        .params = null,
    });

    try operations.append(allocator, .{
        .name = try allocator.dupe(u8, "loan_repayments"),
        .query = try allocator.dupe(u8, "MATCH (a:Account {id: $id})-[r:REPAY]->(l:Loan) RETURN a.id, r.amount, l.id LIMIT 10"),
        .weight = 1.5,
        .slo_ms = 100,
        .params = null,
    });

    try operations.append(allocator, .{
        .name = try allocator.dupe(u8, "person_investments"),
        .query = try allocator.dupe(u8, "MATCH (p:Person {id: $id})-[i:INVEST]->(c:Company) RETURN p.name, i.ratio, c.name LIMIT 10"),
        .weight = 1.5,
        .slo_ms = 100,
        .params = null,
    });

    try operations.append(allocator, .{
        .name = try allocator.dupe(u8, "transfer_path"),
        .query = try allocator.dupe(u8, "MATCH (a1:Account)-[:TRANSFER]->(a2:Account)-[:TRANSFER]->(a3:Account) RETURN a1.id, a2.id, a3.id LIMIT 5"),
        .weight = 1.0,
        .slo_ms = 200,
        .params = null,
    });

    try operations.append(allocator, .{
        .name = try allocator.dupe(u8, "guarantee_chain"),
        .query = try allocator.dupe(u8, "MATCH (p1:Person)-[:GUARANTEE]->(p2:Person) RETURN p1.name, p2.name LIMIT 10"),
        .weight = 1.0,
        .slo_ms = 100,
        .params = null,
    });

    return BenchPack{
        .allocator = allocator,
        .name = try allocator.dupe(u8, "finbench"),
        .description = try allocator.dupe(u8, "LDBC FinBench financial graph benchmark queries"),
        .operations = try operations.toOwnedSlice(allocator),
    };
}

// ============================================================================
// Tests
// ============================================================================

test "load builtin gdc_micro_primitives" {
    const allocator = std.testing.allocator;

    var pack = try loadBuiltinPack(allocator, "gdc_micro_primitives");
    defer pack.deinit(allocator);

    try std.testing.expectEqualStrings("gdc_micro_primitives", pack.name);
    try std.testing.expect(pack.operations.len >= 4);
}

test "parse json benchpack" {
    const allocator = std.testing.allocator;

    const json_content =
        \\{
        \\  "name": "test_pack",
        \\  "description": "Test benchmark pack",
        \\  "operations": [
        \\    {"name": "op1", "query": "MATCH (n) RETURN n", "weight": 1.0, "slo_ms": 100}
        \\  ]
        \\}
    ;

    var pack = try parseJsonBenchpack(allocator, json_content);
    defer pack.deinit(allocator);

    try std.testing.expectEqualStrings("test_pack", pack.name);
    try std.testing.expectEqual(@as(usize, 1), pack.operations.len);
}
