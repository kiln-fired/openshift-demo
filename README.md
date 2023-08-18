# Kiln Demo for OpenShift Container Platform

## Prerequisites

1. An OpenShift v4 or OKD cluster. [CRC](https://github.com/crc-org/crc) is a great way to run one locally.
1. The [OperatorSDK](https://sdk.operatorframework.io/docs/installation/) for installing a Kiln Operator release on you cluster

## Provisioning the demo

### Install the Kiln Operator

1. Create a namespace for the Kiln Operator

   `oc new-project kiln-operator`

1. Deploy the Kiln Operator using the Operator SDK

   `operator-sdk run bundle --install-mode AllNamespaces -n kiln-operator quay.io/kiln-fired/kiln-operator-bundle:latest -n kiln-operator`

### Prepare x509 Issuers

1. Go to the OperatorHub and install the cert-manager Operator for Red Hat OpenShift and configure it to watch all namespaces.

1. Apply the certificate manifest to your target namespace.

   `oc apply -f openshift-cert-manager/ -n openshift-cert-manager`

1. The root CA that will be used to issue x509 certificates for RPC endpoints is now stored in a secret called `rootca`.

   Verify that the secret exists and contains 3 keys (this may take a minute or two):

   `oc describe secret rootca -n openshift-cert-manager`

### Deploy the Demo

1. Create a namespace for the Kiln demo.

   `oc new-project kiln-demo`

1. Provision the mining node

   `oc apply -f kiln-demo/miner`

1. Provision Alice's nodes

   `oc apply -f kiln-demo/alice`

1. Provision Bob's nodes

   `oc apply -f kiln-demo/bob`

## Sample Channel and Transaction Script

1. The following output should match the `alice-address` secret:

   `alice$ lncli --network simnet newaddress np2wkh`

1. The follow should produce an expected output of 0:

   `alice$ lncli --network simnet getwalletbalance`

1. The following will speed up coinbase maturity for Alice's block rewards: 

   `miner$ ./start-btcctl generate 100`

1. Now Alice should have a balance:

   `alice$ lncli --network simnet getwalletbalance`

1. Get Bob's public key:

   `bob$ lncli --network=simnet getinfo`

1. Connect Alice to Bob:

   `alice$ lncli --network=simnet connect <bob_pubkey>@bob`

1. The following should show Bob's node:

   `alice$ lncli --network=simnet listpeers`

1. Open a channel with Bob:

   `alice$ lncli --network=simnet openchannel --node_key=<bob_pubkey> --local_amt=1000000`

1. The following should show Bob's channel:

   `alice$ lncli --network=simnet listchannels`

1. Get an invoice from Bob:

   `bob$ lncli --network=simnet addinvoice --amt=10000`

1. Pay the invoice:

   `alice$ lncli --network=simnet sendpayment --pay_req=<encoded_invoice>`

1. Bob should have a channel balance

   `alice+bob$ lncli --network=simnet channelbalance`

1. Retreive channel point

   `alice$ lncli --network=simnet listchannels`

1. Close the channel

   `alice$ lncli --network=simnet closechannel --funding_txid=<funding_txid> --output_index=<output_index>`

1. The following should show a balance for Bob:

   `alice+bob$ lncli --network=simnet walletbalance`
