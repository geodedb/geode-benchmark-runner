# graphbench

**GDC-aligned benchmark harness for graph databases over QUIC + TLS 1.3**

Connects to Geode (or any graph database supporting QUIC/GQL protocol) to measure performance with GDC/LDBC-compatible metrics.

## Features

- **QUIC+TLS 1.3 connectivity** - Native Geode protocol support
- **Concurrent worker execution** - Multi-threaded load generation
- **Multiple benchmark packs** - GDC micro primitives, LDBC SNB, FinBench
- **Statistical metrics** - p50/p95/p99/p999 latencies, QPS, tail amplification
- **Validity checking** - SLO compliance, error/violation rate thresholds
- **Output generation** - JSON results + markdown summaries
- **Results comparison** - Regression detection between benchmark runs
- **Dataset preparation** - SNB CSV, Graphalytics, FinBench format support
- **Dataset verification** - Validates prepared datasets for integrity

## Build

Requires **Zig 0.15.2**:

```bash
zig build -Doptimize=ReleaseFast
```

## Quick Test (with Geode running on localhost:3141)

```bash
# Run 10-second benchmark with 2 workers
./zig-out/bin/graphbench run \
  --config examples/configs/geode_test.json \
  --out test_results/

# View results
cat test_results/summary.md
```

## Example Output

```
Running benchmark: examples/configs/geode_test.json -> test_results/
Connecting to 127.0.0.1:3141 (transport=quic_tls_insecure)
Connected successfully
Running for 10s with 2 workers, 5 in-flight each
Benchmark pack: gdc_micro_primitives (7 operations)

Benchmark complete!
  QPS: 48.55, p50: 10.50ms, p95: 10.82ms, p99: 11.04ms
  Valid: true, Errors: 0, Violations: 0
```

## Configuration

All settings in JSON:

```json
{
  "db": {
    "host": "127.0.0.1",
    "port": 3141,
    "transport": "quic_tls_insecure",
    "timeout_ms": 30000
  },
  "workload": {
    "benchpack": "gdc_micro_primitives",
    "mode": "closed_loop",
    "duration_sec": 10,
    "workers": 2,
    "in_flight_per_worker": 5,
    "slo_ms": 100
  }
}
```

## Available Benchmark Packs

- **gdc_micro_primitives** - Core graph operations (7 queries): point lookups, k-hop traversals, property filters, label scans
- **finbench** - LDBC FinBench financial graph queries (10 queries): person/account lookups, transfers, aggregations, path queries
- **gdc_snb_interactive_reads** - LDBC SNB interactive read queries
- **gdc_snb_bi** - LDBC SNB business intelligence queries
- **verify_data** - Data integrity verification queries

## Dataset Preparation

```bash
# Prepare SNB CSV dataset
./zig-out/bin/graphbench dataset prepare \
  --dataset path/to/snb/ \
  --out work/ \
  --type snb_csv

# Prepare FinBench dataset
./zig-out/bin/graphbench dataset prepare \
  --dataset path/to/finbench/ \
  --out work/ \
  --type finbench

# Verify prepared dataset
./zig-out/bin/graphbench dataset verify \
  --workdir work/
```

## Architecture

- `src/main.zig` - CLI entry point
- `src/cli.zig` - Command parsing
- `src/config.zig` - JSON/YAML config loading with proper allocation
- `src/driver.zig` - GeodeDriver wrapping geode-client-zig
- `src/runner.zig` - Worker threads + benchmark orchestration
- `src/stats.zig` - Percentile calculations, validity checks
- `src/output.zig` - JSON/markdown report generation, result comparison
- `src/dataset.zig` - SNB CSV, Graphalytics, FinBench preparation
- `src/loader.zig` - Dataset loading into database
- `src/benchpack.zig` - Benchmark pack loading from YAML/JSON

## Dependencies (Apache-2.0 licensed)

From `~/src/gl/devnw/zig/`:

- **quic** - QUIC transport (RFC 9000)
- **tls** - TLS 1.3 implementation
- **dns** - DNS resolution
- **json** - JSON parsing
- **yaml** - YAML parsing
- **slog** - Structured logging
- **uri**, **strings**, **config** - Utilities

From `../geode-client-zig`:

- **geode_client** - Official Geode Zig client

## License

MIT
