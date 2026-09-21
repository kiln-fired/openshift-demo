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
oc get bitcoinnodes,lightningnodes -n "$NAMESPACE"
oc get lightningnode alice -n "$NAMESPACE"   -o jsonpath='Alice: {.status.runtime.identityPubkey}{" blocks="}{.status.runtime.blockHeight}{" peers="}{.status.runtime.numPeers}{"\n"}'
oc get lightningnode bob -n "$NAMESPACE"   -o jsonpath='Bob:   {.status.runtime.identityPubkey}{" blocks="}{.status.runtime.blockHeight}{" peers="}{.status.runtime.numPeers}{"\n"}'

ALICE_KEY="$(lncli alice getinfo | jq -r .identity_pubkey)"
BOB_KEY="$(lncli bob getinfo | jq -r .identity_pubkey)"
PVC_UID="$(oc get pvc "$PVC" -n "$NAMESPACE" -o jsonpath='{.metadata.uid}')"

echo
echo "==> Alice wallet balance"
lncli alice walletbalance

echo
echo "==> Connecting Alice to Bob"
if ! lncli alice listpeers | jq -e --arg pub "$BOB_KEY" '.peers[]? | select(.pub_key == $pub)' >/dev/null; then
  lncli alice connect "$BOB_KEY@bob:9735"
else
  echo "Alice is already connected to Bob"
fi

echo
echo "==> Opening a 1,000,000 sat channel"
if [[ "$(lncli alice listchannels | jq '.channels | length')" -eq 0 ]]; then
  lncli alice openchannel --node_key="$BOB_KEY" --local_amt=1000000
  echo "Waiting for a periodic simnet block to confirm the channel..."
  for _ in {1..30}; do
    [[ "$(lncli alice listchannels | jq '.channels | length')" -gt 0 ]] && break
    sleep 5
  done
fi

CHANNEL_COUNT="$(lncli alice listchannels | jq '.channels | length')"
[[ "$CHANNEL_COUNT" -gt 0 ]] || { echo "Channel did not become active" >&2; exit 1; }
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

[[ "$ALICE_KEY_AFTER_CR" == "$ALICE_KEY" ]] || {
  echo "Alice identity changed after LightningNode recreation" >&2
  exit 1
}
[[ "$PVC_UID_AFTER_CR" == "$PVC_UID" ]] || {
  echo "Alice PVC changed after LightningNode recreation" >&2
  exit 1
}

echo
echo "Demo complete."
echo "  Alice identity: $ALICE_KEY_AFTER_CR"
echo "  Alice PVC UID:  $PVC_UID_AFTER_CR"
echo "  Lightning payment: successful"
echo "  Pod recovery: successful"
echo "  CR recovery: successful"
