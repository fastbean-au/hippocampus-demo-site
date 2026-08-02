# hippocampus-demo-site

The public demo for [Hippocampus](https://github.com/fastbean-au/hippocampus). This repo holds two
pieces:

- **The landing page** — a static site (`index.html` + `assets/`) served by Caddy (this README).
- **The hosted showcase** — the runnable demo stacks under [`showcase/`](showcase/) and their
  documentation under [`docs/`](docs/). Start at **[docs/showcase.md](docs/showcase.md)** (with
  per-cloud runbooks [GCP](docs/showcase-gcp.md) / [OCI](docs/showcase-oci.md)). The stacks pull the
  published `ghcr.io/fastbean-au/hippocampus` image; the service source is the separate
  [`hippocampus`](https://github.com/fastbean-au/hippocampus) repo.

The landing page is a service in the combined showcase stack, so one command brings up the demos
and the site together (the site is built from this repo's root `Containerfile`):

```sh
podman compose -f showcase/compose.showcase-combined.yaml up -d --build
```

## How it's served

The site runs as the `hippocampus-site` service on the showcase's `hippocampus-shared` network.
The showcase's front Caddy owns `:80/:443`, terminates TLS, and reverse-proxies the apex domain to
this container by service name — exactly how it proxies the `book` / `logs` / `auth` / `grafana`
subdomains.

```text
┌─────────────── hippocampus showcase (owns :80/:443) ───────────────┐
│  Caddy ──reverse_proxy──▶ book / logs / auth / grafana             │
│    └────reverse_proxy────▶ hippocampus-site:80                     │
│                              (over the `hippocampus-shared` network)│
└────────────────────────────────────────────────────────────────────┘
```

The site rides on the **combined** stack only; the `book` / `logs` / `lite` variants have no apex
block. It is live at the showcase's apex domain (`https://${BASE_DOMAIN}/`), with TLS handled by
the front Caddy.

## Update the site

Edit `index.html` / `assets/`, then rebuild and redeploy just the site (the rest of the stack keeps
running, and the apex stays up throughout):

```sh
sudo ./showcase/deploy-site.sh
```

`deploy-site.sh` rebuilds the site image and swaps the container in behind the front Caddy with no
apex downtime. Do **not** reach for `podman compose up -d --build hippocampus-site` instead: on this
stack's podman-compose (1.0.6) it can't recreate the running container and silently restarts the old
one, so the rebuilt image never goes live.
