# hippocampus-demo-site

The public demo for [Hippocampus](https://github.com/fastbean-au/hippocampus). This repo holds two
pieces:

- **The landing page** — a static site (`index.html` + `assets/`) served by Caddy (this README).
- **The hosted showcase** — the runnable demo stacks under [`showcase/`](showcase/) and their
  documentation under [`docs/`](docs/). Start at **[docs/showcase.md](docs/showcase.md)** (with
  per-cloud runbooks [GCP](docs/showcase-gcp.md) / [OCI](docs/showcase-oci.md)). The stacks pull the
  published `ghcr.io/fastbean-au/hippocampus` image; the service source is the separate
  [`hippocampus`](https://github.com/fastbean-au/hippocampus) repo.

The two are separate Docker Compose projects: bring the showcase up first (it creates the shared
network), then the landing page joins it.

```sh
# 1. the showcase (creates the hippocampus-shared network)
docker compose -f showcase/docker-compose.showcase-combined.yaml up -d

# 2. the landing page (joins that network)
docker compose up -d --build
```

## How it's served

It deploys as its **own** Docker Compose project, independent of the showcase's lifecycle. The
showcase's front Caddy reverse-proxies the apex domain to this container by service name over a
shared network — so the showcase has no dependency on this repo, and this site can be brought
up, down, or updated without touching the running demos.

```text
┌─────────────── hippocampus showcase (owns :80/:443) ───────────────┐
│  Caddy ──reverse_proxy──▶ book / logs / auth / grafana             │
│    └────reverse_proxy────▶ hippocampus-site:80  ◀── this repo ─────┘
│                              (over the `hippocampus-shared` network)
```

## Deploy

The showcase stack must be up first (it creates the `hippocampus-shared` network). Then, from
this repo:

```sh
docker compose up -d --build
```

The site is live at the showcase's apex domain (`https://${BASE_DOMAIN}/`), with TLS handled by
the front Caddy.

## Update the site

Edit `index.html` / `assets/`, then rebuild and redeploy:

```sh
docker compose up -d --build
```
