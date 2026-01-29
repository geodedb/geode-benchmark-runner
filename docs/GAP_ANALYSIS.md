# Gap Analysis - graphbench

**Generated**: 2026-01-29
**Source of Truth**: [GitLab Issues](https://gitlab.com/devnw/codepros/geode/geode-benchmark-runner/-/issues)

This document tracks open gaps between requirements and implementation. For resolved gaps, see [GAP_ANALYSIS_RESOLVED.md](./GAP_ANALYSIS_RESOLVED.md).

## Summary

| Priority | Count | Status |
|----------|-------|--------|
| High     | 2     | Open   |
| Medium   | 4     | Open   |
| Low      | 3     | Open   |
| **Total**| **9** | Open   |

## Open Gaps

### High Priority

#### GAP-0002: Comprehensive Unit Test Coverage

- **Issue**: [#2](https://gitlab.com/devnw/codepros/geode/geode-benchmark-runner/-/issues/2)
- **Type**: Quality
- **Component**: src/
- **Description**: Currently only `src/benchpack.zig` has embedded unit tests. Other core modules (config.zig, driver.zig, runner.zig, stats.zig, output.zig, dataset.zig, loader.zig) lack test coverage.
- **Impact**: Reduced code quality and maintainability

#### GAP-0008: Update README - Remove Outdated Known Limitations

- **Issue**: [#8](https://gitlab.com/devnw/codepros/geode/geode-benchmark-runner/-/issues/8)
- **Type**: Documentation
- **Component**: README.md, STATUS.md
- **Description**: Documentation contains outdated claims about features being "stubbed" or having "only 2 queries" when they're actually implemented.
- **Impact**: Misleading documentation for users and contributors

### Medium Priority

#### GAP-0001: Debug Build - bufferedReader API Compatibility

- **Issue**: [#1](https://gitlab.com/devnw/codepros/geode/geode-benchmark-runner/-/issues/1)
- **Type**: Technical Debt
- **Component**: src/loader.zig, src/dataset.zig
- **Description**: Uses `deprecatedReader()` workaround for Zig 0.15.2 bufferedReader API changes.
- **Impact**: Debug builds may have issues; using deprecated API

#### GAP-0003: Dataset Verification Implementation

- **Issue**: [#3](https://gitlab.com/devnw/codepros/geode/geode-benchmark-runner/-/issues/3)
- **Type**: Feature
- **Component**: src/dataset.zig
- **Description**: `verifyDataset()` only reads stats.json and counts files; doesn't verify actual data integrity.
- **Impact**: Cannot validate dataset correctness after preparation

#### GAP-0007: Results Comparison/Regression Detection

- **Issue**: [#7](https://gitlab.com/devnw/codepros/geode/geode-benchmark-runner/-/issues/7)
- **Type**: Feature
- **Component**: src/output.zig, src/main.zig
- **Description**: No way to compare benchmark results between runs for performance regression detection.
- **Impact**: Manual comparison required; no automated regression detection

#### GAP-0009: Integration Test Reliability

- **Issue**: [#9](https://gitlab.com/devnw/codepros/geode/geode-benchmark-runner/-/issues/9)
- **Type**: CI/CD
- **Component**: .gitlab-ci.yml
- **Description**: Integration tests configured with `allow_failure: true`, meaning they don't block the pipeline.
- **Impact**: Integration regressions may go unnoticed

### Low Priority

#### GAP-0004: FinBench Queries Should Use Parameterized Values

- **Issue**: [#4](https://gitlab.com/devnw/codepros/geode/geode-benchmark-runner/-/issues/4)
- **Type**: Enhancement
- **Component**: src/benchpack.zig
- **Description**: FinBench benchmark pack uses hardcoded values (e.g., `id: 755`) instead of `$param` placeholders.
- **Impact**: Less flexible benchmark execution; queries not representative of real workloads

#### GAP-0005: Open-Loop Workload Mode Not Implemented

- **Issue**: [#5](https://gitlab.com/devnw/codepros/geode/geode-benchmark-runner/-/issues/5)
- **Type**: Feature
- **Component**: src/runner.zig, src/config.zig
- **Description**: Config supports `open_loop` mode but only closed-loop execution is implemented.
- **Impact**: Cannot test system behavior under arrival-rate based load

#### GAP-0006: Custom Benchpack Documentation

- **Issue**: [#6](https://gitlab.com/devnw/codepros/geode/geode-benchmark-runner/-/issues/6)
- **Type**: Documentation
- **Component**: docs/
- **Description**: No documentation on custom benchpack YAML/JSON file format.
- **Impact**: Users cannot easily create custom benchmark packs

## Gap Analysis Methodology

This analysis was performed by:

1. **Code Review**: Scanning source files for TODO/FIXME markers, stubs, and incomplete implementations
2. **Documentation Review**: Comparing README.md, STATUS.md, and CLAUDE.md against actual code
3. **Test Coverage Analysis**: Identifying modules without unit tests
4. **CI/CD Review**: Checking for reliability issues in pipeline configuration
5. **Feature Completeness**: Comparing config options against implementation

## Updating This Document

This document should only contain **open** gaps. When a gap is resolved:

1. Move the gap entry to `GAP_ANALYSIS_RESOLVED.md`
2. Add resolution date and closing commit/MR reference
3. Update the summary counts

GitLab issues are the source of truth. This document is a human-readable summary.
