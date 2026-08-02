# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

This repo holds two things for the Hippocampus demo:

1. **The static landing page** — plain `index.html` + `assets/` (CSS, JS, favicon, `og-image.png`
   for social/link previews plus its `og-image.svg` source) at the repo root, alongside `robots.txt`
   and `sitemap.xml` for SEO. All served by Caddy. **There is no build step for the site itself**;
   the files are served as-is. The only build is the container image that packages them into Caddy.
   Each of these files is `COPY`-ed explicitly in `Containerfile`, so a **new top-level static file
   must be added there** or it won't ship in the image. `Containerfile` also stamps the sitemap's
   `<lastmod>` with the image build date at build time, so that value is not hand-maintained — the
   date checked into `sitemap.xml` is only a fallback for local, no-build previews.
2. **The hosted showcase** — the runnable demo stacks under [`showcase/`](showcase/) (book / logs /
   combined / lite compose files plus their configs, Caddyfiles, Keycloak realm, and Postgres init)
   and their documentation under [`docs/`](docs/) ([`docs/showcase.md`](docs/showcase.md) is the
   entry point, with per-cloud runbooks [`docs/showcase-gcp.md`](docs/showcase-gcp.md) /
   [`docs/showcase-oci.md`](docs/showcase-oci.md)). The stacks pull the published
   `ghcr.io/fastbean-au/hippocampus:latest` image — the Hippocampus source lives in the separate
   [`hippocampus`](https://github.com/fastbean-au/hippocampus) repo, not here. The **combined** stack
   is self-driving: it runs the data generators as containers
   (`ghcr.io/fastbean-au/hippocampus-gen-{book,logs}:latest`, from the separate
   [`hippocampus-gen`](https://github.com/fastbean-au/hippocampus-gen) repo), so a single `up -d`
   brings up the load too. All images (servers, sidecars, generators) publish multi-arch
   (amd64 + arm64). The realm is **read-only for visitors** (one
   `demo`/`demo` login); the generators write as the `hippocampus-gen` service account (`admin`).
   [`showcase/install-ubuntu.sh`](showcase/install-ubuntu.sh) stands the combined stack up on a fresh
   Ubuntu 24.04 host with a boot-persistent systemd unit (base domain + ACME email as options);
   [`showcase/uninstall-ubuntu.sh`](showcase/uninstall-ubuntu.sh) reverses it (keeping volumes and
   images unless `--remove-volumes` / `--remove-images` are given).

## Commands

```sh
# Format + lint (prettier, markdownlint, git-diff-check, trufflehog via Trunk)
trunk fmt <files...>
trunk check                      # whole repo
trunk check <files...>           # specific files

# Bring up the whole combined showcase — demos AND the landing site — in one project (the site is
# built from the repo-root Containerfile as the `hippocampus-site` service; requires a container engine)
podman compose -f showcase/compose.showcase-combined.yaml up -d --build

# Rebuild + redeploy just the site after editing index.html / assets (leaves the rest of the stack
# running, no apex downtime). Do NOT use `up -d --build hippocampus-site` for this: podman-compose
# 1.0.6 can't recreate the existing container in place and silently restarts the OLD one, so the
# rebuilt image never goes live. On a live host run this as root; it also loads the unit's env file.
sudo ./showcase/deploy-site.sh

# Local preview without a container engine (serves the repo root on :8000)
python3 -m http.server 8000
```

There is no test suite.

## Deployment architecture (the important part)

The landing site does **not** run its own public web server. It rides on the combined showcase
stack, whose front Caddy owns `:80/:443` and terminates TLS. The site is now a **service in that
stack** (`hippocampus-site` in `showcase/compose.showcase-combined.yaml`), so a single
`podman compose -f showcase/compose.showcase-combined.yaml up -d --build` brings up the demos and
the site together:

- The site service is **built from the repo root** (`build.context: ..`,
  `dockerfile: Containerfile`) and baked into a self-contained `caddy:2` image, so it carries no
  host-path or cross-repo dependencies. It joins the `shared` network (`hippocampus-shared`) and
  the front Caddy reaches it by service name over container DNS — exactly how the
  `book` / `logs` / `auth` / `grafana` services are proxied.
- The **apex block** in `showcase/caddy/Caddyfile.combined` is
  `reverse_proxy {$SITE_UPSTREAM:hippocampus-site:80}`. `SITE_UPSTREAM` still lets you point the
  apex elsewhere; drop the `hippocampus-site` service and the apex simply 502s while every subdomain
  keeps working.

The integration lives in exactly two files —
`showcase/compose.showcase-combined.yaml` (the `hippocampus-site` service + the `shared` network)
and `showcase/caddy/Caddyfile.combined` (the apex block) — which must agree on the service name
`hippocampus-site` and the network name `hippocampus-shared`. The site rides **only** on the
combined stack; the `book` / `logs` / `lite` variants have no apex block or shared network.

`Caddyfile` (this repo, at the root) is the **site container's internal** config — plain HTTP on
`:80`, no TLS. `Containerfile` (also at the root) bakes the static files into `caddy:2`. Updating
copy means editing `index.html` / `assets/` and re-running `showcase/deploy-site.sh`, which rebuilds
the site image and swaps the container in behind the front Caddy with no apex downtime (it brings up
an overlapping second backend on the `hippocampus-site` network alias, removes the old container —
possible only because caddy no longer `depends_on` the site — then drops the temp backend). A plain
`podman compose up -d --build hippocampus-site` does **not** work on this stack's podman-compose
(1.0.6): with no `--replace` it hits the existing container's name and silently restarts the old one.

## Constraints when editing

- **The Content-Security-Policy in `Caddyfile` is coupled to what the markup loads.** It currently
  assumes same-origin CSS/JS plus inline SVG only (`style-src` includes `'unsafe-inline'` solely
  for the one inline `style` attribute on the hidden SVG symbol sheet). Adding any external
  resource, inline `<script>`, or `data:`/remote image requires updating the CSP to match, or the
  browser will silently block it. The one exception in the markup is the
  `<script type="application/ld+json">` structured-data block: it is a non-executable data block,
  not a script, so `script-src 'self'` does not block it and no CSP change was needed for it.
- `assets/theme.js` is loaded **non-deferred in `<head>` on purpose** so the light/dark theme is
  applied before first paint (no flash). It reads a saved choice from `localStorage` (`hc-theme`),
  else the OS preference, and only tracks OS changes while the user has made no explicit choice.
- Assets are **not content-hashed**, so the `Cache-Control` header uses `must-revalidate` rather
  than long immutable caching — keep it that way unless fingerprinting is introduced.
