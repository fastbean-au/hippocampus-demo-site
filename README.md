# hippocampus-demo-site

Landing page for the [Hippocampus](https://github.com/fastbean-au/hippocampus) demo — a static
site (`index.html` + `assets/`) served by Caddy.

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
