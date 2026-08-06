# Hosted showcase

A publicly reachable demonstration of Hippocampus — the web console, OpenSearch content search
(keyword **and semantic**), and the Grafana/OTEL telemetry stack — with the UI protected by an
identity provider. It runs as **two
independent stacks**, each driven by the [`hippocampus-gen`](https://github.com/fastbean-au/hippocampus-gen)
generators:

| Stack    | Shape                                                                 | Generator                                                                   |
| -------- | --------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| **book** | _Great Expectations_ reloaded daily, summarised, decaying             | `cmd/book --loop --period 24h --reset --live --pace-window <w> --summarise` |
| **logs** | a continuous log trickle, reaped by consolidation + capacity eviction | `cmd/logs --live --rate <n>`                                                |

The service configs are [`showcase/config.showcase-book.json`](../showcase/config.showcase-book.json) and
[`showcase/config.showcase-logs.json`](../showcase/config.showcase-logs.json); the compose stacks are
[`showcase/compose.showcase-book.yaml`](../showcase/compose.showcase-book.yaml) and
[`…-logs.yaml`](../showcase/compose.showcase-logs.yaml). This document covers the
identity-provider setup and how to run the stacks; the per-cloud VM provisioning is a separate
runbook — [GCP](showcase-gcp.md) or [OCI](showcase-oci.md).

> **Tight on resources?** There is also a **lite** single stack that trades OpenSearch content search
> and the Grafana/OTEL telemetry for a footprint that fits a 0.25 vCPU / 1 GiB VM — see
> [A lite single stack](#a-lite-single-stack-e2-micro) below.

## What the configs assume

Both configs use `auth.method: idp` and a **compressed decay clock**
(`consolidation.unitsOfAgeInDays: 0.002`, ≈ one age-unit per three minutes) so forgetting,
summarisation, and (for logs) capacity eviction all play out within a session rather than over real
days. They differ where the two shapes differ:

- **book** enables summarisation (`summarisationMinMemories: 20`, `summarisationMinAgeInDays: 0`) and
  leaves capacity uncapped — the store is small and purged each day.
- **logs** disables summarisation and caps the store (`capacityBytes`/`capacityMemories`) so eviction
  keeps the ever-growing trickle bounded.
- **book** also enables **semantic search** (`ollama.embedding`), so the console's search tab offers
  keyword, semantic, and hybrid modes. See [Semantic search](#semantic-search) below for why it
  rides with the book example and not the logs one.

Both enable OpenSearch and ship metrics/traces to `otel-lgtm` by default.

## Semantic search

The book stack runs an extra `ollama` service holding a small embedding model. Hippocampus turns
each memory body into a vector through it and stores that in the OpenSearch k-NN index, so the
console's search tab can find a passage by **meaning** as well as by its words — searching the book
for "a sudden change in fortune" surfaces passages that never use those words. The console reads the
available modes from `WhoAmI` and shows a **Mode** picker (keyword / semantic / hybrid, defaulting
to hybrid) only where the deployment can serve more than one.

It is wired to the **book** service only, for two reasons that happen to agree:

- Semantic search is most worth demonstrating on prose, where paraphrase is the whole point. Log
  lines are terse and structured, and keyword search is genuinely the better tool for them.
- Embedding runs on the **write path**, so putting it in front of the logs generator's continuous
  trickle would spend the VM's shared CPU all day for the less interesting demo. The book generator
  writes in a burst once every 24 hours and is then quiet, which suits it far better.

The model is **`all-minilm`** (~45 MB, 384 dimensions) rather than the more usual
`nomic-embed-text` (~275 MB, 768) — a deliberate footprint choice for a demo VM already running
Postgres, OpenSearch, Keycloak and Grafana. Override it with `EMBEDDING_MODEL`, but note that
changing the model means changing `ollama.embedding.dimensions` in the config to match **and**
rebuilding the index (`--backfill-search --reindex`): a k-NN index fixes its vector width at
creation.

The `ollama` service pulls its model on first start, and its healthcheck gates on the **model**
being present rather than the port being open — so `hippocampus` waits for it and no memory is
stored before it can be embedded. First boot therefore takes a minute or two longer than before,
and the model persists in a volume across restarts.

Two operational consequences worth knowing:

- The book config raises `opensearch.reconcileIntervalSeconds` to 3600. The reconciliation sweep
  re-embeds every memory it visits (it must, or it would replace documents with vectorless copies
  and silently strip them from semantic search), which makes it far more expensive than the plain
  re-index it used to be.
- A `--reset` book cycle re-embeds the whole book. That is the burst the sizing note accounts for.

### The one issuer rule

`auth.issuer` (which the **service** uses to discover the JWKS and which it enforces against each
token's `iss`) and `auth.ui.issuer` (which the **browser** runs OIDC discovery against) **must be the
same canonical URL** — the one the identity provider stamps into `iss`. A split-horizon setup (the
browser using a public URL while the service dials an internal one) makes the `iss` claim mismatch
`auth.issuer` and every token is rejected. On a deployed VM this is the single public provider URL
that both the browser and the service containers reach. Override both per deployment:

```sh
HIPPOCAMPUS_AUTH_ISSUER=https://auth.example/realms/hippocampus
HIPPOCAMPUS_AUTH_UI_ISSUER=https://auth.example/realms/hippocampus
```

(All config keys are overridable as `HIPPOCAMPUS_<KEY>` with `.`→`_`.)

## Keycloak (self-hosted)

A ready-to-import realm lives at
[`showcase/keycloak/realm-hippocampus.json`](../showcase/keycloak/realm-hippocampus.json). It defines:

- realm roles `reader` / `writer` / `admin` (mapped straight onto Hippocampus's tiers);
- a **public SPA client** `hippocampus-console` (Authorisation Code + PKCE, no secret) for the `/ui`
  console — set its `redirectUris` to your console URLs (the file ships localhost plus
  `https://book.hippocampus.example/ui` / `https://logs.hippocampus.example/ui` placeholders);
- a **confidential client** `hippocampus-gen` (client-credentials, `serviceAccountsEnabled`) with the
  `admin` role, for the generators — **change its `secret`** before deploying;
- a single demo user `demo` (password `demo`) so visitors who sign in to a console can
  **browse but not mutate** — the showcase is read-only for people, and all writing is done by the
  `hippocampus-gen` service account. The `writer`/`admin` roles are still defined (the generator uses
  `admin`); add `writer-demo`/`admin-demo` users back if you want interactive write access.

Keycloak publishes roles under the nested `realm_access.roles` claim, which is why the configs set
`auth.roleClaim: "realm_access.roles"` (resolved via the dotted-path lookup — see
[Authorisation](https://github.com/fastbean-au/hippocampus/blob/main/docs/configuration.md#authorisation)). Keycloak's access token has no `aud` for these
clients, so `auth.audience` is left empty (unenforced).

Run it (dev mode, importing the realm):

```sh
podman run -d --name keycloak -p 8092:8080 \
  -e KEYCLOAK_ADMIN=admin -e KEYCLOAK_ADMIN_PASSWORD=admin -e KC_HOSTNAME_STRICT=false \
  -v "$PWD/showcase/keycloak/realm-hippocampus.json:/opt/keycloak/data/import/realm.json:ro,Z" \
  quay.io/keycloak/keycloak:26.0 start-dev --import-realm
```

Then point a stack at it (`issuer` = `http://localhost:8092/realms/hippocampus`). A machine token for
the generators:

```sh
curl -s -X POST http://localhost:8092/realms/hippocampus/protocol/openid-connect/token \
  -d grant_type=client_credentials -d client_id=hippocampus-gen \
  -d client_secret=<secret> | jq -r .access_token
```

or let the generator fetch it itself with `--oidc-issuer/--oidc-client-id/--oidc-client-secret` (see
the generator's [Authentication](https://github.com/fastbean-au/hippocampus-gen#authentication)).

## Auth0 (SaaS)

Auth0 is wired through the same `auth.method: idp` path; only the config values differ. In the Auth0
dashboard:

1. **APIs → Create API.** The **Identifier** you choose is the **audience**. Enable RS256. This is
   what makes Auth0 mint a _JWT_ access token — without an audience it returns an opaque token that
   cannot be verified.
2. **Applications → Create → Single Page Application** for the console. Add your console URL to
   _Allowed Callback URLs_ and _Allowed Web Origins_. PKCE is automatic for SPAs.
3. **Applications → Create → Machine to Machine**, authorise it for the API above, for the
   generators (client-credentials). Grant it the permission/role your `admin` tier maps to.
4. **Add roles to the token.** Auth0 does not put roles in a standard claim; add a Login/Client-
   Credentials **Action** that sets a namespaced claim, e.g.
   `api.accessToken.setCustomClaim("https://hippocampus.example/roles", ["admin"])` (or from the
   user's assigned roles). The namespace must be a URI Auth0 won't strip.

Then the config (via env overrides on the showcase config):

```sh
HIPPOCAMPUS_AUTH_ISSUER=https://YOUR_TENANT.us.auth0.com/
HIPPOCAMPUS_AUTH_UI_ISSUER=https://YOUR_TENANT.us.auth0.com/
HIPPOCAMPUS_AUTH_AUDIENCE=https://api.hippocampus.example        # the API Identifier
HIPPOCAMPUS_AUTH_UI_AUDIENCE=https://api.hippocampus.example     # so the browser gets a JWT
HIPPOCAMPUS_AUTH_UI_CLIENTID=<spa-client-id>
HIPPOCAMPUS_AUTH_ROLECLAIM=https://hippocampus.example/roles     # matched literally (top-level)
```

Because the role claim is a URI-shaped **top-level** key, the resolver matches it literally; the
nested dotted-path lookup is what makes Keycloak's `realm_access.roles` work. One resolver, both
providers — see [Authorisation](https://github.com/fastbean-au/hippocampus/blob/main/docs/configuration.md#authorisation).

The generators authenticate to Auth0 with the same flags plus `--oidc-audience <API Identifier>`.

## Running the stacks

Each stack is a self-contained compose project: hippocampus (Postgres + OpenSearch), a Keycloak IdP,
and the otel-lgtm telemetry stack, all behind **Caddy**, which terminates TLS (automatic Let's
Encrypt) and routes by hostname. The two stacks are independent and run side by side on one host.

### The split-issuer fix

`auth.issuer` must be the one URL both the browser and the service reach (see [the one issuer
rule](#the-one-issuer-rule)). Caddy provides it: it joins the compose network with the public
hostnames (`${DOMAIN}`, `auth.${DOMAIN}`, `grafana.${DOMAIN}`) as **network aliases**, so the
hippocampus container resolves `auth.${DOMAIN}` to Caddy and reaches Keycloak at exactly the URL the
browser uses via public DNS. The compose sets `HIPPOCAMPUS_AUTH_ISSUER`/`_UI_ISSUER` and Keycloak's
`KC_HOSTNAME` to that same `https://auth.${DOMAIN}` value.

> Do **not** substitute a `*.localhost` hostname here: libc and Go resolve the `.localhost` TLD to
> loopback (RFC 6761) and never consult the compose DNS, so the container would dial itself instead
> of Caddy. Use a real domain (below), or `/etc/hosts` aliases for a non-`.localhost` name locally.

### Deploy (public domain)

Point DNS A/AAAA records for `${DOMAIN}`, `auth.${DOMAIN}`, and `grafana.${DOMAIN}` at the VM, open
ports 80 and 443, then before first run **change the two demo secrets**: Keycloak's admin password
and the `hippocampus-gen` client `secret` in
[`showcase/keycloak/realm-hippocampus.json`](../showcase/keycloak/realm-hippocampus.json) (the realm's
console `redirectUris` already list `https://book.hippocampus.example/ui` /
`https://logs.hippocampus.example/ui` — change these to your domains too).

> **The realm is imported only on first boot.** Keycloak runs `start-dev --import-realm`, which
> imports [`realm-hippocampus.json`](../showcase/keycloak/realm-hippocampus.json) only into an **empty**
> data volume — editing the file after the volume exists has no effect. If you change `redirectUris`
> (or any realm setting) on an already-running stack, drop just the Keycloak volume and bring it back
> up so it re-imports: `podman compose -f <file> down`, then remove that stack's Keycloak volume by
> name (`book-keycloak-data` / `logs-keycloak-data` / `combined-keycloak-data`, prefixed by the
> compose project — find it with `podman volume ls`) so Postgres/OpenSearch survive, then
> `podman compose -f <file> up -d`.

```sh
BOOK_DOMAIN=book.example ACME_EMAIL=you@example.com \
  podman compose -f showcase/compose.showcase-book.yaml up --build -d

LOGS_DOMAIN=logs.example ACME_EMAIL=you@example.com \
  podman compose -f showcase/compose.showcase-logs.yaml up --build -d
```

Sign in to `https://book.example/ui` as `demo` (password `demo`) and browse the read-only
console.

### Drive it with the generators

The generators ship as published container images —
`ghcr.io/fastbean-au/hippocampus-gen-{book,logs,random}:latest`, built by the
[`hippocampus-gen`](https://github.com/fastbean-au/hippocampus-gen) repo's CI. The
[combined stack](#both-examples-on-one-domain-a-single-merged-stack) runs the `book` and `logs`
images **as services**, so it is self-driving with no extra step (see below). For the standalone
`book`/`logs` stacks above, run the matching image against the published gRPC port, authenticating to
Keycloak as the `hippocampus-gen` client (admin tier — the book path calls `Purge`/`Sleep`):

```sh
# book: reload + summarise every 24h, spread across 2h, ageing live
podman run --rm ghcr.io/fastbean-au/hippocampus-gen-book:latest -s <vm>:50051 \
  --loop --period 24h --reset --pace-window 2h --live --summarize \
  --oidc-issuer https://auth.book.example/realms/hippocampus \
  --oidc-client-id hippocampus-gen --oidc-client-secret "$GEN_SECRET"

# logs: a steady trickle the sleep cycle keeps reaping
podman run --rm ghcr.io/fastbean-au/hippocampus-gen-logs:latest -s <vm>:50052 --live --rate 120 \
  --oidc-issuer https://auth.logs.example/realms/hippocampus \
  --oidc-client-id hippocampus-gen --oidc-client-secret "$GEN_SECRET"
```

The book generator's `--reset` purges the store at the start of every cycle, and its first cycle runs
immediately — so a fresh start clears any existing events and memories before loading.

### Both examples on one domain (a single merged stack)

The book and logs compose files above each ship their _own_ Caddy binding `:80`/`:443` and their own
Keycloak on an `auth.` subdomain — two of everything, across two domains. When you want **both
examples under one parent domain on one host**, the merged stack
[`showcase/compose.showcase-combined.yaml`](../showcase/compose.showcase-combined.yaml)
(Caddyfile [`showcase/caddy/Caddyfile.combined`](../showcase/caddy/Caddyfile.combined)) folds them into a
single compose project: **one Caddy** (two Caddys cannot share the host ports), **one shared
Keycloak**, **one shared Grafana**, and **one shared pair of data stores** — a single Postgres (a
database per example) and a single OpenSearch (an index per example), so the merged host runs one of
each rather than a pair. Everything hangs off a single `BASE_DOMAIN`:

```sh
BASE_DOMAIN=hippocampus.example ACME_EMAIL=you@example.com \
  podman compose -f showcase/compose.showcase-combined.yaml up --build -d
```

That serves five subdomains of the one domain — point A/AAAA records for each (or a single
`*.${BASE_DOMAIN}` wildcard) at the host:

| Subdomain                       | Serves                                                      |
| ------------------------------- | ----------------------------------------------------------- |
| `book.${BASE_DOMAIN}`           | the book console (`/ui`), gRPC on `:50051`                  |
| `logs.${BASE_DOMAIN}`           | the logs console (`/ui`), gRPC on `:50052`                  |
| `auth.${BASE_DOMAIN}`           | Keycloak — **shared**, one realm serving both consoles      |
| `grafana.${BASE_DOMAIN}`        | Grafana — **shared**, both services' telemetry in one place |
| `config-builder.${BASE_DOMAIN}` | the configuration and deployment wizard (see below)         |

Each of those is a whole application with its own navigation, so the landing page opens them in a new
tab and the visitor's original tab stays on the site. Grafana additionally carries its own way back:
`install-ubuntu.sh` renders `observability/hippocampus-dashboard.generated.json` (mounted via
`GRAFANA_DASHBOARD_FILE`) with a dashboard link to `https://${BASE_DOMAIN}`, so a visitor who arrives
straight at `grafana.${BASE_DOMAIN}` — which opens on that dashboard, Grafana's configured home — has
a button home. The tracked dashboard ships `"links": []`, so a hand run, and the standalone book/logs
stacks that have no landing page, get no link rather than a dead one.

The **config builder** is the odd one out: not a demo instance but a tool. It is the
`ghcr.io/fastbean-au/hippocampus-config-wizard` image — a static single-page app (source:
`cmd/config-wizard` in the [hippocampus](https://github.com/fastbean-au/hippocampus) repo) that walks
a visitor through a `config.json` and generates the deployment artefacts to carry it, entirely in
their browser. It holds no state, reaches no service, and makes no outbound request, so it sits on
the `shared` network with nothing else attached to it and needs no authentication. Since the config
it builds may contain the visitor's own secrets, that everything-client-side property is the point —
say so if you adapt this page.

The apex `${BASE_DOMAIN}` itself is also reverse-proxied, to the `hippocampus-site` landing-page
service (`hippocampus-site:80` by default, overridable with `SITE_UPSTREAM`). That service is part of
this stack — a static site built from the repo-root `Containerfile` and brought up with the demos, so
`up --build` deploys it too. Override `SITE_UPSTREAM` (or drop the service) and the apex returns 502
while every subdomain above keeps working.

Why this works with no config-file changes:

- **Shared Keycloak, one issuer.** Both services set
  `HIPPOCAMPUS_AUTH_ISSUER`/`_UI_ISSUER` to `https://auth.${BASE_DOMAIN}/realms/hippocampus`, and the
  shipped realm's console client already lists **both** `book.`/`logs.` `/ui` redirect URIs and one
  `hippocampus-gen` client — so a single Keycloak covers both. The [split-issuer](#the-split-issuer-fix)
  Caddy alias for `auth.${BASE_DOMAIN}` is what lets the containers reach it at the browser's URL.
- **Shared stores, isolated data, reused configs.** Both examples share one Postgres and one
  OpenSearch container, but stay logically isolated: the shared Postgres hosts a database per example
  (`hippocampus_book` / `hippocampus_logs`, created on first boot by
  [`postgres/init-showcase-combined.sql`](../showcase/postgres/init-showcase-combined.sql)) and each
  service uses its own OpenSearch index (`book-memories` / `logs-memories`). Separate databases keep
  each consolidating instance's [single-consolidator](https://github.com/fastbean-au/hippocampus/blob/main/README.md#horizontal-scaling) advisory
  lock from colliding; a shared cluster is otherwise fine. So
  [`config.showcase-book.json`](../showcase/config.showcase-book.json) and
  [`…-logs.json`](../showcase/config.showcase-logs.json) are still reused **verbatim** — the per-example
  DSN database name and index name are supplied as `HIPPOCAMPUS_STORAGE_POSTGRES_DSN` /
  `HIPPOCAMPUS_OPENSEARCH_INDEX` env overrides rather than by editing the configs.

Unlike the standalone stacks, the combined stack runs the **generators as containers**
(`hippocampus-gen-book` / `hippocampus-gen-logs`), so the single `up -d` above brings up a
**self-driving** showcase — the servers _and_ the load that feeds them, with no host processes or
systemd units. Both authenticate as the `hippocampus-gen` client to the shared issuer
`https://auth.${BASE_DOMAIN}/realms/hippocampus`, reaching it (via the Caddy alias) and their target
service by name over the shared network. They wait for Keycloak to report healthy — the stack enables
`KC_HEALTH_ENABLED` and gates the generators on it — so the book's first cycle doesn't miss its token
and idle a whole period. Override `GEN_SECRET` to match the realm if you change the demo secret. For a
real domain, set `BASE_DOMAIN` and change the console client's `redirectUris`/`webOrigins` in the
realm to match, along with the demo secrets.

#### One-command install on a fresh VM

On a clean **Ubuntu 24.04 (minimal)** host, [`showcase/install-ubuntu.sh`](../showcase/install-ubuntu.sh)
does the whole thing: it installs Podman + the compose provider, records the base domain and ACME
email, and registers a systemd unit that brings the combined stack up at boot (and back up after a
reboot — the containers' `restart: unless-stopped` handles crashes in between):

```sh
sudo ./showcase/install-ubuntu.sh \
  --base-domain hippocampus.example \
  --acme-email  you@example.com
# --gen-secret <secret>   optional; must match the realm if you changed it
```

Point DNS for the apex plus the `book.`/`logs.`/`auth.`/`grafana.`/`config-builder.` subdomains at
the host (80/443
reachable) so Caddy can provision TLS, and the self-driving showcase comes up on its own.

#### Updating a running deployment

Pull the new commits into the host's checkout first:

```sh
cd "$(systemctl show -p WorkingDirectory --value hippocampus-showcase)"   # the unit's checkout
sudo git pull
```

**Landing-site-only change** (edited `index.html` / `assets/`, nothing else) — run the site deploy
script. It rebuilds the site image and swaps the container in behind the front Caddy **with no apex
downtime**: it brings up an overlapping second backend on the `hippocampus-site` network alias,
removes the old container, recreates the compose-managed one from the new image, then drops the temp
backend, so the apex always has a live upstream and the rest of the stack is never touched. It also
sources the same `EnvironmentFile` the unit uses, so `BASE_DOMAIN` et al. are the real values.

```sh
sudo ./showcase/deploy-site.sh
```

**Front-Caddy service change** (edited the `caddy` service in `compose.showcase-combined.yaml` —
`init` / `healthcheck` / `env` / `ports` — but nothing else) — run the Caddy deploy script. It
recreates **only** Caddy and the two generators that require it, leaving the backing services
(postgres, opensearch, keycloak, otel-lgtm, book, logs) and the landing site untouched:

```sh
sudo ./showcase/deploy-caddy.sh
```

A plain `podman compose up -d caddy` cannot stand in for this: on podman-compose 1.0.6 it walks
Caddy's whole `depends_on` tree and recreates postgres/opensearch/keycloak/otel/book/logs with it —
a full-stack bounce no lighter than the systemd restart below. The script scopes the blast radius
with `up --no-deps` (and removes the generators first, since their `--requires caddy` edge otherwise
refuses Caddy's removal, then recreates them once Caddy is healthy). Unlike `deploy-site.sh` there is
**a brief apex + subdomain blip** — Caddy owns host `:80/:443`, so no overlapping backend is possible.
For a **Caddyfile-only** change (routes/headers, no compose change) skip the recreate entirely and
reload in place, downtime-free: `sudo podman exec showcase_caddy_1 caddy reload --config /etc/caddy/Caddyfile`.

**Any other change** (compose file beyond the caddy service, other Caddyfiles, configs, image bumps
for the demos) — **restart the systemd unit**. Its `ExecStart` is `up -d --build`, so the restart
rebuilds any changed images and recreates the containers:

```sh
sudo systemctl restart hippocampus-showcase
```

`restart` runs the unit's `down` + `up -d --build` + `start-generators` in one step and — crucially —
loads the unit's `EnvironmentFile` (`/etc/hippocampus-showcase/showcase.env`), so `BASE_DOMAIN` and
`ACME_EMAIL` are the real deployment values. It is a full-stack bounce (≈1–2 min while Keycloak
re-inits), but it keeps every named volume, so the realm is **not** re-imported and no data is lost.

> **Do not reach for `podman compose ... up -d --build hippocampus-site` by hand** to redeploy the
> site. On this stack's podman-compose (1.0.6) it fails two ways — which is exactly what
> `deploy-site.sh` works around:
>
> - **No in-place recreate.** podman-compose 1.0.6 does not pass `--replace`, so it hits the existing
>   container's name and silently falls back to _restarting the old container_ — the rebuilt image
>   never goes live. (`deploy-site.sh` does the `rm` + recreate itself. This is only possible because
>   caddy no longer `depends_on` the site — that `--requires` edge previously made the site
>   un-removable without cascading through caddy and the generators, forcing a full-stack bounce.)
> - **It bypasses the `EnvironmentFile`.** A raw compose invocation does not read `showcase.env`, so
>   `BASE_DOMAIN` falls back to the compose default `hippocampus.example`. `deploy-site.sh` sources it.

Re-run the installer instead only when the change is to the **base domain, the gen secret, or the
Keycloak realm** — [`install-ubuntu.sh`](../showcase/install-ubuntu.sh) is what re-renders the realm and
re-imports it (dropping the Keycloak volume) as part of restarting the unit:

```sh
sudo ./showcase/install-ubuntu.sh --base-domain hippocampus.example --acme-email you@example.com
```

> The landing site is served with `Cache-Control: public, max-age=3600, must-revalidate`, so a
> browser that visited within the hour may show the old page until it revalidates; new visitors and
> crawlers (the OG image and meta tags) get the rebuilt page at once.

To tear it back down, [`showcase/uninstall-ubuntu.sh`](../showcase/uninstall-ubuntu.sh) reverses the
installer — it stops and removes the systemd unit, brings the stack down, and deletes the env file.
It keeps the named volumes (and images) by default so a re-install reuses the data; pass
`--remove-volumes` to wipe the showcase data, `--remove-images` to drop the pulled/built images, and
`--remove-packages` to purge Podman:

```sh
sudo ./showcase/uninstall-ubuntu.sh
# --remove-volumes   also destroy Postgres/OpenSearch/Keycloak/Grafana/Caddy data
# --remove-images    also remove the pulled/built images
# --remove-packages  also purge podman + podman-compose
```

> **Shared identity is the trade-off.** One realm means one set of users and one signing key across
> both examples, so a token minted by signing in to the book console is also accepted by the logs
> service. That is fine for a demo; if you need the two examples to be security-isolated, keep the two
> separate stacks (and two domains) instead.

### A lite single stack (e2-micro)

The book/logs stacks each run Postgres + OpenSearch + Keycloak + otel-lgtm behind Caddy — together
they want ~10 GiB of RAM. When that is too much (a single tiny VM, a throwaway demo), the **lite
stack** [`showcase/compose.showcase-lite.yaml`](../showcase/compose.showcase-lite.yaml)
(config [`showcase/config.showcase-lite.json`](../showcase/config.showcase-lite.json)) strips it to two
containers — hippocampus on **SQLite** plus Caddy — and moves auth to **hosted [Auth0](#auth0-saas)**,
so there is no JVM on the box. It fits a **0.25 vCPU / 1 GiB** machine (~500 MiB in use; the quarter
core, not RAM, is the limit). The trade-off is the two heavy sidecars: **no content-search tab**
(OpenSearch) and **no Grafana dashboards** (telemetry).

Because Auth0's issuer is a single public URL the browser and the container both reach, the lite stack
needs neither the [split-issuer](#the-split-issuer-fix) Caddy-alias trick nor an `auth.` subdomain —
just one A record for the console. Bring it up with your Auth0 tenant details:

```sh
LITE_DOMAIN=demo.example ACME_EMAIL=you@example.com \
  AUTH0_DOMAIN=your-tenant.us.auth0.com \
  AUTH0_AUDIENCE=https://hippocampus.api \
  AUTH0_CLIENT_ID=<console SPA client id> \
  AUTH0_ROLES_CLAIM=https://hippocampus.example/roles \
  podman compose -f showcase/compose.showcase-lite.yaml up --build -d
```

The full walkthrough — Auth0 setup, the machine-to-machine generator, and the systemd unit — is the
[lite section of the GCP runbook](showcase-gcp.md#a-lite-stack-for-an-e2-micro).

### Local evaluation without a public domain

Automatic HTTPS needs a real domain, so the full Caddy stack does not come up as-is on a laptop. To
try the pieces locally, run Keycloak directly (the [Keycloak](#keycloak-self-hosted) section's
`podman run`) and a SQLite instance with `auth.method: idp` pointed at
`http://localhost:8092/realms/hippocampus` — the arrangement the idp round-trip was verified against.
The [`docker/docker-compose.corporate.yaml`](https://github.com/fastbean-au/hippocampus/blob/main/docker/docker-compose.corporate.yaml) stack remains the quick, unauthenticated local demo.
