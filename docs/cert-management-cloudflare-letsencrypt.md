# Certificate Management with Cloudflare and Let's Encrypt

This document captures what we learned running cert-manager with Cloudflare (DNS-01) and Let's Encrypt across multiple Kubernetes clusters.

---

## Certificate Management Strategy

**Centralized Certificate Issuance**: To minimize Let's Encrypt certificate requests and avoid rate limits, we use a centralized approach:

- **Only `rancher-manager` cluster** requests certificates from Let's Encrypt
- **Downstream clusters** (`nprd-apps`, `poc-apps`, `prd-apps`) receive TLS secrets synced from `rancher-manager`
- **Certificate sync** is performed via `scripts/sync-certs-from-rancher-manager.sh`

This reduces certificate requests from **4 orders** (4 clusters × 1 certificate) to just **1 order** (wildcard-dataknife-net), staying well within Let's Encrypt's "5 per exact set" rate limit.

**Certificates issued on rancher-manager:**
- `cert-manager/wildcard-dataknife-net-tls` (requested from Let's Encrypt)
- `kube-system/wildcard-dataknife-net-tls` (copied from `cert-manager/wildcard-dataknife-net-tls` for nginx default SSL)

**Note:** We only request `wildcard-dataknife-net-tls` once in the `cert-manager` namespace. The secret is then copied to `kube-system` for the default ingress controller, avoiding duplicate Let's Encrypt requests for the same DNS names.

**Default Ingress Certificate Configuration:**

The wildcard certificate is configured as the default SSL certificate for nginx-ingress controllers on all downstream clusters. This means:

- **Any Ingress resource without a TLS section** automatically uses the Let's Encrypt wildcard certificate
- **No need to specify `secretName`** in Ingress resources for `*.dataknife.net` domains
- The certificate is automatically synced to `kube-system/wildcard-dataknife-net-tls` on all clusters

**RKE2 Requirement:** RKE2's nginx-ingress controller requires `--default-ssl-certificate` to be set as a **command-line flag** (not just in ConfigMap). Per [GitHub issue #1408](https://github.com/rancher/rke/issues/1408), this must be configured in the DaemonSet arguments.

**GitOps Configuration:**
- Kustomize patches are configured in each overlay's `kustomization.yaml` to automatically add the flag
- Patch file: `cert-manager/base/daemonset-nginx-ingress-patch.yaml`
- Fleet will attempt to apply the patch automatically when syncing

**Manual Setup (if GitOps patch fails):**
```bash
kubectl patch daemonset -n kube-system rke2-ingress-nginx-controller \
  --type=json \
  -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--default-ssl-certificate=kube-system/wildcard-dataknife-net-tls"}]'

# Restart pods to pick up the change
kubectl delete pod -n kube-system -l app=rke2-ingress-nginx-controller
```

**Best Practice:**
- Remove explicit `tls` sections from Ingress resources for `*.dataknife.net` domains
- Let them inherit the default certificate automatically
- This simplifies configuration and ensures all Ingresses use the same synced certificate

**Syncing certificates:**

The sync script (`scripts/sync-certs-from-rancher-manager.sh`) copies secrets from `rancher-manager` to downstream clusters, preserving namespace and secret data.

```bash
# Sync to all downstream clusters
./scripts/sync-certs-from-rancher-manager.sh

# Sync to specific cluster
./scripts/sync-certs-from-rancher-manager.sh nprd-apps
```

**Automation options:**

1. **Kubernetes CronJob (Recommended)**: An automated CronJob is configured in the `rancher-manager` overlay that syncs certificates daily at 2 AM UTC. This is the preferred method for automatic syncing.

   **Setup:**
   ```bash
   # Create the kubeconfig secret with credentials for all clusters
   ./scripts/create-cert-sync-kubeconfig-secret.sh rancher-manager
   ```

   The CronJob resources are included in `cert-manager/overlays/rancher-manager/`:
   - `serviceaccount-cert-sync.yaml` - ServiceAccount and RBAC
   - `configmap-cert-sync-script.yaml` - Sync script
   - `cronjob-cert-sync.yaml` - CronJob definition (daily at 2 AM UTC)

   **Verify:**
   ```bash
   kubectl --context=rancher-manager get cronjob cert-sync -n cert-manager
   kubectl --context=rancher-manager get jobs -n cert-manager -l purpose=cert-sync
   ```

2. **Manual**: Run the script manually when needed:
   ```bash
   ./scripts/sync-certs-from-rancher-manager.sh
   ```

3. **External automation**: CI/CD pipeline or external scheduler that runs the sync script after detecting certificate renewal.

**Note:** Since cert-manager renews certificates 30 days before expiration, syncing daily (via CronJob) is sufficient to keep downstream clusters updated.

---

## Overview

- **cert-manager**: Kubernetes operator for TLS certificates
- **Let's Encrypt**: Free, automated CA; certificates valid 90 days, renewed automatically
- **Cloudflare**: DNS provider for DNS-01 challenge (TXT records)
- **DNS-01**: Validates domain control via `_acme-challenge.<domain>` TXT records; supports wildcards

---

## Let's Encrypt Rate Limits

Let's Encrypt enforces [rate limits](https://letsencrypt.org/docs/rate-limits/). These matter when issuing the same or similar certificates across many clusters.

### New Certificates per Exact Set of Identifiers

**Limit:** Up to **5 certificates** per exact same set of identifiers every **7 days**. Refill: 1 certificate every **34 hours**.

- The "exact set" is the full list of DNS names and IPs in the certificate (order and case don't matter).
- Example: `[*.dataknife.net, dataknife.net]` is one set. Issuing that same set 6+ times in 7 days hits the limit.
- **Common cause:** Deploying the same wildcard cert to many clusters, or repeatedly deleting/recreating certs while debugging.

**Reference:** [New Certificates per Exact Set of Identifiers](https://letsencrypt.org/docs/rate-limits/#new-certificates-per-exact-set-of-identifiers)

**Workaround:** (1) **Wait for refill** — capacity refills at 1 certificate every 34 hours; space out orders. (2) **Consolidate** to one Certificate per cluster for the same set (e.g. one .net cert, reuse its secret) to reduce orders. (3) **Different domain** — add an identifier from a domain you control that is *not* under your wildcard (Let's Encrypt rejects subdomains as redundant). (4) **Public IPs** in `spec.ipAddresses` — private/RFC1918 IPs are rejected; only public IPs work.

---

### New Certificates per Registered Domain

**Limit:** Up to **50 certificates** per registered domain (e.g. `dataknife.net`) every **7 days**. Refill: 1 certificate every **202 minutes**.

- Applies per registered domain (from the Public Suffix List).
- All accounts and all requests for that domain share this limit.

**Reference:** [New Certificates per Registered Domain](https://letsencrypt.org/docs/rate-limits/#new-certificates-per-registered-domain)

---

### New Orders per Account

**Limit:** Up to **300 new orders** per ACME account every **3 hours**. Refill: 1 order every **36 seconds**.

- Each certificate request is one order.
- One certificate can include up to 100 identifiers (DNS names or IPs).

**Reference:** [New Orders per Account](https://letsencrypt.org/docs/rate-limits/#new-orders-per-account)

---

### Other Limits (summary)

- **Authorization failures per identifier:** 5 per identifier per account per hour; can block new orders for that identifier.
- **Consecutive authorization failures:** Can lead to long-term pause for an identifier; see [Let's Encrypt rate limits](https://letsencrypt.org/docs/rate-limits/).
- **Renewals:** ARI-based renewals are exempt from rate limits. Non-ARI renewals with the same identifier set can still hit "New Certificates per Exact Set of Identifiers" (5 per 7 days).

---

## Cloudflare Setup for DNS-01

### API Token

1. Create a token at [Cloudflare API Tokens](https://dash.cloudflare.com/profile/api-tokens).
2. **Required permissions:**
   - **Zone – Zone – Read** (for all zones, or the specific zones you use)
   - **Zone – DNS – Edit** (for all zones, or the specific zones)

Without **Zone – Read**, cert-manager can fail with errors like:
`Could not route to /client/v4/zones/dns_records/, perhaps your object identifier is invalid?` when resolving zone IDs or cleaning up TXT records.

### Secret in Kubernetes

Store the token in each cluster where cert-manager runs:

```bash
kubectl create secret generic cloudflare-api-token \
  --from-literal=api-token=YOUR_TOKEN \
  -n cert-manager
```

The ClusterIssuer references this via `apiTokenSecretRef` (name `cloudflare-api-token`, key `api-token`).

### ClusterIssuer (DNS-01 + Cloudflare)

- Use `dns01.cloudflare.apiTokenSecretRef` (not `apiKeySecretRef`).
- Use `selector.dnsNames` so only the right domains use this solver (e.g. `*.dataknife.net`, `dataknife.net`).
- Cluster-scoped; no `namespace` in the ClusterIssuer.

---

## Rate-Limit Refill Strategy (Exact Set)

When the same wildcard (e.g. `*.dataknife.net`, `dataknife.net`) is issued on many clusters, the "exact set" is identical and you hit the 5-per-7-days limit.

**Identifiers that don't work:**
- **Subdomains under the wildcard** (e.g. `cert-<cluster>.dataknife.net`): rejected as *"redundant with a wildcard domain in the same request"*.
- **Private/RFC1918 node IPs** in `spec.ipAddresses` (e.g. 192.168.x.x, 10.x.x.x): rejected as *"IP address is in a reserved address block: [RFC1918]: Private-Use"*. Only public IPs are accepted.

**Approach: use the base set and rely on refill.** Use only `[*.dataknife.net, dataknife.net]` (no extra `dnsNames` or `ipAddresses`). The limit refills at **1 certificate every 34 hours**. With 4 clusters × 2 certs (wildcard + default-ingress) = 8 orders for the same set:

- **Space out:** After hitting the limit, wait for refill (1 per 34h). cert-manager will retry; orders will succeed as capacity returns. Expect ~8 × 34h ≈ 11+ days to clear a full 8-order backlog after the 5-per-7-days window.
- **Consolidate (optional):** Use one Certificate per cluster for .net (e.g. only `wildcard-dataknife-net-default-ingress` in `kube-system`) and reuse its secret elsewhere. That reduces to 4 orders per set (4 &lt; 5).

---

## Namespaces and Secret Naming

### Avoid Overriding Namespace in Kustomize

If the overlay `kustomization.yaml` sets `namespace: cert-manager`, it overrides **all** resources, including those with `metadata.namespace: kube-system`. That can put both:

- `wildcard-dataknife-net` (intended: `cert-manager`)
- `wildcard-dataknife-net-default-ingress` (intended: `kube-system`)

into `cert-manager`, both using `secretName: wildcard-dataknife-net-tls` → **two Certificates, one secret, conflict**.

**Fix:** Do **not** set `namespace` in the overlay `kustomization.yaml`. Rely on `metadata.namespace` in each resource:

- ClusterIssuer: cluster-scoped (no namespace)
- `wildcard-dataknife-net`: `cert-manager`
- `wildcard-dataknife-net-default-ingress`, ConfigMap for default cert: `kube-system`

Then:

- `cert-manager/wildcard-dataknife-net-tls` (from `wildcard-dataknife-net`)
- `kube-system/wildcard-dataknife-net-tls` (from `wildcard-dataknife-net-default-ingress`)

No conflict.

---

## RKE2 Ingress and Default SSL Certificate

### ConfigMap Names

- RKE2’s nginx-ingress reads: `--configmap=$(POD_NAMESPACE)/rke2-ingress-nginx-controller`
- So it uses the ConfigMap **`rke2-ingress-nginx-controller`** in `kube-system`, **not** `ingress-nginx-controller`.

A ConfigMap named `ingress-nginx-controller` in `kube-system` is **not** used by RKE2’s controller. To set the default SSL certificate for RKE2, the `default-ssl-certificate` key must be in **`rke2-ingress-nginx-controller`** (e.g. by patching that ConfigMap or via the RKE2/Helm chart).

### Fleet and ConfigMap Ownership

If a ConfigMap like `ingress-nginx-controller` was created with `kubectl apply` and has no Helm/Fleet labels/annotations, Fleet may report that it "exists and cannot be imported" (missing `app.kubernetes.io/managed-by: Helm`, `meta.helm.sh/release-name`, etc.). Deleting the ConfigMap lets Fleet recreate it with the right metadata. On RKE2, deleting `ingress-nginx-controller` does **not** affect the controller, because it only uses `rke2-ingress-nginx-controller`.

---

## Fleet / Helm Ownership

Fleet uses Helm to apply manifests. Resources created with `kubectl apply` (or similar) lack Helm labels/annotations, so Fleet cannot adopt them and reports "invalid ownership metadata".

**Fix:** Delete the existing resource (Certificate, ClusterIssuer, ConfigMap, etc.) so Fleet can recreate it with:

- `app.kubernetes.io/managed-by: Helm`
- `meta.helm.sh/release-name`
- `meta.helm.sh/release-namespace`

After that, Fleet can manage it and the bundle can become Ready.

---

## Default Ingress Certificate (kube-system)

The wildcard certificate (`*.dataknife.net`) is configured as the **default SSL certificate** for nginx-ingress controllers on all downstream clusters.

**How it works:**
- The Let's Encrypt wildcard certificate is issued on `rancher-manager` cluster
- The certificate secret (`wildcard-dataknife-net-tls`) is automatically synced to `kube-system` namespace on all downstream clusters via CronJob
- The nginx-ingress DaemonSet is patched to use `--default-ssl-certificate=kube-system/wildcard-dataknife-net-tls` as a command-line flag
- **Any Ingress without TLS configuration** automatically uses this certificate

**RKE2 Requirement:** RKE2's nginx-ingress controller requires `--default-ssl-certificate` to be set as a **command-line flag** (not just in ConfigMap). Per [GitHub issue #1408](https://github.com/rancher/rke/issues/1408), this must be configured in the DaemonSet arguments.

**GitOps Configuration:**
- Kustomize patches are configured in each overlay's `kustomization.yaml` to automatically add the flag
- Patch file: `cert-manager/base/daemonset-nginx-ingress-patch.yaml`
- Fleet will attempt to apply the patch automatically when syncing

**Manual Setup (if GitOps patch fails):**
```bash
kubectl patch daemonset -n kube-system rke2-ingress-nginx-controller \
  --type=json \
  -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--default-ssl-certificate=kube-system/wildcard-dataknife-net-tls"}]'

# Restart pods to pick up the change
kubectl delete pod -n kube-system -l app=rke2-ingress-nginx-controller
```

**Best Practice:**
- Remove explicit `tls` sections from Ingress resources for `*.dataknife.net` domains
- Let them inherit the default certificate automatically
- This simplifies configuration and ensures all Ingresses use the same synced certificate

**Note:** ConfigMap-based default SSL certificate configuration (`default-ssl-certificate` key in `rke2-ingress-nginx-controller` ConfigMap) is **not sufficient** for RKE2. The command-line flag is required.

---

## Troubleshooting

### Certificate Stuck "Issuing" / "Secret does not exist"

- Normal while DNS-01 is in progress (TXT creation, propagation, validation).
- Check: `kubectl get challenges -A`, `kubectl get orders -A`, `kubectl describe challenge …`, cert-manager logs.

### "Too many certificates already issued for exact set of identifiers"

- You’ve hit the [5 per exact set per 7 days](https://letsencrypt.org/docs/rate-limits/#new-certificates-per-exact-set-of-identifiers) limit.
- Options: wait for refill (1 cert every 34 hours), consolidate to 1 Certificate per cluster for that set, or change the set using a different domain (not under the wildcard) or public IPs only (private/RFC1918 IPs are rejected).

### "Domain name 'X' is redundant with a wildcard domain in the same request"

- You added a subdomain (e.g. `cert-rancher-manager.dataknife.net`) while `*.dataknife.net` is in the same certificate. Let's Encrypt rejects it.
- **Fix:** Remove the subdomain from `dnsNames`. To get a unique set, use a different domain (not under the wildcard) or public IPs in `spec.ipAddresses`; private/RFC1918 IPs are rejected.

### "IP address is in a reserved address block: [RFC1918]: Private-Use"

- You added private/RFC1918 IPs (e.g. 192.168.x.x, 10.x.x.x) to `spec.ipAddresses`. Let's Encrypt will not issue for them.
- **Fix:** Remove `ipAddresses` or use only public IPs. For private clusters, rely on the base `dnsNames` and the rate-limit refill strategy (1 cert every 34 hours).

### Cloudflare: "Could not route to /client/v4/zones/..." or Invalid Object

- Token needs **Zone – Zone – Read** in addition to **Zone – DNS – Edit**.
- Create a new token with both, update the secret, restart cert-manager if needed.

### "Secret was issued for 'X'. Two conflicting Certificates pointing to the same secret"

- Two Certificates in the **same namespace** use the same `secretName`.
- Often from a Kustomize `namespace:` override putting both in `cert-manager`. Fix: remove the override and set `metadata.namespace` correctly per resource so the default-ingress cert and its secret live in `kube-system`.

### Fleet: "exists and cannot be imported into the current release: invalid ownership metadata"

- Resource was created outside Fleet/Helm. Delete it so Fleet can recreate it with Helm metadata.

### Updating Rancher Certificate

Rancher requires a specific process to update its certificate. The wildcard certificate can be used for Rancher by updating the `tls-rancher-ingress` secret and Helm values.

**Process:**
1. Copy the Let's Encrypt wildcard certificate to `cattle-system/tls-rancher-ingress` secret
2. Update Helm values to set `ingress.tls.source=secret`
3. Upgrade the Rancher Helm release
4. Restart Rancher deployment

**Important:** Rancher's dynamic listener may cache certificates. If the certificate doesn't update after following the steps, delete and recreate the `tls-rancher-ingress` secret, then restart Rancher pods.

For detailed instructions, see the [Rancher documentation](https://ranchermanager.docs.rancher.com/getting-started/installation-and-upgrade/resources/update-rancher-certificate).

**Note:** If changing from self-signed or Let's Encrypt to a custom certificate, you may need to:
- Update Rancher agents on downstream clusters
- Force update Fleet clusters in Rancher UI

### Fixing Fleet Agent TLS Issues After Certificate Update

After updating Rancher's certificate, Fleet agents on downstream clusters may fail to register with the management cluster due to TLS certificate verification errors. This manifests as:

- Fleet bundles stuck in `WaitApplied` state
- Fleet agent logs showing: `tls: failed to verify certificate: x509: failed to load system roots and no roots provided`
- Cluster registrations failing to complete

**Root Cause:**
The Fleet agent container has `readOnlyRootFilesystem: true`, preventing access to system CA certificate stores. If the `apiServerCA` field in the `fleet-agent-bootstrap` secret is empty, the agent cannot verify the Rancher server's TLS certificate.

**Solution:**

1. **Download the CA certificate** (if using Let's Encrypt):
   ```bash
   curl -s https://letsencrypt.org/certs/isrgrootx1.pem | base64 -w 0 > /tmp/isrg-root-x1-base64.txt
   ```

2. **Update the Fleet agent bootstrap secret** on each downstream cluster:
   ```bash
   # For each downstream cluster (nprd-apps, poc-apps, prd-apps, etc.)
   kubectl --context <cluster-name> patch secret -n cattle-fleet-system fleet-agent-bootstrap \
     --type='json' -p="[{\"op\": \"replace\", \"path\": \"/data/apiServerCA\", \"value\": \"$(cat /tmp/isrg-root-x1-base64.txt)\"}]"
   ```

3. **Restart the Fleet agent** to pick up the new CA certificate:
   ```bash
   kubectl --context <cluster-name> delete pod -n cattle-fleet-system -l app=fleet-agent
   ```

4. **Verify the fix**:
   ```bash
   # Check Fleet agent logs (should no longer show TLS errors)
   kubectl --context <cluster-name> logs -n cattle-fleet-system -l app=fleet-agent --tail=20
   
   # Check Fleet bundle status (should transition from WaitApplied to Ready)
   kubectl --context rancher-manager get bundle -A | grep gitops-core-cert-manager
   ```

**For custom CA certificates:**
If Rancher uses a custom CA certificate (not Let's Encrypt), extract the root CA certificate from your certificate chain and base64 encode it:
```bash
# Extract CA from certificate chain
echo | openssl s_client -connect rancher.dataknife.net:443 -showcerts 2>/dev/null | \
  sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' | \
  tail -35 | base64 -w 0 > /tmp/custom-ca-base64.txt

# Then use the same patch command above with the custom CA
```

**Note:** This fix is required whenever the Rancher server's certificate changes and the Fleet agent bootstrap secret doesn't include the appropriate CA certificate.

---

## References

### Let's Encrypt Rate Limits

- [New Certificates per Exact Set of Identifiers](https://letsencrypt.org/docs/rate-limits/#new-certificates-per-exact-set-of-identifiers)
- [New Certificates per Registered Domain](https://letsencrypt.org/docs/rate-limits/#new-certificates-per-registered-domain)
- [New Orders per Account](https://letsencrypt.org/docs/rate-limits/#new-orders-per-account)
- [Rate Limits (overview)](https://letsencrypt.org/docs/rate-limits/)

### cert-manager and ACME

- [cert-manager Documentation](https://cert-manager.io/docs/)
- [ACME DNS-01](https://cert-manager.io/docs/configuration/acme/dns01/)
- [Cloudflare DNS-01](https://cert-manager.io/docs/configuration/acme/dns01/cloudflare/)
