// SPDX-License-Identifier: MIT
// Copyright (c) 2024-2025 CodePros
//
// Configuration loading with YAML and JSON support

const std = @import("std");
const yaml = @import("yaml");

pub const BenchConfig = struct {
    allocator: std.mem.Allocator,
    db: DbConfig,
    scenario: ScenarioConfig,
    workload: WorkloadConfig,
    dataset: ?DatasetConfig,
    loader: ?LoaderConfig,

    pub fn deinit(self: *BenchConfig) void {
        self.allocator.free(self.db.host);
        if (self.db.auth_token_env) |token| self.allocator.free(token);
        self.allocator.free(self.scenario.durability);
        self.allocator.free(self.scenario.consistency);
        self.allocator.free(self.scenario.cache_state);
        self.allocator.free(self.scenario.db_version);
        self.allocator.free(self.workload.benchpack);

        if (self.dataset) |ds| {
            self.allocator.free(ds.dataset_id);
            self.allocator.free(ds.workdir);
        }

        if (self.loader) |ld| {
            if (ld.insert_node_template) |t| self.allocator.free(t);
            if (ld.insert_edge_template) |t| self.allocator.free(t);
        }
    }
};

pub const DbConfig = struct {
    host: []const u8,
    port: u16,
    transport: TransportProfile,
    auth_token_env: ?[]const u8,
    timeout_ms: u32,
};

pub const TransportProfile = enum {
    quic_tls_strict,
    quic_tls_insecure,
};

pub const ScenarioConfig = struct {
    network_mode: NetworkMode,
    netem: ?NetemConfig,
    durability: []const u8,
    consistency: []const u8,
    cache_state: []const u8,
    db_version: []const u8,
};

pub const NetworkMode = enum {
    loopback,
    remote,
    netem,
};

pub const NetemConfig = struct {
    rtt_ms: ?u32,
    jitter_ms: ?u32,
    loss_pct: ?f32,
};

pub const WorkloadConfig = struct {
    benchpack: []const u8,
    mode: LoadMode,
    duration_sec: ?u32,
    target_qps: ?u32,
    workers: ?u32,
    in_flight_per_worker: ?u32,
    slo_ms: u32,
    violation_threshold: f64,
    error_threshold: f64,
};

pub const LoadMode = enum {
    closed_loop,
    open_loop,
};

pub const DatasetConfig = struct {
    dataset_id: []const u8,
    workdir: []const u8,
    auto_load: bool,
    skip_load: bool,
};

pub const LoaderConfig = struct {
    type: LoaderType,
    batch_size: u32,
    external_command: ?[]const []const u8,
    insert_node_template: ?[]const u8,
    insert_edge_template: ?[]const u8,
};

pub const LoaderType = enum {
    external,
    quic_gql_batch,
};

pub const SweepConfig = struct {
    base: BenchConfig,
    sweep: SweepDimension,

    pub fn deinit(self: *SweepConfig) void {
        self.base.deinit();
        self.base.allocator.free(self.sweep.parameter);
        self.base.allocator.free(self.sweep.values);
    }
};

pub const SweepDimension = struct {
    parameter: []const u8,
    values: []const u32,
};

/// Load configuration from file (auto-detects YAML or JSON)
pub fn loadConfig(allocator: std.mem.Allocator, path: []const u8) !BenchConfig {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    // Detect format by extension or content
    const is_yaml = std.mem.endsWith(u8, path, ".yaml") or
        std.mem.endsWith(u8, path, ".yml") or
        (content.len > 0 and content[0] != '{');

    if (is_yaml) {
        return parseYamlConfig(allocator, content);
    } else {
        return parseJsonConfig(allocator, content);
    }
}

fn parseYamlConfig(allocator: std.mem.Allocator, content: []const u8) !BenchConfig {
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

    // Parse DB config
    const db_map = getMapMap(root_map, "db") orelse return error.MissingDbConfig;
    const db = try parseYamlDbConfigFromValue(allocator, db_map);
    errdefer allocator.free(db.host);

    // Parse scenario config
    const scenario_map = getMapMap(root_map, "scenario");
    const scenario = try parseYamlScenarioConfigFromValue(allocator, scenario_map);
    errdefer {
        allocator.free(scenario.durability);
        allocator.free(scenario.consistency);
        allocator.free(scenario.cache_state);
        allocator.free(scenario.db_version);
    }

    // Parse workload config
    const workload_map = getMapMap(root_map, "workload") orelse return error.MissingWorkloadConfig;
    const workload = try parseYamlWorkloadConfigFromValue(allocator, workload_map);
    errdefer allocator.free(workload.benchpack);

    // Parse optional dataset config
    const dataset = if (getMapMap(root_map, "dataset")) |ds_map|
        try parseYamlDatasetConfigFromValue(allocator, ds_map)
    else
        null;

    // Parse optional loader config
    const loader_config = if (getMapMap(root_map, "loader")) |ld_map|
        try parseYamlLoaderConfigFromValue(allocator, ld_map)
    else
        null;

    return BenchConfig{
        .allocator = allocator,
        .db = db,
        .scenario = scenario,
        .workload = workload,
        .dataset = dataset,
        .loader = loader_config,
    };
}

// Helper to get a map value from a map
fn getMapMap(map: []const yaml.ValueKVPair, key: []const u8) ?[]const yaml.ValueKVPair {
    for (map) |pair| {
        if (pair.k == .str and std.mem.eql(u8, pair.k.str, key)) {
            if (pair.v == .map) {
                return pair.v.map;
            }
        }
    }
    return null;
}

fn getMapStr(map: []const yaml.ValueKVPair, key: []const u8) ?[]const u8 {
    for (map) |pair| {
        if (pair.k == .str and std.mem.eql(u8, pair.k.str, key)) {
            if (pair.v == .str) {
                return pair.v.str;
            }
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

fn parseYamlDbConfigFromValue(allocator: std.mem.Allocator, map: []const yaml.ValueKVPair) !DbConfig {
    const host = getMapStr(map, "host") orelse "127.0.0.1";
    const port: u16 = if (getMapInt(map, "port")) |p| @intCast(p) else 3141;

    var transport: TransportProfile = .quic_tls_insecure;
    if (getMapStr(map, "transport")) |t| {
        if (std.mem.eql(u8, t, "quic_tls_strict")) {
            transport = .quic_tls_strict;
        }
    }

    const auth_token_env: ?[]const u8 = if (getMapStr(map, "auth_token_env")) |t|
        try allocator.dupe(u8, t)
    else
        null;

    const timeout_ms: u32 = if (getMapInt(map, "timeout_ms")) |t| @intCast(t) else 30000;

    return DbConfig{
        .host = try allocator.dupe(u8, host),
        .port = port,
        .transport = transport,
        .auth_token_env = auth_token_env,
        .timeout_ms = timeout_ms,
    };
}

fn parseYamlScenarioConfigFromValue(allocator: std.mem.Allocator, map: ?[]const yaml.ValueKVPair) !ScenarioConfig {
    var network_mode: NetworkMode = .loopback;
    var durability: []const u8 = "fsync";
    var consistency: []const u8 = "serializable";
    var cache_state: []const u8 = "warm";
    var db_version: []const u8 = "0.1.0";

    if (map) |m| {
        if (getMapStr(m, "network_mode")) |s| {
            if (std.mem.eql(u8, s, "remote")) {
                network_mode = .remote;
            } else if (std.mem.eql(u8, s, "netem")) {
                network_mode = .netem;
            }
        }
        if (getMapStr(m, "durability")) |s| durability = s;
        if (getMapStr(m, "consistency")) |s| consistency = s;
        if (getMapStr(m, "cache_state")) |s| cache_state = s;
        if (getMapStr(m, "db_version")) |s| db_version = s;
    }

    return ScenarioConfig{
        .network_mode = network_mode,
        .netem = null,
        .durability = try allocator.dupe(u8, durability),
        .consistency = try allocator.dupe(u8, consistency),
        .cache_state = try allocator.dupe(u8, cache_state),
        .db_version = try allocator.dupe(u8, db_version),
    };
}

fn parseYamlWorkloadConfigFromValue(allocator: std.mem.Allocator, map: []const yaml.ValueKVPair) !WorkloadConfig {
    var benchpack: []const u8 = "gdc_micro_primitives";
    var mode: LoadMode = .closed_loop;
    var duration_sec: ?u32 = null;
    var target_qps: ?u32 = null;
    var workers: ?u32 = null;
    var in_flight_per_worker: ?u32 = null;
    var slo_ms: u32 = 100;
    var violation_threshold: f64 = 0.05;
    var error_threshold: f64 = 0.0;

    if (getMapStr(map, "benchpack")) |s| benchpack = s;
    if (getMapStr(map, "mode")) |s| {
        if (std.mem.eql(u8, s, "open_loop")) mode = .open_loop;
    }
    if (getMapInt(map, "duration_sec")) |i| duration_sec = @intCast(i);
    if (getMapInt(map, "target_qps")) |i| target_qps = @intCast(i);
    if (getMapInt(map, "workers")) |i| workers = @intCast(i);
    if (getMapInt(map, "in_flight_per_worker")) |i| in_flight_per_worker = @intCast(i);
    if (getMapInt(map, "slo_ms")) |i| slo_ms = @intCast(i);
    if (getMapFloat(map, "violation_threshold")) |f| violation_threshold = f;
    if (getMapFloat(map, "error_threshold")) |f| error_threshold = f;

    return WorkloadConfig{
        .benchpack = try allocator.dupe(u8, benchpack),
        .mode = mode,
        .duration_sec = duration_sec,
        .target_qps = target_qps,
        .workers = workers,
        .in_flight_per_worker = in_flight_per_worker,
        .slo_ms = slo_ms,
        .violation_threshold = violation_threshold,
        .error_threshold = error_threshold,
    };
}

fn parseYamlDatasetConfigFromValue(allocator: std.mem.Allocator, map: []const yaml.ValueKVPair) !DatasetConfig {
    const dataset_id = getMapStr(map, "dataset_id") orelse "";
    const workdir = getMapStr(map, "workdir") orelse "work/";
    const auto_load = getMapBool(map, "auto_load") orelse false;
    const skip_load = getMapBool(map, "skip_load") orelse false;

    return DatasetConfig{
        .dataset_id = try allocator.dupe(u8, dataset_id),
        .workdir = try allocator.dupe(u8, workdir),
        .auto_load = auto_load,
        .skip_load = skip_load,
    };
}

fn parseYamlLoaderConfigFromValue(allocator: std.mem.Allocator, map: []const yaml.ValueKVPair) !LoaderConfig {
    var loader_type: LoaderType = .quic_gql_batch;
    var batch_size: u32 = 100;
    var insert_node_template: ?[]const u8 = null;
    var insert_edge_template: ?[]const u8 = null;

    if (getMapStr(map, "type")) |s| {
        if (std.mem.eql(u8, s, "external")) loader_type = .external;
    }
    if (getMapInt(map, "batch_size")) |i| batch_size = @intCast(i);
    if (getMapStr(map, "insert_node_template")) |s| insert_node_template = try allocator.dupe(u8, s);
    if (getMapStr(map, "insert_edge_template")) |s| insert_edge_template = try allocator.dupe(u8, s);

    return LoaderConfig{
        .type = loader_type,
        .batch_size = batch_size,
        .external_command = null,
        .insert_node_template = insert_node_template,
        .insert_edge_template = insert_edge_template,
    };
}

fn parseJsonConfig(allocator: std.mem.Allocator, content: []const u8) !BenchConfig {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    // Parse DB config
    const db_obj = root.get("db").?.object;
    const host = try allocator.dupe(u8, db_obj.get("host").?.string);
    errdefer allocator.free(host);

    const port: u16 = @intCast(db_obj.get("port").?.integer);

    const transport_str = db_obj.get("transport").?.string;
    const transport: TransportProfile = if (std.mem.eql(u8, transport_str, "quic_tls_insecure"))
        .quic_tls_insecure
    else
        .quic_tls_strict;

    const auth_token_env = if (db_obj.get("auth_token_env")) |v|
        try allocator.dupe(u8, v.string)
    else
        null;
    errdefer if (auth_token_env) |t| allocator.free(t);

    const timeout_ms: u32 = @intCast(db_obj.get("timeout_ms").?.integer);

    // Parse scenario
    const scenario_obj = root.get("scenario").?.object;
    const network_mode_str = scenario_obj.get("network_mode").?.string;
    const network_mode: NetworkMode = if (std.mem.eql(u8, network_mode_str, "remote"))
        .remote
    else if (std.mem.eql(u8, network_mode_str, "netem"))
        .netem
    else
        .loopback;

    const durability = try allocator.dupe(u8, scenario_obj.get("durability").?.string);
    errdefer allocator.free(durability);

    const consistency = try allocator.dupe(u8, scenario_obj.get("consistency").?.string);
    errdefer allocator.free(consistency);

    const cache_state = try allocator.dupe(u8, scenario_obj.get("cache_state").?.string);
    errdefer allocator.free(cache_state);

    const db_version = try allocator.dupe(u8, scenario_obj.get("db_version").?.string);
    errdefer allocator.free(db_version);

    // Parse workload
    const workload_obj = root.get("workload").?.object;
    const benchpack = try allocator.dupe(u8, workload_obj.get("benchpack").?.string);
    errdefer allocator.free(benchpack);

    const mode_str = workload_obj.get("mode").?.string;
    const mode: LoadMode = if (std.mem.eql(u8, mode_str, "open_loop"))
        .open_loop
    else
        .closed_loop;

    const duration_sec = if (workload_obj.get("duration_sec")) |v| @as(u32, @intCast(v.integer)) else null;
    const target_qps = if (workload_obj.get("target_qps")) |v| @as(u32, @intCast(v.integer)) else null;
    const workers = if (workload_obj.get("workers")) |v| @as(u32, @intCast(v.integer)) else null;
    const in_flight_per_worker = if (workload_obj.get("in_flight_per_worker")) |v| @as(u32, @intCast(v.integer)) else null;
    const slo_ms: u32 = @intCast(workload_obj.get("slo_ms").?.integer);
    const violation_threshold = workload_obj.get("violation_threshold").?.float;
    const error_threshold = workload_obj.get("error_threshold").?.float;

    // Parse dataset (optional)
    var dataset: ?DatasetConfig = null;
    if (root.get("dataset")) |dataset_val| {
        const dataset_obj = dataset_val.object;
        dataset = DatasetConfig{
            .dataset_id = try allocator.dupe(u8, dataset_obj.get("dataset_id").?.string),
            .workdir = try allocator.dupe(u8, dataset_obj.get("workdir").?.string),
            .auto_load = dataset_obj.get("auto_load").?.bool,
            .skip_load = dataset_obj.get("skip_load").?.bool,
        };
    }

    // Parse loader (optional)
    var loader_config: ?LoaderConfig = null;
    if (root.get("loader")) |loader_val| {
        const loader_obj = loader_val.object;
        const loader_type_str = loader_obj.get("type").?.string;
        const loader_type: LoaderType = if (std.mem.eql(u8, loader_type_str, "external"))
            .external
        else
            .quic_gql_batch;

        const insert_node = if (loader_obj.get("insert_node_template")) |v|
            try allocator.dupe(u8, v.string)
        else
            null;
        const insert_edge = if (loader_obj.get("insert_edge_template")) |v|
            try allocator.dupe(u8, v.string)
        else
            null;

        loader_config = LoaderConfig{
            .type = loader_type,
            .batch_size = @intCast(loader_obj.get("batch_size").?.integer),
            .external_command = null,
            .insert_node_template = insert_node,
            .insert_edge_template = insert_edge,
        };
    }

    return BenchConfig{
        .allocator = allocator,
        .db = DbConfig{
            .host = host,
            .port = port,
            .transport = transport,
            .auth_token_env = auth_token_env,
            .timeout_ms = timeout_ms,
        },
        .scenario = ScenarioConfig{
            .network_mode = network_mode,
            .netem = null,
            .durability = durability,
            .consistency = consistency,
            .cache_state = cache_state,
            .db_version = db_version,
        },
        .workload = WorkloadConfig{
            .benchpack = benchpack,
            .mode = mode,
            .duration_sec = duration_sec,
            .target_qps = target_qps,
            .workers = workers,
            .in_flight_per_worker = in_flight_per_worker,
            .slo_ms = slo_ms,
            .violation_threshold = violation_threshold,
            .error_threshold = error_threshold,
        },
        .dataset = dataset,
        .loader = loader_config,
    };
}

pub fn loadSweepConfig(allocator: std.mem.Allocator, path: []const u8) !SweepConfig {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    // Load base config first
    var base = try loadConfig(allocator, path);
    errdefer base.deinit();

    // Try to parse sweep section
    const is_yaml = std.mem.endsWith(u8, path, ".yaml") or std.mem.endsWith(u8, path, ".yml");

    var parameter: []const u8 = "in_flight_per_worker";
    var values: []u32 = &.{};

    if (is_yaml) {
        var docs = try yaml.loadAll(allocator, content, .{});
        defer {
            for (docs) |*d| d.deinit();
            allocator.free(docs);
        }

        if (docs.len > 0) {
            const value = try yaml.resolveToValue(allocator, &docs[0], .{});
            defer yaml.freeValue(allocator, &value);

            if (value == .map) {
                if (getMapMap(value.map, "sweep")) |sweep_map| {
                    if (getMapStr(sweep_map, "parameter")) |s| parameter = s;
                    if (getMapSeq(sweep_map, "values")) |seq| {
                        var vals = std.ArrayList(u32){};
                        for (seq) |item| {
                            if (item == .int) {
                                try vals.append(allocator, @intCast(item.int));
                            }
                        }
                        values = try vals.toOwnedSlice(allocator);
                    }
                }
            }
        }
    } else {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
        defer parsed.deinit();

        if (parsed.value.object.get("sweep")) |sweep_val| {
            const sweep_obj = sweep_val.object;
            if (sweep_obj.get("parameter")) |p| {
                parameter = p.string;
            }
            if (sweep_obj.get("values")) |v| {
                var vals = std.ArrayList(u32){};
                for (v.array.items) |item| {
                    try vals.append(allocator, @intCast(item.integer));
                }
                values = try vals.toOwnedSlice(allocator);
            }
        }
    }

    // Default values if not specified
    if (values.len == 0) {
        var vals = std.ArrayList(u32){};
        try vals.appendSlice(allocator, &[_]u32{ 1, 5, 10, 20, 50, 100 });
        values = try vals.toOwnedSlice(allocator);
    }

    return SweepConfig{
        .base = base,
        .sweep = SweepDimension{
            .parameter = try allocator.dupe(u8, parameter),
            .values = values,
        },
    };
}

// Unit Tests

test "parseJsonConfig - minimal config" {
    const allocator = std.testing.allocator;

    const json_content =
        \\{
        \\  "db": {
        \\    "host": "localhost",
        \\    "port": 3141,
        \\    "transport": "quic_tls_insecure",
        \\    "timeout_ms": 30000
        \\  },
        \\  "scenario": {
        \\    "network_mode": "loopback",
        \\    "durability": "fsync",
        \\    "consistency": "serializable",
        \\    "cache_state": "warm",
        \\    "db_version": "0.1.0"
        \\  },
        \\  "workload": {
        \\    "benchpack": "gdc_micro_primitives",
        \\    "mode": "closed_loop",
        \\    "duration_sec": 10,
        \\    "workers": 2,
        \\    "slo_ms": 100,
        \\    "violation_threshold": 0.05,
        \\    "error_threshold": 0.0
        \\  }
        \\}
    ;

    var config_result = try parseJsonConfig(allocator, json_content);
    defer config_result.deinit();

    try std.testing.expectEqualStrings("localhost", config_result.db.host);
    try std.testing.expectEqual(@as(u16, 3141), config_result.db.port);
    try std.testing.expectEqual(TransportProfile.quic_tls_insecure, config_result.db.transport);
    try std.testing.expectEqual(@as(u32, 30000), config_result.db.timeout_ms);
    try std.testing.expectEqual(NetworkMode.loopback, config_result.scenario.network_mode);
    try std.testing.expectEqualStrings("gdc_micro_primitives", config_result.workload.benchpack);
    try std.testing.expectEqual(LoadMode.closed_loop, config_result.workload.mode);
    try std.testing.expectEqual(@as(u32, 100), config_result.workload.slo_ms);
}

test "parseJsonConfig - strict transport" {
    const allocator = std.testing.allocator;

    const json_content =
        \\{
        \\  "db": {
        \\    "host": "remote.server.com",
        \\    "port": 8443,
        \\    "transport": "quic_tls_strict",
        \\    "timeout_ms": 60000
        \\  },
        \\  "scenario": {
        \\    "network_mode": "remote",
        \\    "durability": "async",
        \\    "consistency": "eventual",
        \\    "cache_state": "cold",
        \\    "db_version": "1.0.0"
        \\  },
        \\  "workload": {
        \\    "benchpack": "finbench",
        \\    "mode": "open_loop",
        \\    "target_qps": 1000,
        \\    "slo_ms": 50,
        \\    "violation_threshold": 0.01,
        \\    "error_threshold": 0.001
        \\  }
        \\}
    ;

    var config_result = try parseJsonConfig(allocator, json_content);
    defer config_result.deinit();

    try std.testing.expectEqualStrings("remote.server.com", config_result.db.host);
    try std.testing.expectEqual(@as(u16, 8443), config_result.db.port);
    try std.testing.expectEqual(TransportProfile.quic_tls_strict, config_result.db.transport);
    try std.testing.expectEqual(NetworkMode.remote, config_result.scenario.network_mode);
    try std.testing.expectEqual(LoadMode.open_loop, config_result.workload.mode);
    try std.testing.expectEqual(@as(?u32, 1000), config_result.workload.target_qps);
}

test "parseJsonConfig - with dataset config" {
    const allocator = std.testing.allocator;

    const json_content =
        \\{
        \\  "db": {
        \\    "host": "127.0.0.1",
        \\    "port": 3141,
        \\    "transport": "quic_tls_insecure",
        \\    "timeout_ms": 30000
        \\  },
        \\  "scenario": {
        \\    "network_mode": "loopback",
        \\    "durability": "fsync",
        \\    "consistency": "serializable",
        \\    "cache_state": "warm",
        \\    "db_version": "0.1.0"
        \\  },
        \\  "workload": {
        \\    "benchpack": "finbench",
        \\    "mode": "closed_loop",
        \\    "slo_ms": 100,
        \\    "violation_threshold": 0.05,
        \\    "error_threshold": 0.0
        \\  },
        \\  "dataset": {
        \\    "dataset_id": "sf1",
        \\    "workdir": "/tmp/work",
        \\    "auto_load": true,
        \\    "skip_load": false
        \\  }
        \\}
    ;

    var config_result = try parseJsonConfig(allocator, json_content);
    defer config_result.deinit();

    try std.testing.expect(config_result.dataset != null);
    try std.testing.expectEqualStrings("sf1", config_result.dataset.?.dataset_id);
    try std.testing.expectEqualStrings("/tmp/work", config_result.dataset.?.workdir);
    try std.testing.expect(config_result.dataset.?.auto_load);
    try std.testing.expect(!config_result.dataset.?.skip_load);
}

test "parseJsonConfig - with loader config" {
    const allocator = std.testing.allocator;

    const json_content =
        \\{
        \\  "db": {
        \\    "host": "127.0.0.1",
        \\    "port": 3141,
        \\    "transport": "quic_tls_insecure",
        \\    "timeout_ms": 30000
        \\  },
        \\  "scenario": {
        \\    "network_mode": "loopback",
        \\    "durability": "fsync",
        \\    "consistency": "serializable",
        \\    "cache_state": "warm",
        \\    "db_version": "0.1.0"
        \\  },
        \\  "workload": {
        \\    "benchpack": "custom",
        \\    "mode": "closed_loop",
        \\    "slo_ms": 100,
        \\    "violation_threshold": 0.05,
        \\    "error_threshold": 0.0
        \\  },
        \\  "loader": {
        \\    "type": "quic_gql_batch",
        \\    "batch_size": 500,
        \\    "insert_node_template": "CREATE (n:Node {id: $id})",
        \\    "insert_edge_template": "MATCH (a), (b) WHERE a.id = $src AND b.id = $dst CREATE (a)-[:EDGE]->(b)"
        \\  }
        \\}
    ;

    var config_result = try parseJsonConfig(allocator, json_content);
    defer config_result.deinit();

    try std.testing.expect(config_result.loader != null);
    try std.testing.expectEqual(LoaderType.quic_gql_batch, config_result.loader.?.type);
    try std.testing.expectEqual(@as(u32, 500), config_result.loader.?.batch_size);
    try std.testing.expect(config_result.loader.?.insert_node_template != null);
    try std.testing.expect(config_result.loader.?.insert_edge_template != null);
}

test "parseJsonConfig - netem network mode" {
    const allocator = std.testing.allocator;

    const json_content =
        \\{
        \\  "db": {
        \\    "host": "127.0.0.1",
        \\    "port": 3141,
        \\    "transport": "quic_tls_insecure",
        \\    "timeout_ms": 30000
        \\  },
        \\  "scenario": {
        \\    "network_mode": "netem",
        \\    "durability": "fsync",
        \\    "consistency": "serializable",
        \\    "cache_state": "warm",
        \\    "db_version": "0.1.0"
        \\  },
        \\  "workload": {
        \\    "benchpack": "gdc_micro_primitives",
        \\    "mode": "closed_loop",
        \\    "slo_ms": 100,
        \\    "violation_threshold": 0.05,
        \\    "error_threshold": 0.0
        \\  }
        \\}
    ;

    var config_result = try parseJsonConfig(allocator, json_content);
    defer config_result.deinit();

    try std.testing.expectEqual(NetworkMode.netem, config_result.scenario.network_mode);
}

test "TransportProfile enum values" {
    try std.testing.expectEqualStrings("quic_tls_strict", @tagName(TransportProfile.quic_tls_strict));
    try std.testing.expectEqualStrings("quic_tls_insecure", @tagName(TransportProfile.quic_tls_insecure));
}

test "NetworkMode enum values" {
    try std.testing.expectEqualStrings("loopback", @tagName(NetworkMode.loopback));
    try std.testing.expectEqualStrings("remote", @tagName(NetworkMode.remote));
    try std.testing.expectEqualStrings("netem", @tagName(NetworkMode.netem));
}

test "LoadMode enum values" {
    try std.testing.expectEqualStrings("closed_loop", @tagName(LoadMode.closed_loop));
    try std.testing.expectEqualStrings("open_loop", @tagName(LoadMode.open_loop));
}

test "LoaderType enum values" {
    try std.testing.expectEqualStrings("external", @tagName(LoaderType.external));
    try std.testing.expectEqualStrings("quic_gql_batch", @tagName(LoaderType.quic_gql_batch));
}
