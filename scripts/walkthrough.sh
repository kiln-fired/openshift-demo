#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-kiln-demo}"
PVC="lnd-data-alice-0"

for cmd in oc jq; do
  command -v "$cmd" >/dev/null || { echo "Missing required command: $cmd" >&2; exit 1; }
done

lncli() {
  local node="$1"
  shift
  oc exec -n "$NAMESPACE" "$node-0" -c lnd --     lncli --lnddir=/data --network=simnet "$@"
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
  address: bob.$NAMESPACE.svc.cluster.local:9735
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
oc delete pod alice-0 -n "$NAMESPACE" --wait=true
oc wait -n "$NAMESPACE" pod/alice-0 --for=condition=Ready --timeout=240s
oc wait -n "$NAMESPACE" lightningnode/alice --for=condition=Ready --timeout=240s

ALICE_KEY_AFTER_POD="$(lncli alice getinfo | jq -r .identity_pubkey)"
[[ "$ALICE_KEY_AFTER_POD" == "$ALICE_KEY" ]] || {
  echo "Alice identity changed after pod replacement" >&2
  exit 1
}
echo "Identity survived pod replacement: $ALICE_KEY_AFTER_POD"

echo
echo "==> Deleting Alice's LightningNode while retaining its PVC"
oc delete -f manifests/lightning/alice.yaml --wait=true --timeout=240s
oc get pvc "$PVC" -n "$NAMESPACE" >/dev/null
PVC_UID_AFTER_DELETE="$(oc get pvc "$PVC" -n "$NAMESPACE" -o jsonpath='{.metadata.uid}')"
[[ "$PVC_UID_AFTER_DELETE" == "$PVC_UID" ]] || {
  echo "Alice PVC changed during LightningNode deletion" >&2
  exit 1
}

echo "==> Recreating Alice's LightningNode"
oc apply -f manifests/lightning/alice.yaml
oc wait -n "$NAMESPACE" lightningnode/alice --for=condition=Ready --timeout=300s

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
echo "  Pod recovery: successful"
echo "  CR recovery: successful"
