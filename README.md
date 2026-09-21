# Kiln on OpenShift

A repeatable demo of [Kiln](https://github.com/kiln-fired/kiln-operator) running Bitcoin and Lightning infrastructure on Red Hat OpenShift.

The demo provisions one persistent btcd `BitcoinNode` on simnet and two persistent LND `LightningNode` resources, Alice and Bob. The walkthrough funds Alice, opens a Lightning channel, pays Bob, replaces Alice's pod, then deletes and recreates Alice's `LightningNode` while proving that her identity and PVC survive.

> [!WARNING]
> This is a development demo. It uses simnet, demo passwords, a known Alice seed, and automatic block generation. Never reuse these credentials or seed material for real funds.

## Architecture

```text
                         OpenShift
┌───────────────────────────────────────────────────────┐
│ kiln-demo                                             │
│                                                       │
│  ┌──────────────────┐                                 │
│  │ BitcoinNode/btcd │                                 │
│  │ btcd + PVC       │                                 │
│  └────────┬─────────┘                                 │
│           │ nodeRef                                   │
│     ┌─────┴───────────────┐                           │
│     ▼                     ▼                           │
│ ┌──────────────┐      ┌──────────────┐                │
│ │ Alice / LND  │◄────►│ Bob / LND    │                │
│ │ retained PVC │  LN  │ retained PVC │                │
│ └──────────────┘      └──────────────┘                │
└───────────────────────────────────────────────────────┘
```

## What it demonstrates

- declarative Bitcoin and Lightning resources
- `LightningNode.spec.bitcoinConnection.nodeRef`
- persistent Bitcoin and Lightning storage
- authenticated LND runtime readiness
- restricted LND RPC credential publication
- Lightning identity survival across pod replacement
- retained LND state across CR deletion and recreation
- OpenShift security configuration without granting the namespace broad `anyuid`

## Prerequisites

- OpenShift 4.x or OKD with cluster-admin access
- `oc`
- `operator-sdk`
- `openssl`
- `jq`
- access to public images and `quay.io/kiln-fired/kiln-operator-bundle:latest`

Confirm access:

```shell
oc whoami
oc version
```

## Fast path

```shell
./scripts/install.sh
./scripts/walkthrough.sh
```

The install script installs the current Kiln bundle when its CRDs are absent, configures the OpenShift SCC required by Kiln's current fixed UID/GID, creates demo credentials and btcd TLS material, creates seeds, and waits for btcd, Alice, and Bob to report `Ready`.

## Walkthrough

### 1. Provision the environment

```shell
./scripts/install.sh
oc get bitcoinnodes,lightningnodes,pods,pvc -n kiln-demo
```

Inspect Kiln's authenticated runtime view:

```shell
oc get lightningnode alice -n kiln-demo -o yaml
oc get lightningnode bob -n kiln-demo -o yaml
```

Look at `status.phase`, `status.rpcAddress`, `status.rpcSecretName`, and `status.runtime.identityPubkey`.

### 2. Show Alice's simnet balance

```shell
oc exec -n kiln-demo alice-0 -c lnd --   lncli --lnddir=/data --network=simnet walletbalance
```

The demo directs initial simnet mining rewards to an address derived from Alice's development-only seed. btcd generates 400 blocks at startup and then a block every 10 seconds so channel transactions confirm during the demo.

### 3. Connect Alice to Bob

```shell
BOB_KEY="$(oc exec -n kiln-demo bob-0 -c lnd --   lncli --lnddir=/data --network=simnet getinfo | jq -r .identity_pubkey)"

oc exec -n kiln-demo alice-0 -c lnd --   lncli --lnddir=/data --network=simnet connect "$BOB_KEY@bob:9735"
```

### 4. Open a channel

```shell
oc exec -n kiln-demo alice-0 -c lnd --   lncli --lnddir=/data --network=simnet   openchannel --node_key="$BOB_KEY" --local_amt=1000000
```

After a periodic block confirms it:

```shell
oc exec -n kiln-demo alice-0 -c lnd --   lncli --lnddir=/data --network=simnet listchannels
```

### 5. Pay Bob

```shell
INVOICE="$(oc exec -n kiln-demo bob-0 -c lnd --   lncli --lnddir=/data --network=simnet addinvoice --amt=10000 |
  jq -r .payment_request)"

oc exec -n kiln-demo alice-0 -c lnd --   lncli --lnddir=/data --network=simnet payinvoice --force "$INVOICE"
```

Show both channel balances:

```shell
oc exec -n kiln-demo alice-0 -c lnd -- lncli --lnddir=/data --network=simnet channelbalance
oc exec -n kiln-demo bob-0 -c lnd -- lncli --lnddir=/data --network=simnet channelbalance
```

### 6. Prove pod recovery

```shell
ALICE_KEY="$(oc get lightningnode alice -n kiln-demo   -o jsonpath='{.status.runtime.identityPubkey}')"

oc delete pod alice-0 -n kiln-demo
oc wait -n kiln-demo pod/alice-0 --for=condition=Ready --timeout=180s
oc wait -n kiln-demo lightningnode/alice --for=condition=Ready --timeout=180s

oc get lightningnode alice -n kiln-demo   -o jsonpath='{.status.runtime.identityPubkey}{"\n"}'
```

The identity should match `$ALICE_KEY`.

### 7. Prove CR recovery

```shell
PVC=lnd-data-alice-0
oc get pvc "$PVC" -n kiln-demo -o jsonpath='{.metadata.uid}{"\n"}'

oc delete -f manifests/lightning/alice.yaml --wait=true
oc get pvc "$PVC" -n kiln-demo

oc apply -f manifests/lightning/alice.yaml
oc wait -n kiln-demo lightningnode/alice --for=condition=Ready --timeout=300s
```

The same PVC and Alice identity should return.

### 8. Run it all automatically

```shell
./scripts/walkthrough.sh
```

The script fails if the payment does not complete or if Alice's identity/PVC changes.

## OpenShift security note

Kiln currently pins btcd and LND containers to UID/GID `65532`. OpenShift's default restricted SCC normally assigns a namespace-specific UID. This demo creates a dedicated SCC that permits only UID/GID `65532` and binds it only to the service accounts used by the demo.

It does **not** grant the namespace `anyuid`.

## Repository layout

```text
manifests/
  bitcoin/
  lightning/
  seeds/
  demo/
openshift/
  kiln-demo-scc.yaml
  scc-bindings.yaml
scripts/
  install.sh
  walkthrough.sh
  cleanup.sh
```

## Cleanup

```shell
./scripts/cleanup.sh
```

The operator is intentionally left installed for another demo.

## Current Kiln baseline

This repo now follows the current Kiln runtime instead of the 2023 image set:

- btcd `v0.26.2`
- LND `v0.21.0-beta`
- lndinit `v0.1.36-beta-lnd-v0.21.0-beta`
- simnet by default
- shared `BitcoinNode` dependency through `nodeRef`
- retained Lightning PVC lifecycle
- restricted RPC credential publication
