# Kiln Demo for OpenShift Container Platform

## Prerequisites

1. An OpenShift v4 or OKD cluster. [CRC](https://github.com/crc-org/crc) is a great way to run one locally.
2. The [OperatorSDK](https://sdk.operatorframework.io/docs/installation/) for installing a Kiln Operator release on you cluster

## Provisioning the demo

### Install the Kiln Operator

1. Create a namespace for the Kiln Operator

   `oc new-project kiln-operator`

2. Deploy the Kiln Operator using the Operator SDK

   `operator-sdk run bundle --install-mode AllNamespaces -n kiln-operator quay.io/kiln-fired/kiln-operator-bundle:latest -n kiln-operator`

### Prepare x509 Issuers

1. Go to the OperatorHub and install the cert-manager Operator for Red Hat OpenShift and configure it to watch all namespaces.

2. Apply the certificate manifest to your target namespace.

   `oc apply -f openshift-cert-manager/ -n openshift-cert-manager`

5. The root CA that will be used to issue x509 certificates for RPC endpoints is now stored in a secret called `rootca`.

   Verify that the secret exists and contains 3 keys (this may take a minute or two):

   `oc describe secret rootca -n openshift-cert-manager`

### Deploy the Demo

1. Create a namespace for the Kiln demo.

   `oc new-project kiln-demo`

2. Provision the Demo.

   `oc apply -f kiln-demo/`