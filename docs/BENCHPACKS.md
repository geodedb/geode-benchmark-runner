# Custom Benchmark Packs

This document describes the YAML/JSON file format for creating custom benchmark packs.

## Overview

Benchmark packs define a set of queries to execute during benchmarking. They can be:

1. **Built-in packs**: Hardcoded in `src/benchpack.zig` (e.g., `gdc_micro_primitives`, `finbench`)
2. **Custom packs**: YAML or JSON files in the `benchpacks/` directory

## File Format

### YAML Format (Recommended)

```yaml
name: my_custom_pack
version: '1.0'
description: My custom benchmark queries
tags:
  - custom
  - example

queries:
  - name: simple_lookup
    description: Look up a node by ID
    query: 'MATCH (n {id: $id}) RETURN n'
    weight: 10
    category: read

  - name: relationship_traversal
    description: Find related nodes
    query: 'MATCH (n)-[r]->(m) WHERE id(n) = $id RETURN m LIMIT 10'
    weight: 5
    category: traversal

  - name: aggregation
    description: Count nodes by label
    query: 'MATCH (n:Person) RETURN count(n) as total'
    weight: 3
    category: aggregation
```

### JSON Format

```json
{
  "name": "my_custom_pack",
  "version": "1.0",
  "description": "My custom benchmark queries",
  "tags": ["custom", "example"],
  "operations": [
    {
      "name": "simple_lookup",
      "query": "MATCH (n {id: $id}) RETURN n",
      "weight": 1.0,
      "slo_ms": 50
    },
    {
      "name": "relationship_traversal",
      "query": "MATCH (n)-[r]->(m) WHERE id(n) = $id RETURN m LIMIT 10",
      "weight": 1.0,
      "slo_ms": 100
    }
  ]
}
```

## Field Reference

### Top-Level Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | Yes | Unique identifier for the pack |
| `version` | string | No | Semantic version (e.g., "1.0") |
| `description` | string | No | Human-readable description |
| `tags` | array | No | Tags for categorization |
| `queries` or `operations` | array | Yes | List of benchmark operations |

### Query/Operation Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | Yes | Unique operation name |
| `query` | string | Yes | GQL query to execute |
| `weight` | number | No | Relative frequency (default: 1.0) |
| `slo_ms` | number | No | Per-query SLO in milliseconds |
| `description` | string | No | Human-readable description |
| `category` | string | No | Operation category (read, write, traversal, aggregation) |

## Parameter Placeholders

Queries can include parameter placeholders that are substituted at runtime:

| Placeholder | Type | Description |
|-------------|------|-------------|
| `$id` | integer | Node ID from dataset |
| `$src` | integer | Source node ID for edges |
| `$dst` | integer | Destination node ID for edges |
| `$min_age` | integer | Minimum age filter |
| `$name` | string | Name filter value |
| `$ts` | integer | Timestamp value |
| `$weight` | float | Weight/numeric value |

### Example with Parameters

```yaml
queries:
  - name: person_lookup
    query: 'MATCH (p:Person {id: $id}) RETURN p.name, p.age'
    weight: 10

  - name: transfer_path
    query: 'MATCH (a1:Account {id: $src})-[t:TRANSFER]->(a2:Account {id: $dst}) RETURN t.amount'
    weight: 5
```

## Weight Distribution

The `weight` field determines the relative frequency of each query:

- Weights are normalized to sum to 1.0
- Higher weight = more frequently executed
- Example: weights [10, 5, 5] become probabilities [0.5, 0.25, 0.25]

## Built-in Packs

### gdc_micro_primitives

Core graph operations for micro-benchmarking:

- `point_lookup` - Find node by ID
- `k_hop_traversal_1` - 1-hop neighbor traversal
- `k_hop_traversal_2` - 2-hop neighbor traversal
- `property_filter` - Filter by property value
- `count_nodes` - Count all nodes
- `label_scan` - Scan nodes by label
- `edge_traversal` - Traverse outgoing edges

### finbench

LDBC FinBench financial graph queries:

- `simple_read_1` - Person lookup by ID
- `simple_read_2` - Accounts owned by person
- `simple_read_3` - Account transfers
- `complex_read_1` - Accounts by country
- `complex_read_2` - Loan repayments
- `complex_read_3` - Person investments
- `aggregation_1` - Count persons by country
- `aggregation_2` - Count accounts per person
- `path_1` - 2-hop transfer path
- `path_2` - Guarantee chain

### gdc_snb_interactive_reads

LDBC SNB interactive read queries for social network benchmarking.

### gdc_snb_bi

LDBC SNB business intelligence queries for analytical workloads.

## Usage

### Using Built-in Packs

```json
{
  "workload": {
    "benchpack": "gdc_micro_primitives"
  }
}
```

### Using Custom Pack File

Place your YAML/JSON file in `benchpacks/` and reference by filename:

```json
{
  "workload": {
    "benchpack": "my_custom_pack"
  }
}
```

### Loading Pack from Arbitrary Path

```json
{
  "workload": {
    "benchpack": "/path/to/my_pack.yaml"
  }
}
```

## Best Practices

1. **Use descriptive names**: Make query names self-documenting
2. **Set appropriate weights**: Mirror expected production workload distribution
3. **Include SLOs**: Set per-query SLO targets for fine-grained analysis
4. **Use parameters**: Prefer `$param` placeholders over hardcoded values
5. **Categorize queries**: Use categories for reporting and filtering
6. **Version your packs**: Include version numbers for reproducibility

## Validation

Validate your benchmark pack before running:

```bash
./zig-out/bin/graphbench validate --config examples/configs/my_config.json
```

This checks:
- JSON/YAML syntax
- Required fields present
- Query syntax (basic GQL validation)
- Weight values are positive numbers
