# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

The static landing page for the Hippocampus demo — plain `index.html` + `assets/` (CSS, JS,
favicon). **There is no build step for the site itself**; the files are served as-is. The only
build is the Docker image that packages them into Caddy.

## Commands

```sh
# Format + lint (prettier, markdownlint, git-diff-check, trufflehog via Trunk)
trunk fmt <files...>
trunk check                      # whole repo
trunk check <files...>           # specific files

# Build + deploy (requires Docker; the showcase stack must be up first — see below)
docker compose up -d --build

# Local preview without Docker (serves the repo root on :8000)
python3 -m http.server 8000
```

There is no test suite.

## Deployment architecture (the important part)

This site does **not** run its own public web server. It plugs into the separate
[`hippocampus`](https://github.com/fastbean-au/hippocampus) showcase stack, whose front Caddy
already owns `:80/:443` and terminates TLS. The integration is deliberately **dependency-inverted**:

- The **showcase does not depend on this repo.** Its `Caddyfile.combined` has a generic apex
  block, `reverse_proxy {$SITE_UPSTREAM:hippocampus-site:80}`, and names its shared network
  `hippocampus-shared`. Both are conventions it defines itself. Run the showcase without this
  repo and the apex simply 502s while every subdomain keeps working.
- **This repo depends on the showcase**, which is the correct direction. `docker-compose.yaml`
  runs the site as its own project (`hippocampus-site`) that joins `hippocampus-shared` as an
  **external** network. The front Caddy reaches it by service name over Docker DNS — exactly how
  the `book` / `logs` / `auth` / `grafana` services are proxied.

Consequence: the site can be deployed, restarted, or updated independently of the running demos.
The showcase-side hooks live in the sibling `../hippocampus` repo (`docker/caddy/Caddyfile.combined`
and `docker/docker-compose.showcase-combined.yaml`); changes here that touch the integration must
stay consistent with those two conventions (the upstream name and the network name).

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
