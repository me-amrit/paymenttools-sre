#!/usr/bin/env bash
set -euo pipefail

# Usage: ./setup.sh [dev|qa|prod]
ENVIRONMENT="${1:-dev}"
CLUSTER_NAME="paymenttools"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_DIR="$SCRIPT_DIR/.tmp/port-forwards"

case "$ENVIRONMENT" in
  dev|qa|prod) ;;
  *) echo "Unknown environment: $ENVIRONMENT (available: dev, qa, prod)" && exit 1 ;;
esac

stop_port_forwards() {
  if [[ ! -d "$PID_DIR" ]]; then
    return
  fi

  for pid_file in "$PID_DIR"/*.pid; do
    [[ -e "$pid_file" ]] || continue
    pid="$(cat "$pid_file")"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
    rm -f "$pid_file"
  done
}

start_port_forward() {
  local namespace="$1"
  local service="$2"
  local port_mapping="$3"
  local name="$4"

  kubectl port-forward -n "$namespace" "svc/$service" "$port_mapping" &>/dev/null &
  echo "$!" > "$PID_DIR/$name.pid"
}

# prerequisites
for cmd in docker k3d kubectl openssl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Missing: $cmd" && exit 1
  fi
done
if ! docker info &>/dev/null; then
  echo "Docker is not running." && exit 1
fi

# cluster
if k3d cluster list 2>/dev/null | grep -q "$CLUSTER_NAME"; then
  echo "Cluster already exists, recreating..."
  k3d cluster delete "$CLUSTER_NAME"
fi

echo "Creating k3d cluster..."
k3d cluster create "$CLUSTER_NAME" \
  --port "8080:8080@loadbalancer" \
  --port "9090:9090@loadbalancer" \
  --port "3000:3000@loadbalancer" \
  --agents 1 \
  --wait

kubectl wait --for=condition=Ready nodes --all --timeout=120s

echo "Deploying payment services ($ENVIRONMENT)..."
kubectl apply -k "$SCRIPT_DIR/k8s/overlays/$ENVIRONMENT"

# monitoring
echo "Deploying monitoring..."
kubectl apply -f "$SCRIPT_DIR/monitoring/namespace.yaml"
GRAFANA_PASSWORD="$(openssl rand -base64 24)"
kubectl create secret generic grafana-credentials \
  -n monitoring \
  --from-literal=admin-user=admin \
  --from-literal="admin-password=$GRAFANA_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$SCRIPT_DIR/monitoring/prometheus/"
kubectl apply -f "$SCRIPT_DIR/monitoring/grafana/"

# wait
echo "Waiting for pods..."
kubectl wait --for=condition=Ready pods --all -n payment --timeout=120s
kubectl wait --for=condition=Ready pods --all -n monitoring --timeout=120s

# port forwarding
mkdir -p "$PID_DIR"
stop_port_forwards
sleep 1
start_port_forward payment payment-gateway 8080:8080 gateway
start_port_forward monitoring prometheus 9090:9090 prometheus
start_port_forward monitoring grafana 3000:3000 grafana
sleep 3

# smoke test
echo ""
if curl -sf http://localhost:8080/healthz &>/dev/null; then
  echo "Health check: OK"
else
  echo "Health check: FAILED (service may still be starting)"
fi

RESPONSE=$(curl -sf -X POST http://localhost:8080/pay \
  -H "Content-Type: application/json" \
  -d '{"payment_id": "smoke-test", "amount": 100, "currency": "EUR", "recipient": "merchant-123"}' 2>/dev/null) || true
if [[ -n "$RESPONSE" ]]; then
  echo "Payment test: $RESPONSE"
fi

echo ""
echo "Ready."
echo "  Gateway:    http://localhost:8080"
echo "  Prometheus: http://localhost:9090"
echo "  Grafana:    http://localhost:3000"
echo "  Grafana login: admin / $GRAFANA_PASSWORD"
echo ""
echo "  ./teardown.sh to clean up"
