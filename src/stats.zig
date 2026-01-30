const std = @import("std");

pub const Percentiles = struct {
    p50: f64,
    p95: f64,
    p99: f64,
    p999: f64,
    min: f64,
    max: f64,
    mean: f64,

    pub fn compute(latencies: []f64) Percentiles {
        if (latencies.len == 0) {
            return Percentiles{
                .p50 = 0,
                .p95 = 0,
                .p99 = 0,
                .p999 = 0,
                .min = 0,
                .max = 0,
                .mean = 0,
            };
        }

        std.mem.sort(f64, latencies, {}, comptime std.sort.asc(f64));

        const min = latencies[0];
        const max = latencies[latencies.len - 1];

        var sum: f64 = 0;
        for (latencies) |lat| {
            sum += lat;
        }
        const mean = sum / @as(f64, @floatFromInt(latencies.len));

        return Percentiles{
            .p50 = percentile(latencies, 0.50),
            .p95 = percentile(latencies, 0.95),
            .p99 = percentile(latencies, 0.99),
            .p999 = percentile(latencies, 0.999),
            .min = min,
            .max = max,
            .mean = mean,
        };
    }
};

fn percentile(sorted_values: []const f64, p: f64) f64 {
    if (sorted_values.len == 0) return 0;

    const rank = p * @as(f64, @floatFromInt(sorted_values.len - 1));
    const lower_idx = @as(usize, @intFromFloat(@floor(rank)));
    const upper_idx = @min(lower_idx + 1, sorted_values.len - 1);
    const fraction = rank - @floor(rank);

    return sorted_values[lower_idx] * (1.0 - fraction) + sorted_values[upper_idx] * fraction;
}

pub const RunMetrics = struct {
    qps: f64,
    latency: Percentiles,
    error_rate: f64,
    violation_rate: f64,
    tail_amplification: f64,
    qps_ceiling_est_from_p50: f64,
    required_in_flight: f64,

    pub fn computeTailAmplification(p: Percentiles) f64 {
        if (p.p50 == 0) return 0;
        return p.p99 / p.p50;
    }

    pub fn computeQpsCeiling(in_flight: u32, p50_ms: f64) f64 {
        if (p50_ms == 0) return 0;
        return @as(f64, @floatFromInt(in_flight)) / (p50_ms / 1000.0);
    }

    pub fn computeRequiredInFlight(target_qps: f64, p50_ms: f64) f64 {
        return target_qps * (p50_ms / 1000.0);
    }
};

pub const ValidityCheck = struct {
    is_valid: bool,
    reasons: []const []const u8,

    pub fn check(
        allocator: std.mem.Allocator,
        metrics: RunMetrics,
        slo_ms: f64,
        violation_threshold: f64,
        error_threshold: f64,
    ) !ValidityCheck {
        var reasons = std.array_list.AlignedManaged([]const u8, null).init(allocator);
        var is_valid = true;

        if (metrics.latency.p95 > slo_ms) {
            try reasons.append(try std.fmt.allocPrint(
                allocator,
                "p95 {d:.2}ms > SLO {d:.2}ms",
                .{ metrics.latency.p95, slo_ms },
            ));
            is_valid = false;
        }

        if (metrics.violation_rate > violation_threshold) {
            try reasons.append(try std.fmt.allocPrint(
                allocator,
                "violation_rate {d:.4} > threshold {d:.4}",
                .{ metrics.violation_rate, violation_threshold },
            ));
            is_valid = false;
        }

        if (metrics.error_rate > error_threshold) {
            try reasons.append(try std.fmt.allocPrint(
                allocator,
                "error_rate {d:.4} > threshold {d:.4}",
                .{ metrics.error_rate, error_threshold },
            ));
            is_valid = false;
        }

        return ValidityCheck{
            .is_valid = is_valid,
            .reasons = try reasons.toOwnedSlice(),
        };
    }

    pub fn deinit(self: *ValidityCheck, allocator: std.mem.Allocator) void {
        for (self.reasons) |reason| {
            allocator.free(reason);
        }
        allocator.free(self.reasons);
    }
};

test "percentile calculation" {
    var latencies = [_]f64{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    const p = Percentiles.compute(&latencies);

    try std.testing.expectApproxEqAbs(@as(f64, 5.5), p.p50, 0.1);
    try std.testing.expectApproxEqAbs(@as(f64, 9.55), p.p95, 0.1);
    try std.testing.expectApproxEqAbs(@as(f64, 9.91), p.p99, 0.1);
}

test "concurrency math" {
    const p50_ms = 19.5;
    const in_flight: u32 = 6;
    const qps_ceiling = RunMetrics.computeQpsCeiling(in_flight, p50_ms);

    try std.testing.expectApproxEqAbs(@as(f64, 307.7), qps_ceiling, 0.1);
}

test "percentile calculation - empty array" {
    var latencies = [_]f64{};
    const p = Percentiles.compute(&latencies);

    try std.testing.expectEqual(@as(f64, 0), p.p50);
    try std.testing.expectEqual(@as(f64, 0), p.p95);
    try std.testing.expectEqual(@as(f64, 0), p.p99);
    try std.testing.expectEqual(@as(f64, 0), p.p999);
    try std.testing.expectEqual(@as(f64, 0), p.min);
    try std.testing.expectEqual(@as(f64, 0), p.max);
    try std.testing.expectEqual(@as(f64, 0), p.mean);
}

test "percentile calculation - single element" {
    var latencies = [_]f64{42.0};
    const p = Percentiles.compute(&latencies);

    try std.testing.expectEqual(@as(f64, 42.0), p.p50);
    try std.testing.expectEqual(@as(f64, 42.0), p.min);
    try std.testing.expectEqual(@as(f64, 42.0), p.max);
    try std.testing.expectEqual(@as(f64, 42.0), p.mean);
}

test "percentile calculation - two elements" {
    var latencies = [_]f64{ 10.0, 20.0 };
    const p = Percentiles.compute(&latencies);

    try std.testing.expectApproxEqAbs(@as(f64, 15.0), p.p50, 0.1);
    try std.testing.expectEqual(@as(f64, 10.0), p.min);
    try std.testing.expectEqual(@as(f64, 20.0), p.max);
    try std.testing.expectEqual(@as(f64, 15.0), p.mean);
}

test "percentile calculation - unsorted input" {
    var latencies = [_]f64{ 5, 3, 1, 4, 2 };
    const p = Percentiles.compute(&latencies);

    try std.testing.expectEqual(@as(f64, 1.0), p.min);
    try std.testing.expectEqual(@as(f64, 5.0), p.max);
    try std.testing.expectEqual(@as(f64, 3.0), p.mean);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), p.p50, 0.1);
}

test "tail amplification" {
    const p = Percentiles{
        .p50 = 10.0,
        .p95 = 50.0,
        .p99 = 100.0,
        .p999 = 200.0,
        .min = 5.0,
        .max = 300.0,
        .mean = 25.0,
    };

    const tail_amp = RunMetrics.computeTailAmplification(p);
    try std.testing.expectEqual(@as(f64, 10.0), tail_amp);
}

test "tail amplification - zero p50" {
    const p = Percentiles{
        .p50 = 0,
        .p95 = 50.0,
        .p99 = 100.0,
        .p999 = 200.0,
        .min = 0,
        .max = 300.0,
        .mean = 25.0,
    };

    const tail_amp = RunMetrics.computeTailAmplification(p);
    try std.testing.expectEqual(@as(f64, 0), tail_amp);
}

test "qps ceiling - zero p50" {
    const qps_ceiling = RunMetrics.computeQpsCeiling(10, 0);
    try std.testing.expectEqual(@as(f64, 0), qps_ceiling);
}

test "required in-flight calculation" {
    const target_qps: f64 = 1000.0;
    const p50_ms: f64 = 10.0;
    const required = RunMetrics.computeRequiredInFlight(target_qps, p50_ms);

    // 1000 QPS * 10ms = 1000 * 0.01s = 10 in-flight
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), required, 0.1);
}

test "validity check - all valid" {
    const allocator = std.testing.allocator;

    const metrics = RunMetrics{
        .qps = 100.0,
        .latency = Percentiles{
            .p50 = 10.0,
            .p95 = 50.0,
            .p99 = 80.0,
            .p999 = 90.0,
            .min = 5.0,
            .max = 100.0,
            .mean = 25.0,
        },
        .error_rate = 0.0,
        .violation_rate = 0.01,
        .tail_amplification = 8.0,
        .qps_ceiling_est_from_p50 = 1000.0,
        .required_in_flight = 1.0,
    };

    var validity = try ValidityCheck.check(allocator, metrics, 100.0, 0.05, 0.01);
    defer validity.deinit(allocator);

    try std.testing.expect(validity.is_valid);
    try std.testing.expectEqual(@as(usize, 0), validity.reasons.len);
}

test "validity check - p95 exceeds SLO" {
    const allocator = std.testing.allocator;

    const metrics = RunMetrics{
        .qps = 100.0,
        .latency = Percentiles{
            .p50 = 10.0,
            .p95 = 150.0, // Exceeds SLO of 100ms
            .p99 = 200.0,
            .p999 = 300.0,
            .min = 5.0,
            .max = 400.0,
            .mean = 50.0,
        },
        .error_rate = 0.0,
        .violation_rate = 0.01,
        .tail_amplification = 20.0,
        .qps_ceiling_est_from_p50 = 1000.0,
        .required_in_flight = 1.0,
    };

    var validity = try ValidityCheck.check(allocator, metrics, 100.0, 0.05, 0.01);
    defer validity.deinit(allocator);

    try std.testing.expect(!validity.is_valid);
    try std.testing.expectEqual(@as(usize, 1), validity.reasons.len);
}

test "validity check - multiple failures" {
    const allocator = std.testing.allocator;

    const metrics = RunMetrics{
        .qps = 100.0,
        .latency = Percentiles{
            .p50 = 10.0,
            .p95 = 150.0, // Exceeds SLO
            .p99 = 200.0,
            .p999 = 300.0,
            .min = 5.0,
            .max = 400.0,
            .mean = 50.0,
        },
        .error_rate = 0.05, // Exceeds threshold
        .violation_rate = 0.10, // Exceeds threshold
        .tail_amplification = 20.0,
        .qps_ceiling_est_from_p50 = 1000.0,
        .required_in_flight = 1.0,
    };

    var validity = try ValidityCheck.check(allocator, metrics, 100.0, 0.05, 0.01);
    defer validity.deinit(allocator);

    try std.testing.expect(!validity.is_valid);
    try std.testing.expectEqual(@as(usize, 3), validity.reasons.len);
}
