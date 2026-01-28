# LDBC FinBench Benchmark Results

**Date:** 2026-01-28
**Geode Version:** 0.18.0
**Dataset:** LDBC FinBench sf0.01

## Dataset Summary

The LDBC Financial Benchmark (FinBench) dataset models a financial network with persons, companies, accounts, loans, and various financial transactions.

### Nodes Loaded

| Label   | Count | Description |
|---------|-------|-------------|
| Person  | 788   | Individual customers |
| Company | 387   | Business entities |
| Account | 2,055 | Financial accounts |
| Loan    | 1,376 | Loan records |
| Medium  | 978   | Authentication devices |
| **Total** | **5,584** | |

### Relationships Loaded

| Type      | Count | Description |
|-----------|-------|-------------|
| OWN       | 2,055 | Person/Company owns Account |
| APPLY     | 1,376 | Person/Company applied for Loan |
| INVEST    | 1,681 | Person/Company invests in Company |
| GUARANTEE | 377   | Person/Company guarantees another |
| TRANSFER  | 2,000 | Account to Account transfer (sampled) |
| WITHDRAW  | 2,000 | Account withdrawal (sampled) |
| DEPOSIT   | 2,758 | Loan deposited to Account |
| REPAY     | 2,747 | Account repays Loan |
| SIGN_IN   | 2,489 | Medium signs into Account |
| **Total** | **17,987** | |

Note: TRANSFER and WITHDRAW relationships were limited to 2,000 each to reduce loading time. The full sf0.01 dataset contains approximately 31,000 relationships.

## Benchmark Configuration

```yaml
workload:
  benchpack: ldbc_finbench
  mode: closed_loop
  duration_sec: 15
  workers: 1
  in_flight_per_worker: 5
  slo_ms: 100
```

## Benchmark Queries

The FinBench benchpack includes 10 representative queries:

| Query | Description | SLO |
|-------|-------------|-----|
| count_persons | Count all Person nodes | 100ms |
| count_accounts | Count all Account nodes | 100ms |
| find_person_by_id | Lookup person by ID | 50ms |
| person_accounts | Find accounts owned by persons | 100ms |
| account_transfers | Find transfer relationships | 100ms |
| persons_by_country | Filter persons by country | 100ms |
| loan_repayments | Find loan repayment relationships | 100ms |
| person_investments | Find investment relationships | 100ms |
| transfer_path | 2-hop transfer path traversal | 200ms |
| guarantee_chain | Find guarantee relationships | 100ms |

## Results

### Latency Metrics

| Metric | Value |
|--------|-------|
| p50 | 413.40 ms |
| p95 | 2,006.71 ms |
| p99 | 2,040.56 ms |
| p999 | 2,049.51 ms |
| min | 22.04 ms |
| max | 2,050.50 ms |
| mean | 626.27 ms |

### Throughput

| Metric | Value |
|--------|-------|
| QPS | 1.59 |
| QPS Ceiling (est. from p50) | 12.09 |

### Quality Metrics

| Metric | Value |
|--------|-------|
| Error Rate | 0.00% |
| SLO Violation Rate | 74.07% |
| Tail Amplification | 4.94x |
| Valid Run | No (high violation rate) |

## Query Verification

All queries were verified to return actual data from the database:

```
=== count_persons ===
{"count": 788}

=== find_person_by_id ===
{"name": "Bertrand", "country": "Australia"}

=== person_accounts ===
{"name": "Maguire", "id": 4779445104546939854}
{"name": "Maguire", "id": 4681491812651631567}
{"name": "Redman", "id": 4789296728731812456}
...

=== account_transfers ===
{"a1.id": 113434415614394918, "amount": 8685028.36, "a2.id": 231653905832870639}
{"a1.id": 113434415614394918, "amount": 3332636.68, "a2.id": 162411061562049342}
...
```

## Analysis

### Observations

1. **High Latency Variability**: The tail amplification of 4.94x indicates significant latency variance between queries. Simple count queries complete in ~22ms while complex traversals can take over 2 seconds.

2. **Query Complexity Impact**: The 2-hop transfer path query and relationship traversals contribute to the high p95/p99 latencies.

3. **No Errors**: Zero error rate confirms stable query execution and correct data loading.

4. **SLO Violations**: The 74% violation rate is primarily due to complex traversal queries exceeding the 100ms SLO.

### Recommendations

1. **Adjust SLOs**: Consider query-specific SLOs (e.g., 200ms for traversals, 50ms for point lookups)

2. **Add Indexes**: Property indexes on frequently queried fields (Person.country, Person.id) could improve lookup performance

3. **Optimize Traversals**: The 2-hop transfer path query could benefit from query optimization or caching

4. **Increase Workers**: With stable error rate, increasing workers could improve QPS without sacrificing reliability

## Files

- **Benchmark Config**: `examples/configs/finbench_bench.yaml`
- **Benchpack**: Built-in `finbench` / `ldbc_finbench` in `src/benchpack.zig`
- **Data Loader**: `scripts/load_finbench.py`
- **Results**: `finbench_results/result.json`

## Reproduction

```bash
# 1. Start Geode server
cd ../geode && ./zig-out/bin/geode serve --data-dir /tmp/geode-test --listen 0.0.0.0:3141 --disable-auth

# 2. Load FinBench data
cd ../geode-benchmark-runner/graphbench
python3 scripts/load_finbench.py /tmp/gdc_bench/sf0.01

# 3. Run benchmark
./zig-out/bin/graphbench run --config examples/configs/finbench_bench.yaml --out finbench_results
```
