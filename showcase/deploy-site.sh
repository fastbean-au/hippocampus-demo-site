#!/usr/bin/env bash
#
# deploy-site.sh - redeploy ONLY the landing site (the hippocampus-site service) with no apex
# downtime, without bouncing the rest of the combined showcase.
#
# WHY THIS EXISTS: `systemctl restart hippocampus-showcase` is a full-stack bounce (~1-2 min while
# Keycloak re-inits) that briefly takes the WHOLE demo - consoles, IdP, generators - down. That is far
# too heavy, and far too visible, for a copy change to index.html / assets. A plain
# `podman compose up -d --build hippocampus-site` cannot stand in for it either: podman-compose 1.0.6
# does not pass --replace, so when the site container already exists it hits a name clash and silently
# falls back to restarting the OLD container - the rebuilt image never goes live.
#
# WHAT THIS DOES: rebuilds the site image, then swaps the container in behind the front Caddy using an
# overlapping SECOND backend on the same `hippocampus-site` network alias, so the apex always has at
# least one live upstream and never 502s (see the sequence below). It sources the systemd unit's
# EnvironmentFile so BASE_DOMAIN et al. are the real deployment's values - a hand-run compose would
# otherwise fall back to the compose defaults (hippocampus.example) and stamp the wrong domain.
#
# This works only because caddy no longer `depends_on` hippocampus-site (see the note in
# compose.showcase-combined.yaml); with that edge in place the `podman rm` below would be refused.
#
# Run as root - the showcase containers live under root podman:
#   sudo ./showcase/deploy-site.sh
#
# Override the env file location if it is not the install default:
#   sudo SHOWCASE_ENV=/path/to/showcase.env ./showcase/deploy-site.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/compose.showcase-combined.yaml"
SERVICE="hippocampus-site"
IMAGE="hippocampus-demo-site:latest"
NETWORK="hippocampus-shared"
ALIAS="hippocampus-site"
TEMP_NAME="hippocampus-site-deploy"

# Match the systemd unit: load BASE_DOMAIN / ACME_EMAIL / GEN_SECRET so compose interpolation uses the
# real deployment's values rather than the compose defaults. Override the path with SHOWCASE_ENV.
SHOWCASE_ENV="${SHOWCASE_ENV:-/etc/hippocampus-showcase/showcase.env}"
if [[ -f "${SHOWCASE_ENV}" ]]; then
  set -a

  # shellcheck disable=SC1090
  source "${SHOWCASE_ENV}"

  set +a
else
  echo "deploy-site: WARNING - ${SHOWCASE_ENV} not found; compose will use its built-in defaults" >&2
fi

# podman-compose derives the project name from the compose file's directory (see start-generators.sh),
# so scope container lookups to it - a stray site container from another project is never matched.
PROJECT="$(basename "${SCRIPT_DIR}")"

# find_site_cid - the current compose-managed site container id, if any (by label, project-scoped).
find_site_cid() {
  podman ps -aq \
    --filter "label=com.docker.compose.project=${PROJECT}" \
    --filter "label=com.docker.compose.service=${SERVICE}" | head -n1
}

# wait_serving - poll a container's own HTTP until it answers, so a backend is only ever treated as
# live once it actually serves. Returns non-zero if it never came up.
wait_serving() {
  local cid="$1"

  for _ in $(seq 1 30); do
    if podman exec "${cid}" wget -qO- http://localhost:80/ >/dev/null 2>&1; then
      return 0
    fi

    sleep 1
  done

  return 1
}

echo "deploy-site: building ${IMAGE} from ${REPO_ROOT}"
podman compose -f "${COMPOSE_FILE}" build "${SERVICE}"

# Clean up any temp backend left behind by an interrupted earlier run before starting a new one.
podman rm -f "${TEMP_NAME}" >/dev/null 2>&1 || true

OLD_CID="$(find_site_cid)"

if [[ -n "${OLD_CID}" ]]; then
  echo "deploy-site: starting an overlapping backend on alias '${ALIAS}' so the apex never drops"
  podman run -d --name "${TEMP_NAME}" \
    --network "${NETWORK}" --network-alias "${ALIAS}" \
    "${IMAGE}" >/dev/null

  if ! wait_serving "${TEMP_NAME}"; then
    echo "deploy-site: temp backend never served; aborting with the live site untouched" >&2
    podman rm -f "${TEMP_NAME}" >/dev/null 2>&1 || true

    exit 1
  fi

  # The alias now resolves to both old and temp, so removing the old container leaves temp serving the
  # apex - no gap. (This rm is exactly what compose cannot do while caddy depends_on the site.)
  echo "deploy-site: temp backend live; removing the old site container"

  if ! podman rm -f "${OLD_CID}" >/dev/null 2>&1; then
    # The only expected cause is a caddy container still carrying the old `--requires hippocampus-site`
    # edge - i.e. this stack has not been restarted since caddy stopped depending on the site. One
    # `systemctl restart hippocampus-showcase` recreates caddy without the edge and activates this path.
    echo "deploy-site: could not remove the old site container - the running caddy still requires it." >&2
    echo "deploy-site: run 'sudo systemctl restart hippocampus-showcase' once to activate, then retry." >&2
    podman rm -f "${TEMP_NAME}" >/dev/null 2>&1 || true

    exit 1
  fi
fi

# Recreate the proper compose-managed container from the new image. The old name is now free, so no
# --replace is needed; while this comes up the temp backend still holds the alias.
echo "deploy-site: (re)creating the compose-managed ${SERVICE} from the new image"
podman compose -f "${COMPOSE_FILE}" up -d "${SERVICE}"

NEW_CID="$(find_site_cid)"

if [[ -n "${NEW_CID}" ]] && ! wait_serving "${NEW_CID}"; then
  echo "deploy-site: WARNING - the new ${SERVICE} container is not serving yet" >&2
fi

# The compose-managed container is live on the new image and holds the alias, so dropping the temp
# backend leaves the apex up throughout.
podman rm -f "${TEMP_NAME}" >/dev/null 2>&1 || true

echo "deploy-site: done - ${SERVICE} is live on the new image"
