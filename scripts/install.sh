#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-kiln-demo}"
OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-kiln-operator}"
BUNDLE_IMG="${BUNDLE_IMG:-quay.io/kiln-fired/kiln-operator-bundle:latest}"

for cmd in oc operator-sdk openssl jq; do
  command -v "$cmd" >/dev/null || { echo "Missing required command: $cmd" >&2; exit 1; }
done

echo "==> Cluster: $(oc whoami --show-server)"
oc create namespace "$NAMESPACE" --dry-run=client -o yaml | oc apply -f -

echo "==> Applying OpenShift security configuration"
oc apply -f openshift/kiln-demo-scc.yaml
oc apply -f openshift/scc-bindings.yaml

if ! oc get crd bitcoinnodes.bitcoin.kiln-fired.github.io >/dev/null 2>&1; then
  echo "==> Installing Kiln operator bundle"
  oc create namespace "$OPERATOR_NAMESPACE" --dry-run=client -o yaml | oc apply -f -
  operator-sdk run bundle "$BUNDLE_IMG"     --namespace "$OPERATOR_NAMESPACE"     --install-mode AllNamespaces
else
  echo "==> Kiln CRDs already installed; using the existing operator"
fi

echo "==> Waiting for Kiln APIs"
for crd in   bitcoinnodes.bitcoin.kiln-fired.github.io   lightningnodes.bitcoin.kiln-fired.github.io   seeds.bitcoin.kiln-fired.github.io; do
  oc wait --for=condition=Established "crd/$crd" --timeout=120s
done

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

echo "==> Creating btcd RPC TLS material"
openssl req -x509 -newkey rsa:2048 -nodes -days 7   -keyout "$tmpdir/tls.key"   -out "$tmpdir/tls.crt"   -subj "/CN=btcd.$NAMESPACE.svc.cluster.local"   -addext "subjectAltName=DNS:btcd,DNS:btcd.$NAMESPACE.svc,DNS:btcd.$NAMESPACE.svc.cluster.local"   >/dev/null 2>&1

oc create secret generic btcd-rpc-tls -n "$NAMESPACE"   --from-file=tls.crt="$tmpdir/tls.crt"   --from-file=tls.key="$tmpdir/tls.key"   --from-file=ca.crt="$tmpdir/tls.crt"   --dry-run=client -o yaml | oc apply -f -

echo "==> Creating demo credentials"
oc create secret generic btcd-rpc-creds -n "$NAMESPACE"   --from-literal=username=kiln   --from-literal=password=kiln-demo-rpc-password   --dry-run=client -o yaml | oc apply -f -

oc create secret generic alice-wallet -n "$NAMESPACE"   --from-literal=password=kiln-demo-alice-password   --dry-run=client -o yaml | oc apply -f -

oc create secret generic bob-wallet -n "$NAMESPACE"   --from-literal=password=kiln-demo-bob-password   --dry-run=client -o yaml | oc apply -f -

echo "==> Creating seed Secrets"
# Alice's existing fixture is intentionally retained because its known simnet
# wallet corresponds to the public reward address used by this demo.
oc apply -f kiln-demo/alice/Seed_alice.yaml
oc apply -f manifests/seeds/bob.yaml
oc apply -f manifests/demo/alice-reward-address.yaml

for secret in alice-seed bob-seed; do
  for _ in {1..60}; do
    oc get secret "$secret" -n "$NAMESPACE" >/dev/null 2>&1 && break
    sleep 2
  done
  oc get secret "$secret" -n "$NAMESPACE" >/dev/null
done

echo "==> Starting btcd"
oc apply -f manifests/bitcoin/btcd.yaml
oc wait -n "$NAMESPACE" bitcoinnode/btcd --for=condition=Ready --timeout=240s

echo "==> Starting Alice and Bob"
oc apply -f manifests/lightning/
oc wait -n "$NAMESPACE" lightningnode/alice --for=condition=Ready --timeout=300s
oc wait -n "$NAMESPACE" lightningnode/bob --for=condition=Ready --timeout=300s

echo
echo "Kiln demo is ready."
oc get bitcoinnodes,lightningnodes -n "$NAMESPACE"
oc get pods,pvc -n "$NAMESPACE"
echo
echo "Next: ./scripts/walkthrough.sh"
