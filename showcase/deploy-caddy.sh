#!/usr/bin/env bash
#
# deploy-caddy.sh - recreate ONLY the front Caddy (plus the two generators that require it) to pick up
# a compose-level change to the `caddy` service - init / healthcheck / env / ports / volumes - while
# leaving the backing services (postgres, opensearch, keycloak, otel-lgtm, book, logs) and the landing
# site untouched.
#
# WHY THIS EXISTS: on this stack's podman-compose (1.0.6) a plain `podman compose up -d caddy`
# recreates Caddy's ENTIRE depends_on tree (postgres/opensearch/keycloak/otel/book/logs) - a ~1-2 min
# outage no lighter than `systemctl restart hippocampus-showcase`. And Caddy cannot be recreated on
# its own out of the box: the generators carry a `--requires caddy` edge, so `podman rm caddy` (which
# a recreate must do) is refused while they exist. This script scopes the blast radius to Caddy + the
# generators by (a) removing the generators first so Caddy is free to be replaced, (b) recreating
# Caddy with `up --no-deps --force-recreate` so its dependency tree is NOT dragged along, then (c)
# bringing the generators back once Caddy is serving again - they do NOT reliably self-restart after
# the cold-start OIDC race, so they must be (re)created only once the issuer answers.
#
# NO ZERO-DOWNTIME here, unlike deploy-site.sh: Caddy owns host :80/:443, so a second overlapping
# backend cannot bind them. Expect a few-seconds apex + subdomain blip while Caddy is recreated.
#
# For a Caddyfile-ONLY change (routes / headers, no change to the compose service), prefer the even
# lighter, downtime-free reload - the Caddyfile is bind-mounted, so no recreate is needed:
#   sudo podman exec showcase_caddy_1 caddy reload --config /etc/caddy/Caddyfile
# Use THIS script only for changes to the caddy SERVICE in compose.showcase-combined.yaml.
#
# Run as root - the showcase containers live under root podman:
#   sudo ./showcase/deploy-caddy.sh
#
# Override the env file location if it is not the install default:
#   sudo SHOWCASE_ENV=/path/to/showcase.env ./showcase/deploy-caddy.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/compose.showcase-combined.yaml"
CADDY_SERVICE="caddy"
GEN_SERVICES=(hippocampus-gen-book hippocampus-gen-logs)

# Match the systemd unit: load BASE_DOMAIN / ACME_EMAIL / GEN_SECRET so compose interpolation uses the
# real deployment's values rather than the compose defaults (hippocampus.example) - a hand-run compose
# would otherwise stamp the wrong domain onto Caddy's aliases and healthcheck. Override with SHOWCASE_ENV.
SHOWCASE_ENV="${SHOWCASE_ENV:-/etc/hippocampus-showcase/showcase.env}"
if [[ -f "${SHOWCASE_ENV}" ]]; then
  set -a

  # shellcheck disable=SC1090
  source "${SHOWCASE_ENV}"

  set +a
else
  echo "deploy-caddy: WARNING - ${SHOWCASE_ENV} not found; compose will use its built-in defaults" >&2
fi

# podman-compose derives the project name from the compose file's directory and names containers
# <project>_<service>_1, so the project prefix already scopes these to this stack.
PROJECT="$(basename "${SCRIPT_DIR}")"

# cname - the compose container name for a service in this project.
cname() {
  echo "${PROJECT}_${1}_1"
}

# wait_healthy - poll a container's healthcheck until it reports healthy. Non-zero if it never does.
wait_healthy() {
  local name="$1"

  for _ in $(seq 1 40); do
    if [[ "$(podman inspect -f '{{.State.Health.Status}}' "${name}" 2>/dev/null)" == "healthy" ]]; then
      return 0
    fi

    sleep 3
  done

  return 1
}

# The generators carry a `--requires caddy` edge, so Caddy cannot be removed while they exist. Remove
# them first - they are recreated once Caddy is healthy again. This only pauses the demo's load briefly.
echo "deploy-caddy: removing the generators so Caddy can be recreated (they require it)"
for svc in "${GEN_SERVICES[@]}"; do
  podman rm -f "$(cname "${svc}")" >/dev/null 2>&1 || true
done

# Recreate ONLY Caddy. --no-deps stops podman-compose walking Caddy's depends_on tree and bouncing
# postgres/opensearch/keycloak/otel/book/logs with it; --force-recreate guarantees the new service
# definition is applied even if the config hash looks unchanged. Brief apex + subdomain blip here.
echo "deploy-caddy: recreating the front Caddy (brief apex + subdomain blip)"
podman compose -f "${COMPOSE_FILE}" up -d --no-deps --force-recreate "${CADDY_SERVICE}"

# Gate the generators on Caddy actually serving the issuer again: its healthcheck probes the exact
# OIDC discovery path the generators authenticate against, so once it is healthy their first token
# attempt succeeds.
echo "deploy-caddy: waiting for Caddy to report healthy"
if ! wait_healthy "$(cname "${CADDY_SERVICE}")"; then
  echo "deploy-caddy: WARNING - Caddy did not report healthy in time; starting generators anyway" >&2
fi

# Bring the generators back. --no-deps again so recreating them does not drag Caddy (and its whole
# tree) through another recreate.
echo "deploy-caddy: recreating the generators"
podman compose -f "${COMPOSE_FILE}" up -d --no-deps "${GEN_SERVICES[@]}"

echo "deploy-caddy: done - Caddy recreated on the new definition; backing services and site untouched"
