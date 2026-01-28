# graphbench

**GDC-aligned benchmark harness for graph databases over QUIC + TLS 1.3**

Connects to Geode (or any graph database supporting QUIC/GQL protocol) to measure performance with GDC/LDBC-compatible metrics.

## ✅ What Works Now

- **✅ Geode QUIC+TLS connection** - Successfully connects to localhost:3141
- **✅ Concurrent worker execution** - Multi-threaded load generation
- **✅ Real query execution** - Runs point lookups and k-hop traversals against Geode
- **✅ Statistical metrics** - p50/p95/p99 latencies, QPS, tail amplification
- **✅ Validity checking** - SLO compliance, error/violation rate thresholds
- **✅ Output generation** - JSON results + markdown summaries
- **✅ Configuration loading** - Full JSON config with proper string lifecycle
- **✅ SNB CSV dataset preparation** - Processes LDBC SNB fixture files

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
Benchmark pack: gdc_micro_primitives (2 operations)

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

## Project Status

This is a **working prototype** demonstrating:
- Real QUIC+TLS connectivity to Geode
- Proper config/string lifecycle management (fixed arena issues)
- Concurrent worker pools with mutex-protected shared state
- GDC-aligned output format with network mode disclosure
- Dataset preparation scaffolding for LDBC SNB CSV files

## Known Limitations

- Dataset loader is stubbed (doesn't actually load into Geode yet)
- Only 2 hardcoded queries in micro primitives pack
- Sweep runs with stub data
- No parameter substitution in queries yet
- No dataset verification implementation

## Architecture

- `src/main.zig` - CLI entry point
- `src/cli.zig` - Command parsing
- `src/config.zig` - JSON config loading with proper allocation
- `src/driver.zig` - GeodeDriver wrapping geode-client-zig
- `src/runner.zig` - Worker threads + benchmark orchestration
- `src/stats.zig` - Percentile calculations, validity checks
- `src/output.zig` - JSON/markdown report generation
- `src/dataset.zig` - SNB CSV preparation (streaming parser)
- `src/loader.zig` - Dataset loading interface (stub)

## Dependencies (Apache-2.0 licensed)

From `~/src/gl/devnw/zig/`:
- **quic** - QUIC transport (RFC 9000)
- **tls** - TLS 1.3 implementation
- **dns** - DNS resolution
- **json** - JSON parsing
- **slog** - Structured logging
- **uri**, **strings**, **config** - Utilities

From `../geode-client-zig`:
- **geode_client** - Official Geode Zig client

## License

MIT
