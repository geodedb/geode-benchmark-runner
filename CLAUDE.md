# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**graphbench** is a GDC-aligned benchmark harness for graph databases over QUIC + TLS 1.3. It connects to Geode (or any graph database supporting QUIC/GQL protocol) to measure performance with GDC/LDBC-compatible metrics.

**Status**: Working prototype - connects to Geode, runs concurrent benchmarks, computes statistics.

## Build Commands

```bash
# Build (requires Zig 0.15.2)
zig build                           # Debug build
zig build -Doptimize=ReleaseFast    # Release build

# Run unit tests
zig build test

# Run with arguments
zig build run -- run --config examples/configs/geode_test.json --out test_results/

# Or use Makefile
make build          # Debug build
make build-release  # Release build
make test           # Run tests
```

## Development Setup

```bash
# Install pre-commit hooks (recommended)
make setup-dev

# Or manually:
pip install pre-commit
pre-commit install
pre-commit install --hook-type commit-msg
pre-commit install --hook-type pre-push

# Run all checks
make pre-commit
```

## CLI Commands

All commands require a running Geode server (default: `localhost:3141`).

```bash
# Run a single benchmark
./zig-out/bin/graphbench run --config <config.json> --out <output_dir>/

# Run parameter sweep (tests multiple values for a parameter)
./zig-out/bin/graphbench sweep --config <sweep_config.json> --out <output_dir>/

# Validate configuration file
./zig-out/bin/graphbench validate --config <config.json>

# Dataset operations
./zig-out/bin/graphbench dataset prepare --dataset <path/to/snb/> --out <workdir/> --type snb_csv
./zig-out/bin/graphbench dataset load --config <config.json> --dataset-id <id> --workdir <workdir/>
./zig-out/bin/graphbench dataset verify --config <config.json> --dataset-id <id> --workdir <workdir/>
```

## Architecture

The benchmark harness follows a pipeline architecture:

```
CLI (main.zig, cli.zig)
    ↓
Config (config.zig) → JSON config parsing with proper string lifecycle
    ↓
BenchPack (benchpack.zig) → Load benchmark packs from YAML/JSON or built-in
    ↓
Driver (driver.zig) → GeodeDriver wrapping geode-client-zig via QUIC+TLS
    ↓
Runner (runner.zig) → Multi-threaded worker pools with mutex-protected shared state
    ↓
Stats (stats.zig) → Percentile calculations (p50/p95/p99/p999), validity checks
    ↓
Output (output.zig) → JSON results + markdown summaries
```

**Key Design Decisions**:

- **Parameterized queries**: Runner uses `execWithParams` with JSON params object instead of string substitution (prevents injection attacks)
- **String lifecycle in config.zig**: All JSON-parsed strings are duplicated with `allocator.dupe()` to prevent use-after-free when the JSON parser is deallocated
- **Worker thread safety in runner.zig**: Shared state (latencies, errors, violations) protected by mutex; worker contexts pre-allocated before thread spawn to prevent pointer invalidation
- **Driver protocol**: Uses HELLO handshake → RUN_GQL → SCHEMA response → PULL → BINDINGS response flow

## Built-in Benchmark Packs

Available via `"benchpack"` config field (no file needed):

| Name | Description |
|------|-------------|
| `gdc_micro_primitives` | Point lookups, k-hop traversals, property filters, count |
| `gdc_graph_algorithms` | Shortest path, all shortest paths, connected components |
| `gdc_crud_operations` | Create/update/delete nodes and relationships |
| `finbench` / `ldbc_finbench` | LDBC FinBench financial graph queries |

Custom packs can be loaded from `benchpacks/` directory as YAML or JSON files.

## Configuration Format

Benchmarks are configured via JSON files (see `examples/configs/`):

```json
{
  "db": { "host": "127.0.0.1", "port": 3141, "transport": "quic_tls_insecure", "timeout_ms": 30000 },
  "workload": {
    "benchpack": "gdc_micro_primitives",
    "duration_sec": 10,
    "workers": 2,
    "in_flight_per_worker": 5,
    "slo_ms": 100,
    "violation_threshold": 0.05,
    "error_threshold": 0.0
  },
  "scenario": { "network_mode": "loopback", "durability": "fsync" }
}
```

## Output Files

After running a benchmark, the output directory contains:

- `result.json` - QPS, latency percentiles, error/violation rates, validity status
- `meta.json` - Scenario metadata (network mode, transport, db version)
- `summary.md` - Human-readable markdown summary

## Helper Scripts

```bash
# Load LDBC FinBench data into Geode
./scripts/load_finbench.sh /path/to/sf0.01

# Network emulation for latency testing (requires tc/netem)
./scripts/netem.sh
```

## Dependencies

From `build.zig.zon`:

- `geode_client` - Official Geode Zig client (local path: `../geode-client-zig`)
- `zig_cli` - CLI framework
- `yaml` - YAML parser for benchmark packs
- `quic`, `json`, `slog`, `strings` - Supporting libraries from gitlab.com/devnw/zig

## CI/CD Pipeline

GitLab CI pipeline runs on every push with stages: lint, build, test, integration, security, sbom, release.

**Required Setup**: The `geode-client-zig` dependency must be accessible to CI. This is configured via CI job token allowlist (already set up) or a `GEODE_CLONE_TOKEN` variable.

**Key Jobs**:

- `zig-format` - Code formatting check
- `build` - Debug build verification
- `test` - Unit tests with coverage reporting
- `integration-tests` - Benchmark against live Geode server (allow_failure)
- Security scanning (SAST, secrets, gitleaks)
- SBOM generation

## Known Limitations

- Dataset loader in `loader.zig` is stubbed (use `scripts/load_finbench.sh` instead)
- Parameterized queries support limited built-in params: `$id`, `$src`, `$dst`, `$min_age`, `$name`, `$ts`, `$weight`
- Sweep execution re-reads config for each point (doesn't preserve in-memory modifications)
- Integration tests require access to private Geode container registry
