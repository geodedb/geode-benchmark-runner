const std = @import("std");
const geode = @import("geode_client");
const config = @import("config.zig");

pub const LoadReport = struct {
    dataset_id: []const u8,
    load_time_sec: f64,
    node_count: u64,
    edge_count: u64,
    
    pub fn deinit(_: *LoadReport, _: std.mem.Allocator) void {}
};

pub const Loader = struct {
    allocator: std.mem.Allocator,
    loader_config: config.LoaderConfig,
    
    pub fn init(allocator: std.mem.Allocator, loader_config: config.LoaderConfig) Loader {
        return Loader{
            .allocator = allocator,
            .loader_config = loader_config,
        };
    }
    
    pub fn loadDataset(_: *Loader, dataset_id: []const u8, _: []const u8, _: config.DbConfig) !LoadReport {
        const start = std.time.milliTimestamp();
        
        // Stub implementation
        std.posix.nanosleep(0, 100 * std.time.ns_per_ms);
        
        const end = std.time.milliTimestamp();
        const duration = @as(f64, @floatFromInt(end - start)) / 1000.0;
        
        return LoadReport{
            .dataset_id = dataset_id,
            .load_time_sec = duration,
            .node_count = 0,
            .edge_count = 0,
        };
    }
};

pub fn loadDataset(
    allocator: std.mem.Allocator,
    config_path: []const u8,
    dataset_id: []const u8,
    workdir: []const u8,
) !void {
    const cfg = try config.loadConfig(allocator, config_path);
    defer cfg.deinit();
    
    if (cfg.loader == null) {
        std.debug.print("No loader configured\n", .{});
        return error.NoLoader;
    }
    
    var loader = Loader.init(allocator, cfg.loader.?);
    var report = try loader.loadDataset(dataset_id, workdir, cfg.db);
    defer report.deinit(allocator);
    
    std.debug.print("Load complete in {d:.2}s\n", .{report.load_time_sec});
}
