# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

This repo holds two things for the Hippocampus demo:

1. **The static landing page** — plain `index.html` + `assets/` (CSS, JS, favicon) at the repo root,
   served by Caddy. **There is no build step for the site itself**; the files are served as-is. The
   only build is the Docker image that packages them into Caddy.
2. **The hosted showcase** — the runnable demo stacks under [`showcase/`](showcase/) (book / logs /
   combined / lite compose files plus their configs, Caddyfiles, Keycloak realm, and Postgres init)
   and their documentation under [`docs/`](docs/) ([`docs/showcase.md`](docs/showcase.md) is the
   entry point, with per-cloud runbooks [`docs/showcase-gcp.md`](docs/showcase-gcp.md) /
   [`docs/showcase-oci.md`](docs/showcase-oci.md)). The stacks pull the published
   `ghcr.io/fastbean-au/hippocampus:latest` image — the Hippocampus source lives in the separate
   [`hippocampus`](https://github.com/fastbean-au/hippocampus) repo, not here.

## Commands

```sh
# Format + lint (prettier, markdownlint, git-diff-check, trufflehog via Trunk)
trunk fmt <files...>
trunk check                      # whole repo
trunk check <files...>           # specific files

# Bring up the showcase stack (creates the `hippocampus-shared` network the site joins)
docker compose -f showcase/docker-compose.showcase-combined.yaml up -d

# Build + deploy the landing site (requires Docker; the showcase stack must be up first — see below)
docker compose up -d --build

# Local preview without Docker (serves the repo root on :8000)
python3 -m http.server 8000
```

There is no test suite.

## Deployment architecture (the important part)

The landing site does **not** run its own public web server. It plugs into the showcase stack (now
also in this repo, under `showcase/`), whose front Caddy already owns `:80/:443` and terminates TLS.
The two are **separate compose projects** kept deliberately **dependency-inverted**, so the site's
lifecycle stays independent of the running demos:

- The **showcase does not depend on the site.** Its `showcase/caddy/Caddyfile.combined` has a
  generic apex block, `reverse_proxy {$SITE_UPSTREAM:hippocampus-site:80}`, and names its shared
  network `hippocampus-shared`. Both are conventions it defines itself. Run the showcase without
  the site project up and the apex simply 502s while every subdomain keeps working.
- **The site project depends on the showcase**, which is the correct direction. The root
  `docker-compose.yaml` runs the site as its own project (`hippocampus-site`) that joins
  `hippocampus-shared` as an **external** network. The front Caddy reaches it by service name over
  Docker DNS — exactly how the `book` / `logs` / `auth` / `grafana` services are proxied.

Consequence: the site can be deployed, restarted, or updated independently of the running demos.
The showcase-side hooks are `showcase/caddy/Caddyfile.combined` and
`showcase/docker-compose.showcase-combined.yaml`; changes that touch the integration must keep the
two conventions (the upstream name `hippocampus-site` and the network name `hippocampus-shared`)
consistent across the root `docker-compose.yaml` and those two files.

`Caddyfile` (this repo) is the **container's internal** config — plain HTTP on `:80`, no TLS.
`Dockerfile` bakes the static files into `caddy:2`, so the image is self-contained with no host
paths. Updating copy means editing the files and re-running `docker compose up -d --build`.

## Constraints when editing

- **The Content-Security-Policy in `Caddyfile` is coupled to what the markup loads.** It currently
  assumes same-origin CSS/JS plus inline SVG only (`style-src` includes `'unsafe-inline'` solely
  for the one inline `style` attribute on the hidden SVG symbol sheet). Adding any external
  resource, inline `<script>`, or `data:`/remote image requires updating the CSP to match, or the
  browser will silently block it.
- `assets/theme.js` is loaded **non-deferred in `<head>` on purpose** so the light/dark theme is
  applied before first paint (no flash). It reads a saved choice from `localStorage` (`hc-theme`),
  else the OS preference, and only tracks OS changes while the user has made no explicit choice.
- Assets are **not content-hashed**, so the `Cache-Control` header uses `must-revalidate` rather
  than long immutable caching — keep it that way unless fingerprinting is introduced.
