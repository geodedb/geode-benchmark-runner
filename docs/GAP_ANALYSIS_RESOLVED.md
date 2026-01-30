# Resolved Gaps - graphbench

**Generated**: 2026-01-30
**Source of Truth**: [GitLab Issues](https://gitlab.com/devnw/codepros/geode/geode-benchmark-runner/-/issues?state=closed)

This document tracks resolved gaps. For open gaps, see [GAP_ANALYSIS.md](./GAP_ANALYSIS.md).

## Summary

| Total Resolved | 7 |
|----------------|---|

## Resolved Gaps

### GAP-0002: Comprehensive Unit Test Coverage

- **Issue**: [#2](https://gitlab.com/devnw/codepros/geode/geode-benchmark-runner/-/issues/2)
- **Type**: Quality
- **Resolution Date**: 2026-01-30
- **Resolved By**: Local implementation (pending commit)
- **Description**: Core modules lacked embedded unit tests. Only `src/benchpack.zig` had tests initially.
- **Resolution**: Added comprehensive unit tests to all core modules:
  - `stats.zig`: 12 tests (percentile calculation, tail amplification, validity checks)
  - `config.zig`: 9 tests (JSON config parsing, enum values)
  - `output.zig`: 7 tests (writeResults, writeMeta, writeSummary, compareResults)
  - `loader.zig`: 9 tests (buildCreateNodeQuery, buildCreateEdgeQuery, LoadReport, Loader)
  - `benchpack.zig`: 2 tests (load builtin, parse JSON)
  - `driver.zig`: 4 tests (QueryResult struct, GeodeDriver init, QuicDriver alias)
  - `runner.zig`: 8 tests (selectOperation, buildQueryParams, freeJsonParams, WorkerContext)
  - `dataset.zig`: 6 tests (DatasetType, Stats, Manifest, JsonlFileCounts, VerificationResult)
  - **Total: 59 tests passing**
  - All tests run without requiring live Geode connections by testing struct construction, pure functions, and enum values

### GAP-0001: Debug Build - bufferedReader API Compatibility

- **Issue**: [#1](https://gitlab.com/devnw/codepros/geode/geode-benchmark-runner/-/issues/1)
- **Type**: Technical Debt
- **Resolution Date**: 2026-01-30
- **Resolved By**: Local implementation (pending commit)
- **Description**: Uses `deprecatedReader()` workaround for Zig 0.15.2 bufferedReader API changes.
- **Resolution**: Replaced all `bufferedReader` and streaming reader patterns with Zig 0.15.2-compatible `readToEndAlloc()` + `std.mem.splitScalar()` pattern in `src/loader.zig` and `src/dataset.zig`. This reads entire file contents into memory then iterates over lines, avoiding the deprecated streaming reader API.

### GAP-0003: Dataset Verification Implementation

- **Issue**: [#3](https://gitlab.com/devnw/codepros/geode/geode-benchmark-runner/-/issues/3)
- **Type**: Feature
- **Resolution Date**: 2026-01-30
- **Resolved By**: Local implementation (pending commit)
- **Description**: `verifyDataset()` only reads stats.json and counts files; doesn't verify actual data integrity.
- **Resolution**: Enhanced `verifyDataset()` to perform actual data integrity verification:
  - Counts lines in all JSONL files in nodes/ and edges/ directories
  - Validates JSON syntax of each line
  - Compares actual counts against stats.json expected counts
  - Reports detailed errors for mismatches and invalid JSON
  - Added `verifyDatasetDetailed()` returning `VerificationResult` struct with comprehensive verification data

### GAP-0007: Results Comparison/Regression Detection

- **Issue**: [#7](https://gitlab.com/devnw/codepros/geode/geode-benchmark-runner/-/issues/7)
- **Type**: Feature
- **Resolution Date**: 2026-01-30
- **Resolved By**: Local implementation (pending commit)
- **Description**: No way to compare benchmark results between runs for performance regression detection.
- **Resolution**: Added `compareResults()` function in `src/output.zig` that:
  - Loads two benchmark result JSON files (baseline and current)
  - Computes QPS and p95 latency change percentages
  - Detects regressions based on configurable threshold
  - Returns `CompareResult` struct with all comparison metrics
  - Includes `format()` method for human-readable output

### GAP-0008: Update README - Remove Outdated Known Limitations

- **Issue**: [#8](https://gitlab.com/devnw/codepros/geode/geode-benchmark-runner/-/issues/8)
- **Type**: Documentation
- **Resolution Date**: 2026-01-30
- **Resolved By**: Local implementation (pending commit)
- **Description**: Documentation contains outdated claims about features being "stubbed" or having "only 2 queries" when they're actually implemented.
- **Resolution**: Updated README.md, STATUS.md, and CLAUDE.md to:
  - Reflect actual feature completeness (7 queries in gdc_micro_primitives, 10 in finbench)
  - Remove claims about stubbed features that are now implemented
  - Document dataset verification, results comparison, and multiple benchmark packs
  - Update build/test status to reflect Zig 0.15.2 compatibility

### GAP-0006: Custom Benchpack Documentation

- **Issue**: [#6](https://gitlab.com/devnw/codepros/geode/geode-benchmark-runner/-/issues/6)
- **Type**: Documentation
- **Resolution Date**: 2026-01-30
- **Resolved By**: Local implementation (pending commit)
- **Description**: No documentation on custom benchpack YAML/JSON file format.
- **Resolution**: Created `docs/BENCHPACKS.md` with comprehensive documentation:
  - YAML and JSON format examples
  - Complete field reference for all configuration options
  - Parameter placeholder documentation ($id, $src, $dst, etc.)
  - Weight distribution explanation
  - Built-in pack descriptions (gdc_micro_primitives, finbench, gdc_snb_*)
  - Usage examples for built-in and custom packs
  - Best practices guide

### GAP-0004: FinBench Queries Should Use Parameterized Values

- **Issue**: [#4](https://gitlab.com/devnw/codepros/geode/geode-benchmark-runner/-/issues/4)
- **Type**: Enhancement
- **Resolution Date**: 2026-01-30
- **Resolved By**: Local implementation (pending commit)
- **Description**: FinBench benchmark pack uses hardcoded values (e.g., `id: 755`) instead of `$param` placeholders.
- **Resolution**: Updated both built-in finbench pack in `src/benchpack.zig` and `benchpacks/finbench.yaml` to use parameter placeholders:
  - Replaced `{id: 755}` with `{id: $id}`
  - Replaced `p.country = 'Australia'` with `p.country = $name`
  - Updated all queries to use consistent parameterization
  - Allows dynamic value injection at runtime

---

## Resolution Template

When moving a gap from GAP_ANALYSIS.md to this file, use this format:

```markdown
### GAP-XXXX: [Title]

- **Issue**: [#N](link)
- **Type**: [Type]
- **Resolution Date**: YYYY-MM-DD
- **Resolved By**: [MR/Commit link]
- **Description**: [Brief description]
- **Resolution**: [How it was resolved]
```
