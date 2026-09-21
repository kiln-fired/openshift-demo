#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-kiln-demo}"

echo "==> Removing demo namespace"
oc delete namespace "$NAMESPACE" --ignore-not-found --wait=true

echo "==> Removing demo SCC"
oc delete scc kiln-demo --ignore-not-found

echo "Demo resources removed. The Kiln operator was left installed."
