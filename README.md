# GitOps Core

GitOps repository for core infrastructure services, focusing on certificate management via Cloudflare and Let's Encrypt.

## Overview

This repository hosts the core service configuration for automatic TLS certificate management using:
- **cert-manager**: Kubernetes certificate management operator
- **Let's Encrypt**: Free TLS certificate authority
- **Cloudflare**: DNS provider for DNS-01 challenge validation

## Quick Start

See [cert-manager/README.md](cert-manager/README.md) for detailed setup and usage instructions.

## Structure

```
.
├── cert-manager/   # Certificate management via Cloudflare and Let's Encrypt
│   ├── base/       # Base configurations (reusable across clusters)
│   └── overlays/   # Cluster-specific overlays
├── docs/           # Documentation (rate limits, Cloudflare, troubleshooting)
└── ...
```

## Services

- **Cert-Manager**: Automatic wildcard certificate provisioning and renewal for `*.dataknife.net` and `*.dataknife.ai` domains

## Documentation

- **[Certificate management with Cloudflare and Let's Encrypt](docs/cert-management-cloudflare-letsencrypt.md)** — Rate limits, Cloudflare setup, cluster-specific identifiers, namespaces, RKE2, Fleet, and troubleshooting.

### Let's Encrypt rate limits

When issuing the same or similar certificates across many clusters, be aware of:

- [New Certificates per Exact Set of Identifiers](https://letsencrypt.org/docs/rate-limits/#new-certificates-per-exact-set-of-identifiers) — 5 per exact set per 7 days
- [New Certificates per Registered Domain](https://letsencrypt.org/docs/rate-limits/#new-certificates-per-registered-domain) — 50 per domain per 7 days
- [New Orders per Account](https://letsencrypt.org/docs/rate-limits/#new-orders-per-account) — 300 per account per 3 hours

See [docs/cert-management-cloudflare-letsencrypt.md](docs/cert-management-cloudflare-letsencrypt.md) for how we avoid these (e.g. cluster-specific DNS names).

## Deployment

This repository is designed to be deployed via Rancher Fleet or other GitOps tools. Each overlay contains cluster-specific configurations.

## Contributing

See individual service directories for service-specific documentation and setup instructions.
