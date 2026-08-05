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
   images unless `--remove-volumes` / `--remove-images` are given). The combined stack also publishes the
   **configuration wizard** at `config-builder.${BASE_DOMAIN}` (the
   `ghcr.io/fastbean-au/hippocampus-config-wizard` image, source `cmd/config-wizard` in the
   hippocampus repo) — a tool rather than a demo: a static page that builds a `config.json` and its
   deployment artefacts entirely in the visitor's browser, so it needs no auth, no store, and no
   network access beyond the front Caddy reaching it by name.

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

# Recreate ONLY the front Caddy (+ the two generators that require it) to apply a change to the
# `caddy` service OR to caddy/Caddyfile.combined, WITHOUT bouncing the backing services. A plain
# `up -d caddy` recreates Caddy's whole depends_on tree (a full-stack outage); this scopes it with
# `up --no-deps` and never passes --force-recreate (see below). Brief apex blip — Caddy owns
# :80/:443, so no zero-downtime swap is possible. This is also the ONLY reliable way to apply a
# Caddyfile change on a host that updates by `git pull` (see the reload caveat below).
sudo ./showcase/deploy-caddy.sh

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

### podman-compose 1.0.6 traps (read before touching a deploy script)

Both of these bite silently — they report success while doing the wrong thing. See
`podman_compose.py` ~2053-2069; the deploy scripts route around them and verify the result.

- **Never pass `--force-recreate`.** Its handler is
  `if args.force_recreate or len(diff_hashes): compose.commands["down"](...)` — a **full-project
  `down`** that ignores `--no-deps` and the named service alike. Passing it to limit a recreate does
  the exact opposite and takes the whole stack down. Remove the one container you want replaced by
  hand, then `up -d --no-deps <service>` into the free name. The same `down` also fires whenever a
  container's stored config-hash differs from the compose file's current hash — i.e. after **any**
  edit to `compose.showcase-combined.yaml` — so a targeted `up` can still bounce unrelated services;
  `deploy-caddy.sh` restarts whatever it finds stopped rather than assuming containment.
- **A name clash degrades to `podman start`.** When `podman run` fails because the container name is
  taken, compose silently runs `podman start <name>` instead — reviving the **old** container, with
  its old image and its old bind mounts, while the log output still reads like a recreate. Always
  free the name first, and verify the container id actually changed afterwards.

### The Caddyfile bind mount goes stale on `git pull`

`caddy/Caddyfile.combined` is bind-mounted **as a file**, so the mount is pinned to that file's
inode when the container starts. The downtime-free reload:

```sh
sudo podman exec showcase_caddy_1 caddy reload --config /etc/caddy/Caddyfile
```

only picks up an edit that **kept the same inode** (`cat new > Caddyfile`). Anything that replaces
the file — `git pull`, `sed -i`, `mv`, most editors' write-new-then-rename — leaves the container
reading the **old** inode: the host file is new, the container's is not, and `caddy reload` logs
`"config is unchanged"` and exits **0**. Since this deployment updates by `git pull`, reload is
effectively unusable for Caddyfile changes there — use `sudo ./showcase/deploy-caddy.sh`, which
recreates the container and so re-resolves the mount. The script's `assert_caddyfile_fresh` compares
the mounted copy's checksum against the host's and fails the run if they differ.

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
