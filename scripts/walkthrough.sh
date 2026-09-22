#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-kiln-demo}"
SCB_SECRET="alice-scb"

for cmd in oc jq; do
  command -v "$cmd" >/dev/null || { echo "Missing required command: $cmd" >&2; exit 1; }
done

lightning_pod() {
  local node="$1"
  oc get pod -n "$NAMESPACE" -l "app=lightningnode,lightningnode_cr=$node" -o jsonpath='{.items[0].metadata.name}'
}

lightning_host() {
  local node="$1"
  oc get lightningnode "$node" -n "$NAMESPACE" -o jsonpath='{.status.rpcAddress}' | cut -d: -f1
}

lncli() {
  local node="$1"
  shift
  local pod
  pod="$(lightning_pod "$node")"
  oc exec -n "$NAMESPACE" "$pod" -c lnd --     lncli --lnddir=/data --network=simnet "$@"
}

echo "==> Checking readiness"
oc wait -n "$NAMESPACE" bitcoinnode/btcd --for=condition=Ready --timeout=60s
oc wait -n "$NAMESPACE" lightningnode/alice --for=condition=Ready --timeout=60s
oc wait -n "$NAMESPACE" lightningnode/bob --for=condition=Ready --timeout=60s

echo
echo "==> Kiln runtime status"
oc get bitcoinnodes,lightningnodes,lightningpeers,lightningchannels -n "$NAMESPACE"
oc get lightningnode alice -n "$NAMESPACE"   -o jsonpath='Alice: {.status.runtime.identityPubkey}{" blocks="}{.status.runtime.blockHeight}{" peers="}{.status.runtime.numPeers}{"\n"}'
oc get lightningnode bob -n "$NAMESPACE"   -o jsonpath='Bob:   {.status.runtime.identityPubkey}{" blocks="}{.status.runtime.blockHeight}{" peers="}{.status.runtime.numPeers}{"\n"}'

ALICE_KEY="$(lncli alice getinfo | jq -r .identity_pubkey)"
BOB_KEY="$(lncli bob getinfo | jq -r .identity_pubkey)"
BOB_HOST="$(lightning_host bob)"
PVC="$(oc get pvc -n "$NAMESPACE" -l 'app=lightningnode,lightningnode_cr=alice' -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$PVC" ]] || { echo "Could not resolve Alice PVC" >&2; exit 1; }
PVC_UID="$(oc get pvc "$PVC" -n "$NAMESPACE" -o jsonpath='{.metadata.uid}')"

echo
echo "==> Alice wallet balance"
lncli alice walletbalance

echo
echo "==> Declaring Alice -> Bob peer connectivity"
cat <<EOF | oc apply -f -
apiVersion: bitcoin.kiln-fired.github.io/v1alpha1
kind: LightningPeer
metadata:
  name: bob
  namespace: $NAMESPACE
spec:
  nodeRef: alice
  pubkey: $BOB_KEY
  address: $BOB_HOST:9735
EOF
oc wait -n "$NAMESPACE" lightningpeer/bob --for=condition=Ready --timeout=180s
oc get lightningpeer bob -n "$NAMESPACE"

echo
echo "==> Declaring a 1,000,000 sat channel"
cat <<EOF | oc apply -f -
apiVersion: bitcoin.kiln-fired.github.io/v1alpha1
kind: LightningChannel
metadata:
  name: alice-to-bob
  namespace: $NAMESPACE
spec:
  peerRef: bob
  capacitySats: 1000000
  private: true
  minConfs: 1
EOF
oc wait -n "$NAMESPACE" lightningchannel/alice-to-bob --for=condition=Ready --timeout=240s

CHANNEL_POINT="$(oc get lightningchannel alice-to-bob -n "$NAMESPACE" -o jsonpath='{.status.channelPoint}')"
[[ -n "$CHANNEL_POINT" ]] || { echo "LightningChannel did not report a channel point" >&2; exit 1; }

echo "==> Waiting for Alice's retained static channel backup"
oc wait -n "$NAMESPACE" lightningnode/alice --for=condition=BackupReady --timeout=180s
for _ in {1..60}; do
  SCB_DATA="$(oc get secret "$SCB_SECRET" -n "$NAMESPACE" -o jsonpath='{.data.channel\.backup}' 2>/dev/null || true)"
  [[ -n "$SCB_DATA" ]] && break
  sleep 2
done
[[ -n "$SCB_DATA" ]] || { echo "Alice SCB Secret is empty" >&2; exit 1; }
SCB_UID="$(oc get secret "$SCB_SECRET" -n "$NAMESPACE" -o jsonpath='{.metadata.uid}')"
SCB_OWNERS="$(oc get secret "$SCB_SECRET" -n "$NAMESPACE" -o jsonpath='{.metadata.ownerReferences}' 2>/dev/null || true)"
[[ -z "$SCB_OWNERS" || "$SCB_OWNERS" == "<no value>" ]] || {
  echo "Alice SCB Secret unexpectedly has an owner reference" >&2
  exit 1
}
echo "Retained SCB Secret: $SCB_SECRET ($SCB_UID)"

oc get lightningpeer,lightningchannel -n "$NAMESPACE"
lncli alice listchannels

echo
echo "==> Bob creates a 10,000 sat invoice"
INVOICE="$(lncli bob addinvoice --amt=10000 | jq -r .payment_request)"
[[ -n "$INVOICE" && "$INVOICE" != "null" ]] || { echo "Could not create invoice" >&2; exit 1; }

echo "==> Alice pays Bob"
lncli alice payinvoice --force "$INVOICE"

echo
echo "==> Channel balances"
echo "--- Alice ---"
lncli alice channelbalance
echo "--- Bob ---"
lncli bob channelbalance

echo
echo "==> Replacing Alice's pod"
ALICE_POD="$(lightning_pod alice)"
oc delete pod "$ALICE_POD" -n "$NAMESPACE" --wait=true
oc wait -n "$NAMESPACE" pod/"$ALICE_POD" --for=condition=Ready --timeout=240s
oc wait -n "$NAMESPACE" lightningnode/alice --for=condition=Ready --timeout=240s

ALICE_KEY_AFTER_POD="$(lncli alice getinfo | jq -r .identity_pubkey)"
[[ "$ALICE_KEY_AFTER_POD" == "$ALICE_KEY" ]] || {
  echo "Alice identity changed after pod replacement" >&2
  exit 1
}
echo "Identity survived pod replacement: $ALICE_KEY_AFTER_POD"
oc wait -n "$NAMESPACE" lightningnode/alice --for=condition=BackupReady --timeout=180s
[[ "$(oc get secret "$SCB_SECRET" -n "$NAMESPACE" -o jsonpath='{.metadata.uid}')" == "$SCB_UID" ]] || {
  echo "Alice SCB Secret changed after pod replacement" >&2
  exit 1
}
[[ -n "$(oc get secret "$SCB_SECRET" -n "$NAMESPACE" -o jsonpath='{.data.channel\.backup}')" ]] || {
  echo "Alice SCB Secret became empty after pod replacement" >&2
  exit 1
}

echo
echo "==> Deleting Alice's LightningNode while retaining its PVC"
oc delete -f manifests/lightning/alice.yaml --wait=true --timeout=240s
oc get pvc "$PVC" -n "$NAMESPACE" >/dev/null
oc get secret "$SCB_SECRET" -n "$NAMESPACE" >/dev/null
[[ "$(oc get secret "$SCB_SECRET" -n "$NAMESPACE" -o jsonpath='{.metadata.uid}')" == "$SCB_UID" ]] || {
  echo "Alice SCB Secret changed during LightningNode deletion" >&2
  exit 1
}
[[ -n "$(oc get secret "$SCB_SECRET" -n "$NAMESPACE" -o jsonpath='{.data.channel\.backup}')" ]] || {
  echo "Alice SCB Secret disappeared or became empty during LightningNode deletion" >&2
  exit 1
}
PVC_UID_AFTER_DELETE="$(oc get pvc "$PVC" -n "$NAMESPACE" -o jsonpath='{.metadata.uid}')"
[[ "$PVC_UID_AFTER_DELETE" == "$PVC_UID" ]] || {
  echo "Alice PVC changed during LightningNode deletion" >&2
  exit 1
}

echo "==> Recreating Alice's LightningNode"
oc apply -f manifests/lightning/alice.yaml
oc wait -n "$NAMESPACE" lightningnode/alice --for=condition=Ready --timeout=300s
oc wait -n "$NAMESPACE" lightningnode/alice --for=condition=BackupReady --timeout=180s
[[ "$(oc get secret "$SCB_SECRET" -n "$NAMESPACE" -o jsonpath='{.metadata.uid}')" == "$SCB_UID" ]] || {
  echo "Alice SCB Secret changed after LightningNode recreation" >&2
  exit 1
}

ALICE_KEY_AFTER_CR="$(lncli alice getinfo | jq -r .identity_pubkey)"
PVC_UID_AFTER_CR="$(oc get pvc "$PVC" -n "$NAMESPACE" -o jsonpath='{.metadata.uid}')"
oc wait -n "$NAMESPACE" lightningpeer/bob --for=condition=Ready --timeout=180s
oc wait -n "$NAMESPACE" lightningchannel/alice-to-bob --for=condition=Ready --timeout=180s
CHANNEL_POINT_AFTER_CR="$(oc get lightningchannel alice-to-bob -n "$NAMESPACE" -o jsonpath='{.status.channelPoint}')"

[[ "$ALICE_KEY_AFTER_CR" == "$ALICE_KEY" ]] || {
  echo "Alice identity changed after LightningNode recreation" >&2
  exit 1
}
[[ "$PVC_UID_AFTER_CR" == "$PVC_UID" ]] || {
  echo "Alice PVC changed after LightningNode recreation" >&2
  exit 1
}
[[ "$CHANNEL_POINT_AFTER_CR" == "$CHANNEL_POINT" ]] || {
  echo "Kiln-managed channel identity changed after LightningNode recreation" >&2
  exit 1
}

echo
echo "Demo complete."
echo "  Alice identity: $ALICE_KEY_AFTER_CR"
echo "  Alice PVC UID:  $PVC_UID_AFTER_CR"
echo "  Lightning peer CR: reconciled"
echo "  Lightning channel CR: $CHANNEL_POINT_AFTER_CR"
echo "  Lightning payment: successful"
echo "  Static channel backup: retained in $SCB_SECRET"
echo "  Pod recovery: successful"
echo "  CR recovery: successful"
