#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="paymenttools"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_DIR="$SCRIPT_DIR/.tmp/port-forwards"

if [[ -d "$PID_DIR" ]]; then
  for pid_file in "$PID_DIR"/*.pid; do
    [[ -e "$pid_file" ]] || continue
    pid="$(cat "$pid_file")"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
    rm -f "$pid_file"
  done
fi

if k3d cluster list 2>/dev/null | grep -q "$CLUSTER_NAME"; then
  k3d cluster delete "$CLUSTER_NAME"
  echo "Cluster deleted."
else
  echo "No cluster found."
fi
