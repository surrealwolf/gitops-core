#!/bin/bash
# Manual script to apply cert-manager configuration for testing
# This applies the rancher-manager overlay configuration

set -e

CLUSTER_CONTEXT="${1:-rancher-manager}"
CLOUDFLARE_TOKEN="${2}"

if [ -z "$CLOUDFLARE_TOKEN" ]; then
    echo "Error: Cloudflare API token is required"
    echo "Usage: $0 [cluster-context] [cloudflare-api-token]"
    echo ""
    echo "Example:"
    echo "  $0 rancher-manager your-cloudflare-api-token-here"
    echo ""
    echo "To get a Cloudflare API token:"
    echo "  1. Go to https://dash.cloudflare.com/profile/api-tokens"
    echo "  2. Create token with 'Zone' - 'DNS:Edit' permissions"
    echo "  3. Use the token value here"
    exit 1
fi

echo "Applying cert-manager configuration to cluster: $CLUSTER_CONTEXT"
echo ""

# Step 1: Create Cloudflare API token secret
echo "Step 1: Creating Cloudflare API token secret..."
kubectl --context "$CLUSTER_CONTEXT" create secret generic cloudflare-api-token \
    --from-literal=api-token="$CLOUDFLARE_TOKEN" \
    -n cert-manager \
    --dry-run=client -o yaml | kubectl --context "$CLUSTER_CONTEXT" apply -f -

if [ $? -eq 0 ]; then
    echo "✓ Cloudflare secret created/updated"
else
    echo "✗ Failed to create Cloudflare secret"
    exit 1
fi
echo ""

# Step 2: Apply ClusterIssuer
echo "Step 2: Applying ClusterIssuer..."
kubectl --context "$CLUSTER_CONTEXT" apply -f cert-manager/overlays/rancher-manager/clusterissuer.yaml

if [ $? -eq 0 ]; then
    echo "✓ ClusterIssuer applied"
else
    echo "✗ Failed to apply ClusterIssuer"
    exit 1
fi
echo ""

# Step 3: Apply Certificate resources
echo "Step 3: Applying Certificate resources..."
kubectl --context "$CLUSTER_CONTEXT" apply -f cert-manager/overlays/rancher-manager/certificate-wildcard-dataknife-net.yaml
kubectl --context "$CLUSTER_CONTEXT" apply -f cert-manager/overlays/rancher-manager/certificate-wildcard-dataknife-ai.yaml

if [ $? -eq 0 ]; then
    echo "✓ Certificate resources applied"
else
    echo "✗ Failed to apply Certificate resources"
    exit 1
fi
echo ""

# Step 4: Apply default ingress certificate
echo "Step 4: Applying default ingress certificate..."
kubectl --context "$CLUSTER_CONTEXT" apply -f cert-manager/overlays/rancher-manager/certificate-default-ingress-net.yaml

if [ $? -eq 0 ]; then
    echo "✓ Default ingress certificate applied"
else
    echo "✗ Failed to apply default ingress certificate"
    exit 1
fi
echo ""

# Step 5: Apply ConfigMap for nginx-ingress
echo "Step 5: Applying ConfigMap for nginx-ingress default certificate..."
kubectl --context "$CLUSTER_CONTEXT" apply -f cert-manager/overlays/rancher-manager/configmap-default-cert.yaml

if [ $? -eq 0 ]; then
    echo "✓ ConfigMap applied"
else
    echo "✗ Failed to apply ConfigMap"
    exit 1
fi
echo ""

# Step 6: Verify
echo "Step 6: Verifying configuration..."
echo ""
echo "Checking ClusterIssuer:"
kubectl --context "$CLUSTER_CONTEXT" get clusterissuer letsencrypt-dns01 -o wide

echo ""
echo "Checking Certificates:"
kubectl --context "$CLUSTER_CONTEXT" get certificates -n cert-manager
kubectl --context "$CLUSTER_CONTEXT" get certificates -n kube-system

echo ""
echo "Checking Certificate status (this may take a few minutes):"
echo "Run this command to monitor certificate issuance:"
echo "  kubectl --context $CLUSTER_CONTEXT get certificates -A -w"
echo ""
echo "To check certificate details:"
echo "  kubectl --context $CLUSTER_CONTEXT describe certificate wildcard-dataknife-net -n cert-manager"
echo ""
echo "✓ Configuration applied successfully!"
echo ""
echo "Note: Certificate issuance may take 1-5 minutes as Let's Encrypt performs DNS-01 challenge"
