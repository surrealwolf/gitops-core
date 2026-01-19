# Cert-Manager GitOps Configuration

This directory contains GitOps configurations for automatic Let's Encrypt wildcard certificate provisioning and renewal using cert-manager.

## Overview

This configuration provides automatic TLS certificate management for:
- `*.dataknife.net` wildcard certificate

Certificates are automatically issued by Let's Encrypt using DNS-01 challenge and renewed before expiration.

## Directory Structure

```
cert-manager/
├── base/                      # Base configurations (reusable across clusters)
│   ├── clusterissuer.yaml    # Let's Encrypt ClusterIssuer template
│   ├── certificate-*.yaml    # Certificate resources for wildcards
│   ├── kustomization.yaml    # Kustomize configuration
│   └── README.md             # Base configuration documentation
├── overlays/                  # Cluster-specific overlays
│   ├── rancher-manager/      # rancher-manager cluster configuration
│   ├── nprd-apps/            # nprd-apps cluster configuration
│   ├── poc-apps/             # poc-apps cluster configuration
│   └── prd-apps/             # prd-apps cluster configuration
│       ├── clusterissuer.yaml # DNS provider configuration
│       ├── kustomization.yaml # Overlay kustomization
│       └── fleet.yaml        # Fleet targeting
└── README.md                 # This file
```

## Quick Start

### 1. Prerequisites

- cert-manager installed on cluster (already installed on nprd-apps)
- DNS provider API credentials (Cloudflare, Route53, etc.)
- DNS zone `dataknife.net` accessible via API

### 2. Configure DNS Provider

1. **Choose your DNS provider** (Cloudflare recommended):
   - See `secrets/cert-manager/README.md` for provider-specific instructions

2. **Create DNS provider secret**:
   ```bash
   # Example: Cloudflare
   kubectl create secret generic cloudflare-api-token \
     --from-literal=api-token=your-cloudflare-api-token-here \
     -n cert-manager
   ```

3. **Configure ClusterIssuer**:
   - Edit `overlays/{cluster-name}/clusterissuer.yaml` for each cluster
   - Uncomment and configure your DNS provider section

### 3. Deploy via GitOps

The configuration is automatically deployed via Fleet when committed to Git:
- Fleet monitors: `cert-manager/overlays/{cluster-name}`
- Changes are automatically synced to each cluster
- Wildcard certificates are deployed to all clusters: rancher-manager, nprd-apps, poc-apps, prd-apps

### 4. Verify Certificate Status

```bash
# Check ClusterIssuer
kubectl get clusterissuer letsencrypt-dns01

# Check Certificates
kubectl get certificates -n cert-manager

# Check certificate details
kubectl describe certificate wildcard-dataknife-net -n cert-manager

# Check TLS secrets (created automatically)
kubectl get secrets -n cert-manager | grep wildcard
```

## Using Certificates

Once certificates are issued, use them in Ingress resources:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
spec:
  tls:
    - hosts:
        - app.dataknife.net
      secretName: wildcard-dataknife-net-tls  # From cert-manager namespace
  rules:
    - host: app.dataknife.net
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-app
                port:
                  number: 80
```

### Default Ingress Certificate

The wildcard certificate (`*.dataknife.net`) is configured as the **default SSL certificate** for nginx-ingress controllers.

This means:
- **Any Ingress without TLS configuration** will automatically use this certificate
- **No need to specify `secretName`** in Ingress resources for dataknife.net domains
- The certificate is automatically created in the `kube-system` namespace for nginx-ingress

**Important:** RKE2's nginx-ingress controller requires `--default-ssl-certificate` to be set as a **command-line flag** (not just in ConfigMap). Per [GitHub issue #1408](https://github.com/rancher/rke/issues/1408), this must be configured in the DaemonSet arguments.

**One-time setup per cluster:**
```bash
kubectl patch daemonset -n kube-system rke2-ingress-nginx-controller \
  --type=json \
  -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--default-ssl-certificate=kube-system/wildcard-dataknife-net-tls"}]'
```

After applying the patch, restart the nginx-ingress pods:
```bash
kubectl delete pod -n kube-system -l app=rke2-ingress-nginx-controller
```

**Note:** Fleet/Kustomize patches are configured in each overlay's `kustomization.yaml`, but they may not be able to patch RKE2-managed DaemonSets. If the automated patch fails, apply the patch manually using the command above.

**Example Ingress without TLS specification (uses default certificate):**
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
spec:
  rules:
    - host: app.dataknife.net
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-app
                port:
                  number: 80
  # No TLS section needed - default certificate will be used automatically
```

**Example Ingress with explicit TLS (still works, overrides default):**
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
spec:
  tls:
    - hosts:
        - app.dataknife.net
      secretName: wildcard-dataknife-net-tls  # Explicit certificate
  rules:
    - host: app.dataknife.net
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-app
                port:
                  number: 80
```

### Sharing Certificates Across Namespaces

Certificates create secrets in the `cert-manager` namespace. To use in other namespaces:

**Option 1: Copy secret** (manual):
```bash
kubectl get secret wildcard-dataknife-net-tls -n cert-manager -o yaml | \
  sed 's/namespace: cert-manager/namespace: your-namespace/' | \
  kubectl apply -f -
```

**Option 2: Reference from cert-manager namespace** (if ingress controller supports cross-namespace):
Some ingress controllers allow referencing secrets across namespaces. Check your ingress controller documentation.

**Option 3: Create Certificate per namespace** (recommended):
Create Certificate resources in each namespace that needs the certificate.

## Certificate Renewal

Certificates are automatically renewed by cert-manager:
- **Renewal trigger**: 30 days before expiration
- **Certificate lifetime**: 90 days (Let's Encrypt standard)
- **No manual intervention required**

Monitor renewal status:
```bash
kubectl get certificates -n cert-manager -w
```

## Certificate Syncing (Multi-Cluster)

**Centralized Certificate Management**: Only `rancher-manager` cluster requests certificates from Let's Encrypt. TLS secrets are automatically synced to downstream clusters (`nprd-apps`, `poc-apps`, `prd-apps`) via a Kubernetes CronJob.

This reduces Let's Encrypt certificate requests from 8 (4 clusters × 2 certs) to just 2 (wildcard-net, wildcard-ai), avoiding rate limits.

### Automatic Sync via CronJob

A CronJob is configured in `cert-manager/overlays/rancher-manager/` that syncs certificates daily at 2 AM UTC:

**Setup:**
```bash
# Create kubeconfig secret with credentials for all clusters
./scripts/create-cert-sync-kubeconfig-secret.sh rancher-manager
```

**Verify:**
```bash
# Check CronJob
kubectl --context=rancher-manager get cronjob cert-sync -n cert-manager

# Check recent sync jobs
kubectl --context=rancher-manager get jobs -n cert-manager -l purpose=cert-sync

# View sync job logs
kubectl --context=rancher-manager logs -n cert-manager job/cert-sync-<timestamp>
```

**Manual Sync:**
If needed, you can also run the sync manually:
```bash
./scripts/sync-certs-from-rancher-manager.sh
```

For more details, see **[docs/cert-management-cloudflare-letsencrypt.md](../docs/cert-management-cloudflare-letsencrypt.md)**.

## Troubleshooting

### Certificate Not Issuing

1. **Check ClusterIssuer status**:
   ```bash
   kubectl describe clusterissuer letsencrypt-dns01
   ```

2. **Check Certificate status**:
   ```bash
   kubectl describe certificate wildcard-dataknife-net -n cert-manager
   ```

3. **Check DNS provider secret**:
   ```bash
   kubectl get secret -n cert-manager
   kubectl describe secret <dns-provider-secret> -n cert-manager
   ```

4. **Check cert-manager logs**:
   ```bash
   kubectl logs -n cert-manager deployment/cert-manager | grep -i dns
   ```

5. **Check ACME challenges**:
   ```bash
   kubectl get challenges -n cert-manager
   kubectl get orders -n cert-manager
   kubectl describe challenge <challenge-name> -n cert-manager
   ```

### Common Issues

- **DNS provider secret not found**: Ensure secret exists in `cert-manager` namespace with correct name
- **DNS provider API permissions**: Verify credentials have permission to create/edit TXT records; Cloudflare needs **Zone – Read** and **Zone – DNS – Edit**
- **Rate limiting**: See [Let's Encrypt rate limits](https://letsencrypt.org/docs/rate-limits/); especially [5 per exact set per 7 days](https://letsencrypt.org/docs/rate-limits/#new-certificates-per-exact-set-of-identifiers) when reusing the same identifiers across clusters
- **DNS propagation delays**: DNS-01 challenges may take a few minutes

### Getting Help

- **[docs/cert-management-cloudflare-letsencrypt.md](../docs/cert-management-cloudflare-letsencrypt.md)** — Rate limits, Cloudflare, rate-limit refill strategy, Fleet, RKE2, troubleshooting
- Check `base/README.md` for detailed configuration documentation
- Check `secrets/cert-manager/README.md` for DNS provider setup
- Review cert-manager logs: `kubectl logs -n cert-manager deployment/cert-manager`
- Check cert-manager events: `kubectl get events -n cert-manager --sort-by='.lastTimestamp'`

## References

- [cert-manager Documentation](https://cert-manager.io/docs/)
- [Let's Encrypt Documentation](https://letsencrypt.org/docs/)
- [Let's Encrypt Rate Limits](https://letsencrypt.org/docs/rate-limits/):
  - [New Certificates per Exact Set of Identifiers](https://letsencrypt.org/docs/rate-limits/#new-certificates-per-exact-set-of-identifiers)
  - [New Certificates per Registered Domain](https://letsencrypt.org/docs/rate-limits/#new-certificates-per-registered-domain)
  - [New Orders per Account](https://letsencrypt.org/docs/rate-limits/#new-orders-per-account)
- [ACME DNS-01 Challenge](https://cert-manager.io/docs/configuration/acme/dns01/)
- [DNS Provider Configuration (Cloudflare)](https://cert-manager.io/docs/configuration/acme/dns01/cloudflare/)
