#!/bin/bash
# Example netem helper script - apply latency/jitter/loss to loopback or interface

set -e

INTERFACE="${1:-lo}"
RTT_MS="${2:-20}"
JITTER_MS="${3:-5}"
LOSS_PCT="${4:-0}"

case "$5" in
    apply)
        echo "Applying netem to $INTERFACE: RTT=${RTT_MS}ms, jitter=${JITTER_MS}ms, loss=${LOSS_PCT}%"
        sudo tc qdisc add dev "$INTERFACE" root netem delay "${RTT_MS}ms" "${JITTER_MS}ms" loss "${LOSS_PCT}%"
        ;;
    rollback)
        echo "Removing netem from $INTERFACE"
        sudo tc qdisc del dev "$INTERFACE" root 2>/dev/null || echo "No netem to remove"
        ;;
    *)
        echo "Usage: $0 <interface> <rtt_ms> <jitter_ms> <loss_pct> <apply|rollback>"
        echo "Example: $0 lo 20 5 0.1 apply"
        exit 1
        ;;
esac
