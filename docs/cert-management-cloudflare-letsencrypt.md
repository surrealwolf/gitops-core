# Certificate Management with Cloudflare and Let's Encrypt

This document captures what we learned running cert-manager with Cloudflare (DNS-01) and Let's Encrypt across multiple Kubernetes clusters.

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

**Workaround:** Change the set by adding a cluster-specific identifier (e.g. `cert-<cluster>.dataknife.net`) so each cluster has a different set. New orders with the new set are not considered renewals and still count against other limits, but they avoid this one.

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
- Use `selector.dnsNames` so only the right domains use this solver (e.g. `*.dataknife.net`, `dataknife.net`, `*.dataknife.ai`, `dataknife.ai`).
- Cluster-scoped; no `namespace` in the ClusterIssuer.

---

## Cluster-Specific Identifiers (Avoiding "5 per Exact Set")

When the same wildcard (e.g. `*.dataknife.net`, `dataknife.net`) is issued on many clusters, the "exact set" is identical and you quickly hit the 5-per-7-days limit.

**Approach:** Add one extra DNS name per cluster so each cluster has a different set, e.g.:

- `cert-rancher-manager.dataknife.net`
- `cert-nprd-apps.dataknife.net`
- `cert-poc-apps.dataknife.net`
- `cert-prd-apps.dataknife.net`

These are subdomains of `dataknife.net`, so:

- They are covered by `*.dataknife.net` in the ClusterIssuer selector.
- DNS-01 can create `_acme-challenge.cert-<cluster>.dataknife.net` via the Cloudflare API.

Add the same `cert-<cluster>.dataknife.net` to both:

- `wildcard-dataknife-net` (in `cert-manager`)
- `wildcard-dataknife-net-default-ingress` (in `kube-system`)

so each cluster has one unique set for the .net certs. Two orders per cluster for that set (2 &lt; 5) is fine.

---

## Namespaces and Secret Naming

### Avoid Overriding Namespace in Kustomize

If the overlay `kustomization.yaml` sets `namespace: cert-manager`, it overrides **all** resources, including those with `metadata.namespace: kube-system`. That can put both:

- `wildcard-dataknife-net` (intended: `cert-manager`)
- `wildcard-dataknife-net-default-ingress` (intended: `kube-system`)

into `cert-manager`, both using `secretName: wildcard-dataknife-net-tls` → **two Certificates, one secret, conflict**.

**Fix:** Do **not** set `namespace` in the overlay `kustomization.yaml`. Rely on `metadata.namespace` in each resource:

- ClusterIssuer: cluster-scoped (no namespace)
- `wildcard-dataknife-net`, `wildcard-dataknife-ai`: `cert-manager`
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

We also create:

- A Certificate `wildcard-dataknife-net-default-ingress` in `kube-system` with `secretName: wildcard-dataknife-net-tls`
- A ConfigMap `ingress-nginx-controller` in `kube-system` with `default-ssl-certificate: kube-system/wildcard-dataknife-net-tls`

On RKE2, the controller does **not** read `ingress-nginx-controller`, so that default-ssl-certificate setting has no effect unless the controller is configured to use it. For RKE2, the default cert would need to be wired through `rke2-ingress-nginx-controller` or the Helm chart.

---

## Troubleshooting

### Certificate Stuck "Issuing" / "Secret does not exist"

- Normal while DNS-01 is in progress (TXT creation, propagation, validation).
- Check: `kubectl get challenges -A`, `kubectl get orders -A`, `kubectl describe challenge …`, cert-manager logs.

### "Too many certificates already issued for exact set of identifiers"

- You’ve hit the [5 per exact set per 7 days](https://letsencrypt.org/docs/rate-limits/#new-certificates-per-exact-set-of-identifiers) limit.
- Options: wait for refill (1 cert every 34 hours), or change the set (e.g. add `cert-<cluster>.<domain>`).

### Cloudflare: "Could not route to /client/v4/zones/..." or Invalid Object

- Token needs **Zone – Zone – Read** in addition to **Zone – DNS – Edit**.
- Create a new token with both, update the secret, restart cert-manager if needed.

### "Secret was issued for 'X'. Two conflicting Certificates pointing to the same secret"

- Two Certificates in the **same namespace** use the same `secretName`.
- Often from a Kustomize `namespace:` override putting both in `cert-manager`. Fix: remove the override and set `metadata.namespace` correctly per resource so the default-ingress cert and its secret live in `kube-system`.

### Fleet: "exists and cannot be imported into the current release: invalid ownership metadata"

- Resource was created outside Fleet/Helm. Delete it so Fleet can recreate it with Helm metadata.

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
