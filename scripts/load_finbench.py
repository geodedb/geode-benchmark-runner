#!/usr/bin/env python3
"""Fast FinBench data loader for Geode using batch queries."""

import csv
import subprocess
import sys
import os
from pathlib import Path

DATA_DIR = sys.argv[1] if len(sys.argv) > 1 else "/tmp/gdc_bench/sf0.01"
GEODE_CMD = os.environ.get("GEODE_CMD", "/home/benji/src/gl/devnw/codepros/geode/geode/zig-out/bin/geode")
SERVER = os.environ.get("SERVER", "127.0.0.1:3141")
BATCH_SIZE = 50  # Number of creates per batch

def run_query(query):
    """Execute a GQL query."""
    try:
        result = subprocess.run(
            [GEODE_CMD, "query", "--server", SERVER, "--insecure", query],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode != 0:
            print(f"Query failed: {result.stderr}")
            return False
        return True
    except subprocess.TimeoutExpired:
        print(f"Query timeout")
        return False
    except Exception as e:
        print(f"Query error: {e}")
        return False

def escape_string(s):
    """Escape single quotes for GQL strings."""
    if s is None:
        return ""
    return str(s).replace("'", "''").replace("\\", "\\\\")

def load_nodes(csv_file, label, id_field, prop_mapping, limit=None):
    """Load nodes from CSV file."""
    print(f"Loading {label} nodes from {csv_file}...")
    count = 0
    errors = 0

    with open(csv_file, 'r') as f:
        reader = csv.DictReader(f, delimiter='|')
        for row in reader:
            if limit and count >= limit:
                break

            # Build properties
            props = [f"id: {row[id_field]}"]
            for csv_col, prop_name, is_string in prop_mapping:
                if csv_col in row and row[csv_col]:
                    val = row[csv_col]
                    if is_string:
                        props.append(f"{prop_name}: '{escape_string(val)}'")
                    else:
                        props.append(f"{prop_name}: {val}")

            props_str = ", ".join(props)
            query = f"CREATE (n:{label} {{{props_str}}}) RETURN n"

            if not run_query(query):
                errors += 1

            count += 1
            if count % 100 == 0:
                print(f"  Loaded {count} {label} nodes ({errors} errors)...")

    print(f"  Done: {count} {label} nodes ({errors} errors)")
    return count, errors

def load_relationships(csv_file, from_label, to_label, rel_type, from_id, to_id, prop_mapping=None, limit=None):
    """Load relationships from CSV file."""
    print(f"Loading {rel_type} relationships from {csv_file}...")
    count = 0
    errors = 0

    with open(csv_file, 'r') as f:
        reader = csv.DictReader(f, delimiter='|')
        for row in reader:
            if limit and count >= limit:
                break

            from_val = row[from_id]
            to_val = row[to_id]

            # Build relationship properties
            if prop_mapping:
                props = []
                for csv_col, prop_name, is_string in prop_mapping:
                    if csv_col in row and row[csv_col]:
                        val = row[csv_col]
                        if is_string:
                            props.append(f"{prop_name}: '{escape_string(val)}'")
                        else:
                            props.append(f"{prop_name}: {val}")
                props_str = " {" + ", ".join(props) + "}" if props else ""
            else:
                props_str = ""

            query = f"MATCH (a:{from_label} {{id: {from_val}}}), (b:{to_label} {{id: {to_val}}}) CREATE (a)-[:{rel_type}{props_str}]->(b) RETURN a, b"

            if not run_query(query):
                errors += 1

            count += 1
            if count % 100 == 0:
                print(f"  Loaded {count} {rel_type} relationships ({errors} errors)...")

    print(f"  Done: {count} {rel_type} relationships ({errors} errors)")
    return count, errors

def main():
    snapshot_dir = Path(DATA_DIR) / "snapshot"

    if not snapshot_dir.exists():
        print(f"Error: Snapshot directory not found: {snapshot_dir}")
        sys.exit(1)

    print(f"Loading FinBench data from: {DATA_DIR}")
    print(f"Server: {SERVER}")
    print()

    total_nodes = 0
    total_rels = 0
    total_errors = 0

    # Load nodes
    c, e = load_nodes(snapshot_dir / "Person.csv", "Person", "personId", [
        ("personName", "name", True),
        ("isBlocked", "isBlocked", False),
        ("gender", "gender", True),
        ("country", "country", True),
        ("city", "city", True),
    ])
    total_nodes += c
    total_errors += e

    c, e = load_nodes(snapshot_dir / "Company.csv", "Company", "companyId", [
        ("companyName", "name", True),
        ("isBlocked", "isBlocked", False),
        ("country", "country", True),
        ("city", "city", True),
        ("business", "business", True),
    ])
    total_nodes += c
    total_errors += e

    c, e = load_nodes(snapshot_dir / "Account.csv", "Account", "accountId", [
        ("isBlocked", "isBlocked", False),
        ("accoutType", "type", True),
        ("nickname", "nickname", True),
        ("accountLevel", "level", True),
    ])
    total_nodes += c
    total_errors += e

    c, e = load_nodes(snapshot_dir / "Loan.csv", "Loan", "loanId", [
        ("loanAmount", "amount", False),
        ("balance", "balance", False),
        ("loanUsage", "usage", True),
        ("interestRate", "interestRate", False),
    ])
    total_nodes += c
    total_errors += e

    c, e = load_nodes(snapshot_dir / "Medium.csv", "Medium", "mediumId", [
        ("mediumType", "type", True),
        ("isBlocked", "isBlocked", False),
        ("riskLevel", "riskLevel", True),
    ])
    total_nodes += c
    total_errors += e

    print()
    print(f"Total nodes loaded: {total_nodes} ({total_errors} errors)")
    print()

    # Load relationships
    c, e = load_relationships(snapshot_dir / "PersonOwnAccount.csv", "Person", "Account", "OWN", "personId", "accountId")
    total_rels += c
    total_errors += e

    c, e = load_relationships(snapshot_dir / "CompanyOwnAccount.csv", "Company", "Account", "OWN", "companyId", "accountId")
    total_rels += c
    total_errors += e

    c, e = load_relationships(snapshot_dir / "PersonApplyLoan.csv", "Person", "Loan", "APPLY", "personId", "loanId")
    total_rels += c
    total_errors += e

    c, e = load_relationships(snapshot_dir / "CompanyApplyLoan.csv", "Company", "Loan", "APPLY", "companyId", "loanId")
    total_rels += c
    total_errors += e

    c, e = load_relationships(snapshot_dir / "PersonInvestCompany.csv", "Person", "Company", "INVEST", "investorId", "companyId", [
        ("ratio", "ratio", False),
    ])
    total_rels += c
    total_errors += e

    c, e = load_relationships(snapshot_dir / "CompanyInvestCompany.csv", "Company", "Company", "INVEST", "investorId", "companyId", [
        ("ratio", "ratio", False),
    ])
    total_rels += c
    total_errors += e

    c, e = load_relationships(snapshot_dir / "PersonGuaranteePerson.csv", "Person", "Person", "GUARANTEE", "fromId", "toId")
    total_rels += c
    total_errors += e

    c, e = load_relationships(snapshot_dir / "CompanyGuaranteeCompany.csv", "Company", "Company", "GUARANTEE", "fromId", "toId")
    total_rels += c
    total_errors += e

    # Transfer relationships - limit to 2000 for faster loading
    c, e = load_relationships(snapshot_dir / "AccountTransferAccount.csv", "Account", "Account", "TRANSFER", "fromId", "toId", [
        ("amount", "amount", False),
    ], limit=2000)
    total_rels += c
    total_errors += e

    c, e = load_relationships(snapshot_dir / "AccountWithdrawAccount.csv", "Account", "Account", "WITHDRAW", "fromId", "toId", [
        ("amount", "amount", False),
    ], limit=2000)
    total_rels += c
    total_errors += e

    c, e = load_relationships(snapshot_dir / "LoanDepositAccount.csv", "Loan", "Account", "DEPOSIT", "loanId", "accountId", [
        ("amount", "amount", False),
    ])
    total_rels += c
    total_errors += e

    c, e = load_relationships(snapshot_dir / "AccountRepayLoan.csv", "Account", "Loan", "REPAY", "accountId", "loanId", [
        ("amount", "amount", False),
    ])
    total_rels += c
    total_errors += e

    c, e = load_relationships(snapshot_dir / "MediumSignInAccount.csv", "Medium", "Account", "SIGN_IN", "mediumId", "accountId")
    total_rels += c
    total_errors += e

    print()
    print(f"Total relationships loaded: {total_rels} ({total_errors} errors)")
    print()

    # Verify
    print("Verifying data load...")
    run_query("MATCH (n) RETURN labels(n)[0] AS label, count(n) AS count")

    print()
    print(f"FinBench data load complete!")
    print(f"Total: {total_nodes} nodes, {total_rels} relationships")

if __name__ == "__main__":
    main()
