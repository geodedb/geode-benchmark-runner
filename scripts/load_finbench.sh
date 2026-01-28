#!/bin/bash
# Load LDBC FinBench data into Geode
# Usage: ./load_finbench.sh /path/to/sf0.01
#
# shellcheck disable=SC2034  # Unused variables are intentional - parsing CSV columns

set -e

DATA_DIR="${1:-/tmp/gdc_bench/sf0.01}"
GEODE_CMD="${GEODE_CMD:-/home/benji/src/gl/devnw/codepros/geode/geode/zig-out/bin/geode}"
SERVER="${SERVER:-127.0.0.1:3141}"

if [ ! -d "$DATA_DIR/snapshot" ]; then
    echo "Error: Data directory not found: $DATA_DIR/snapshot"
    exit 1
fi

echo "Loading FinBench data from: $DATA_DIR"
echo "Server: $SERVER"

# Function to run a query
run_query() {
    $GEODE_CMD query --server $SERVER --insecure "$1" 2>/dev/null | grep -v "status_class" || true
}

# Load Person nodes
echo "Loading Person nodes..."
count=0
tail -n +2 "$DATA_DIR/snapshot/Person.csv" | while IFS='|' read -r personId personName isBlocked createTime gender birthday country city; do
    # Escape single quotes in personName
    personName=$(echo "$personName" | sed "s/'/''/g")
    query="CREATE (p:Person {id: $personId, name: '$personName', isBlocked: $isBlocked, gender: '$gender', country: '$country', city: '$city'}) RETURN p"
    run_query "$query" > /dev/null
    count=$((count + 1))
    if [ $((count % 100)) -eq 0 ]; then
        echo "  Loaded $count Person nodes..."
    fi
done
echo "  Done loading Person nodes"

# Load Company nodes
echo "Loading Company nodes..."
count=0
tail -n +2 "$DATA_DIR/snapshot/Company.csv" | while IFS='|' read -r companyId companyName isBlocked createTime country city business description url; do
    companyName=$(echo "$companyName" | sed "s/'/''/g")
    business=$(echo "$business" | sed "s/'/''/g")
    query="CREATE (c:Company {id: $companyId, name: '$companyName', isBlocked: $isBlocked, country: '$country', city: '$city', business: '$business'}) RETURN c"
    run_query "$query" > /dev/null
    count=$((count + 1))
    if [ $((count % 100)) -eq 0 ]; then
        echo "  Loaded $count Company nodes..."
    fi
done
echo "  Done loading Company nodes"

# Load Account nodes
echo "Loading Account nodes..."
count=0
tail -n +2 "$DATA_DIR/snapshot/Account.csv" | while IFS='|' read -r accountId createTime isBlocked accountType nickname phonenum email freqLoginType lastLoginTime accountLevel; do
    nickname=$(echo "$nickname" | sed "s/'/''/g")
    query="CREATE (a:Account {id: $accountId, isBlocked: $isBlocked, type: '$accountType', nickname: '$nickname', level: '$accountLevel'}) RETURN a"
    run_query "$query" > /dev/null
    count=$((count + 1))
    if [ $((count % 100)) -eq 0 ]; then
        echo "  Loaded $count Account nodes..."
    fi
done
echo "  Done loading Account nodes"

# Load Loan nodes
echo "Loading Loan nodes..."
count=0
tail -n +2 "$DATA_DIR/snapshot/Loan.csv" | while IFS='|' read -r loanId loanAmount balance createTime loanUsage interestRate; do
    loanUsage=$(echo "$loanUsage" | sed "s/'/''/g")
    query="CREATE (l:Loan {id: $loanId, amount: $loanAmount, balance: $balance, usage: '$loanUsage', interestRate: $interestRate}) RETURN l"
    run_query "$query" > /dev/null
    count=$((count + 1))
    if [ $((count % 100)) -eq 0 ]; then
        echo "  Loaded $count Loan nodes..."
    fi
done
echo "  Done loading Loan nodes"

# Load Medium nodes
echo "Loading Medium nodes..."
count=0
tail -n +2 "$DATA_DIR/snapshot/Medium.csv" | while IFS='|' read -r mediumId mediumType isBlocked createTime lastLoginTime riskLevel; do
    riskLevel=$(echo "$riskLevel" | sed "s/'/''/g")
    query="CREATE (m:Medium {id: $mediumId, type: '$mediumType', isBlocked: $isBlocked, riskLevel: '$riskLevel'}) RETURN m"
    run_query "$query" > /dev/null
    count=$((count + 1))
    if [ $((count % 100)) -eq 0 ]; then
        echo "  Loaded $count Medium nodes..."
    fi
done
echo "  Done loading Medium nodes"

echo ""
echo "Loading relationships..."

# Load PersonOwnAccount relationships
echo "Loading PersonOwnAccount relationships..."
count=0
tail -n +2 "$DATA_DIR/snapshot/PersonOwnAccount.csv" | while IFS='|' read -r personId accountId createTime; do
    query="MATCH (p:Person {id: $personId}), (a:Account {id: $accountId}) CREATE (p)-[:OWN]->(a) RETURN p, a"
    run_query "$query" > /dev/null
    count=$((count + 1))
    if [ $((count % 100)) -eq 0 ]; then
        echo "  Loaded $count PersonOwnAccount relationships..."
    fi
done
echo "  Done loading PersonOwnAccount"

# Load CompanyOwnAccount relationships
echo "Loading CompanyOwnAccount relationships..."
count=0
tail -n +2 "$DATA_DIR/snapshot/CompanyOwnAccount.csv" | while IFS='|' read -r companyId accountId createTime; do
    query="MATCH (c:Company {id: $companyId}), (a:Account {id: $accountId}) CREATE (c)-[:OWN]->(a) RETURN c, a"
    run_query "$query" > /dev/null
    count=$((count + 1))
    if [ $((count % 100)) -eq 0 ]; then
        echo "  Loaded $count CompanyOwnAccount relationships..."
    fi
done
echo "  Done loading CompanyOwnAccount"

# Load AccountTransferAccount relationships (sample - this can be large)
echo "Loading AccountTransferAccount relationships (first 1000)..."
count=0
tail -n +2 "$DATA_DIR/snapshot/AccountTransferAccount.csv" | head -1000 | while IFS='|' read -r fromId toId amount createTime orderNum comment payType goodsType; do
    query="MATCH (a1:Account {id: $fromId}), (a2:Account {id: $toId}) CREATE (a1)-[:TRANSFER {amount: $amount}]->(a2) RETURN a1, a2"
    run_query "$query" > /dev/null
    count=$((count + 1))
    if [ $((count % 100)) -eq 0 ]; then
        echo "  Loaded $count AccountTransferAccount relationships..."
    fi
done
echo "  Done loading AccountTransferAccount"

echo ""
echo "Verifying data load..."
run_query "MATCH (n) RETURN labels(n)[0] AS label, count(n) AS count"

echo ""
echo "FinBench data load complete!"
