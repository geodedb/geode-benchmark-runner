# Gap Analysis - graphbench

**Generated**: 2026-01-30
**Source of Truth**: [GitLab Issues](https://gitlab.com/devnw/codepros/geode/geode-benchmark-runner/-/issues)

This document tracks open gaps between requirements and implementation. For resolved gaps, see [GAP_ANALYSIS_RESOLVED.md](./GAP_ANALYSIS_RESOLVED.md).

## Summary

| Priority | Count | Status |
|----------|-------|--------|
| Medium   | 1     | Blocked |
| Low      | 1     | Blocked |
| **Total**| **2** | Blocked |

All actionable gaps have been closed. The remaining 2 gaps are explicitly blocked pending infrastructure or architectural changes.

## Blocked Gaps

### Medium Priority

#### GAP-0009: Integration Test Reliability (BLOCKED)

- **Issue**: [#9](https://gitlab.com/devnw/codepros/geode/geode-benchmark-runner/-/issues/9)
- **Type**: CI/CD
- **Component**: .gitlab-ci.yml
- **Description**: Integration tests configured with `allow_failure: true`, meaning they don't block the pipeline.
- **Impact**: Integration regressions may go unnoticed
- **Status**: **BLOCKED**
- **Blocker**: The `allow_failure: true` is intentional because:
  - The Geode container registry (`geodedb/geode:latest`) may not be accessible to all CI runners
  - The Geode service may not start reliably in CI environment
  - Removing this flag would cause all CI runs to fail when infrastructure is unavailable
- **Unblock Steps**:
  1. Ensure Geode container image is reliably available in GitLab container registry
  2. Configure CI runners with appropriate access to pull the image
  3. Add health checks and retry logic for Geode service startup
  4. Gradually transition to `allow_failure: false` after stability is confirmed

### Low Priority

#### GAP-0005: Open-Loop Workload Mode Not Implemented (BLOCKED)

- **Issue**: [#5](https://gitlab.com/devnw/codepros/geode/geode-benchmark-runner/-/issues/5)
- **Type**: Feature
- **Component**: src/runner.zig, src/config.zig
- **Description**: Config supports `open_loop` mode but only closed-loop execution is implemented.
- **Impact**: Cannot test system behavior under arrival-rate based load
- **Status**: **BLOCKED**
- **Blocker**: Implementing open-loop (arrival-rate based) load generation requires significant architectural changes:
  - Poisson or uniform arrival rate scheduler
  - Request queuing to decouple submission from completion
  - Backpressure handling when target QPS exceeds capacity
  - Separate measurement of queuing delay vs service time
- **Unblock Steps**:
  1. Design the open-loop scheduling architecture
  2. Implement a separate scheduler module for arrival-rate control
  3. Add queue depth tracking and backpressure metrics
  4. Create dedicated MR with proper design review and testing

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
