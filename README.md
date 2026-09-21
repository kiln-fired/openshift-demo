# Kiln on OpenShift

A repeatable demo of [Kiln](https://github.com/kiln-fired/kiln-operator) running Bitcoin and Lightning infrastructure on Red Hat OpenShift.

The demo provisions one persistent btcd `BitcoinNode` on simnet and two persistent LND `LightningNode` resources, Alice and Bob. The walkthrough then declares Alice-to-Bob connectivity with a `LightningPeer`, declares the funded relationship with a `LightningChannel`, pays Bob through LND, replaces Alice's pod, and finally deletes/recreates Alice's `LightningNode` while proving that her identity, PVC, and Kiln-owned channel survive.

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
│ │ Alice / LND  │      │ Bob / LND    │                │
│ │ retained PVC │      │ retained PVC │                │
│ └──────┬───────┘      └──────────────┘                │
│        │ nodeRef                                       │
│        ▼                                               │
│ ┌──────────────────┐                                   │
│ │ LightningPeer/bob│                                   │
│ └────────┬─────────┘                                   │
│          │ peerRef                                     │
│          ▼                                             │
│ ┌─────────────────────────┐                            │
│ │ LightningChannel/       │                            │
│ │ alice-to-bob            │                            │
│ └─────────────────────────┘                            │
└───────────────────────────────────────────────────────┘
```

## What it demonstrates

- declarative Bitcoin and Lightning resources
- immediate-resource API references: `LightningNode → BitcoinNode →` runtime dependency, `LightningPeer → LightningNode`, and `LightningChannel → LightningPeer`
- managed Lightning network/RPC configuration derived from `bitcoinConnection.nodeRef`
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

### 3. Declare Alice-to-Bob connectivity

The walkthrough resolves Bob's LND pubkey, then creates a first-class `LightningPeer/bob`:

```yaml
apiVersion: bitcoin.kiln-fired.github.io/v1alpha1
kind: LightningPeer
spec:
  nodeRef: alice
  pubkey: <Bob identity pubkey>
  address: bob.kiln-demo.svc.cluster.local:9735
```

Kiln observes LND and reconciles the connection. The demo waits for `LightningPeer.Ready=True`.

### 4. Declare a channel

The channel references only its immediate dependency, the peer:

```yaml
apiVersion: bitcoin.kiln-fired.github.io/v1alpha1
kind: LightningChannel
metadata:
  name: alice-to-bob
spec:
  peerRef: bob
  capacitySats: 1000000
  private: true
  minConfs: 1
```

Kiln owns the funding lifecycle and reports the resulting channel point in status. The walkthrough waits for `LightningChannel.Ready=True` and verifies the same channel survives later node recovery.

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

The script fails if the peer or channel CR does not reconcile, the payment does not complete, or Alice's identity, PVC, or Kiln-owned channel identity changes across recovery.

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
- managed `LightningNode` network/RPC configuration derived through `bitcoinConnection.nodeRef`
- first-class `LightningPeer` and `LightningChannel` desired state
- `LightningChannel.peerRef` as the single channel dependency reference
- retained Lightning PVC lifecycle
- restricted RPC credential publication
