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

## Which deployment option?

There are four compose stacks under [`showcase/`](showcase/). They are alternatives, not layers —
pick one per host. **[`compose.showcase-combined.yaml`](showcase/compose.showcase-combined.yaml) is
the default choice** and is what the public demo runs; the others exist for narrower cases.

| Stack                                                                                      | Use it when                                                                            | You get                                                                                                                                                                                                   | You give up                                                                          | Host budget                                                                                   |
| ------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------- |
| **combined** — [`compose.showcase-combined.yaml`](showcase/compose.showcase-combined.yaml) | You want the whole showcase on one domain, running itself — the public-demo shape      | All three examples, **self-driving** (the generators and the Bluesky bridge run as containers), one shared Keycloak/Grafana/Postgres/OpenSearch, plus the landing page at the apex and the config builder | Security isolation — one realm means a token from either console works on both       | 4 vCPU / 16 GiB (`e2-standard-4`, OCI 4 OCPU / 24 GiB); apex + 6 subdomains in DNS            |
| **book** — [`compose.showcase-book.yaml`](showcase/compose.showcase-book.yaml)             | You only want the prose example, or want the two examples isolated on separate domains | _Great Expectations_ reloaded/summarised/decaying, and the only stack with **semantic + hybrid search** (`ollama` sidecar)                                                                                | The logs example; you run the generator yourself; no landing page, no config builder | ~5 GiB; `DOMAIN` + `auth.` + `grafana.`                                                       |
| **logs** — [`compose.showcase-logs.yaml`](showcase/compose.showcase-logs.yaml)             | You only want the trickle-and-eviction example, or its own isolated domain             | A continuous log trickle reaped by consolidation and capacity eviction                                                                                                                                    | The book example and semantic search; you run the generator yourself                 | ~5 GiB; `DOMAIN` + `auth.` + `grafana.`                                                       |
| **lite** — [`compose.showcase-lite.yaml`](showcase/compose.showcase-lite.yaml)             | The VM is tiny or free-tier, and one console is enough                                 | Two containers — hippocampus on SQLite + Caddy — with hosted **Auth0** instead of a self-hosted JVM                                                                                                       | The content-search tab (no OpenSearch) and the Grafana dashboards (no telemetry)     | 0.25 vCPU / 1 GiB (`e2-micro`, OCI `E2.1.Micro`); one A record. The quarter core is the limit |

Running **book and logs side by side** is the isolated alternative to combined: two domains, two of
everything (each ships its own Caddy on `:80`/`:443`, so they need separate hosts or separate IPs),
and no shared realm. Combined exists because that is two of everything for one demo.

**No public domain?** Automatic HTTPS needs a real domain, so none of the Caddy stacks come up as-is
on a laptop — see [local evaluation](docs/showcase.md#local-evaluation-without-a-public-domain). To
preview just this landing page, no container engine required:

```sh
python3 -m http.server 8000
```

### Standing a host up, and day-2 changes

| Do this                                                          | When                                                                                                                                                                                                                                                                                  |
| ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`showcase/install-ubuntu.sh`](showcase/install-ubuntu.sh)       | First install on a fresh **Ubuntu 24.04** host. Installs Podman, records the domain, and registers a systemd unit so the combined stack survives reboots. Re-run it later **only** to change the base domain, the gen secret, or the Keycloak realm — it is what re-imports the realm |
| `podman compose -f <file> up -d --build`                         | Any other host or stack variant, or when you don't want boot persistence                                                                                                                                                                                                              |
| [`showcase/deploy-site.sh`](showcase/deploy-site.sh)             | Only `index.html` / `assets/` changed — see [Update the site](#update-the-site)                                                                                                                                                                                                       |
| [`showcase/deploy-caddy.sh`](showcase/deploy-caddy.sh)           | The `caddy` service or `caddy/Caddyfile.combined` changed. On a host that updates by `git pull` this is the only reliable path: the Caddyfile is bind-mounted by inode, so `caddy reload` reports success while still reading the old file                                            |
| [`showcase/deploy-generators.sh`](showcase/deploy-generators.sh) | A new `hippocampus-gen-{book,logs}` image was published and you want the demo load running it. Nothing else pulls it — neither `up -d` nor a unit restart — so this is the only path that ships a generator change                                                                    |
| `showcase/deploy-generators.sh bluesky`                          | A Hippocampus release changed the Bluesky demo's service image, its bridge image, or the bridge's flags in the compose file. The same script and the same reasoning; it recreates the service before the bridge, since a bridge that cannot dial exits. `bluesky-bridge` for the bridge alone |
| [`showcase/uninstall-ubuntu.sh`](showcase/uninstall-ubuntu.sh)   | Tearing it down. Keeps volumes and images unless `--remove-volumes` / `--remove-images`                                                                                                                                                                                               |

The full walkthroughs live in [docs/showcase.md](docs/showcase.md); VM provisioning is per-cloud in
the [GCP](docs/showcase-gcp.md) and [OCI](docs/showcase-oci.md) runbooks.

## How it's served

The site runs as the `hippocampus-site` service on the showcase's `hippocampus-shared` network.
The showcase's front Caddy owns `:80/:443`, terminates TLS, and reverse-proxies the apex domain to
this container by service name — exactly how it proxies the `book` / `logs` / `auth` / `grafana` /
`config-builder` subdomains.

```text
┌─────────────── hippocampus showcase (owns :80/:443) ───────────────┐
│  Caddy ──reverse_proxy──▶ book / logs / auth / grafana             │
│    └────reverse_proxy────▶ config-builder:8091 (the config wizard)  │
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
