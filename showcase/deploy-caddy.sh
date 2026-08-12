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
# generators by (a) removing the generators first so Caddy is free to be replaced, (b) removing the
# Caddy container ITSELF so its name is free, (c) creating it again from the current definition, then
# (d) bringing the generators back once Caddy is serving again - they do NOT reliably self-restart
# after the cold-start OIDC race, so they must be (re)created only once the issuer answers.
#
# TWO podman-compose 1.0.6 LANDMINES this script must route around (see podman_compose.py ~2053-2069);
# both were hit in anger on 2026-08-05 and the script has been rewritten to avoid them:
#
#   1. `--force-recreate` is NOT safe here, despite being the obvious flag for the job. Its handler is
#      `if args.force_recreate or len(diff_hashes): compose.commands["down"](...)` - a FULL-PROJECT
#      down that ignores --no-deps and the named service alike. Passing it to contain the blast radius
#      does the exact opposite: it takes the whole stack down. This script therefore never passes it
#      and removes the one container it wants replaced by hand.
#   2. When `podman run` fails because the container name is already in use, compose SILENTLY falls
#      back to `podman start <name>` - reviving the OLD container while reporting success. That is why
#      step (b) exists: with the name already free, `run` cannot clash and cannot fall back. The
#      verification at the end catches it anyway if it ever does.
#
# Note that `diff_hashes` fires the same full-project down whenever a container's stored config-hash
# differs from the compose file's current hash - i.e. after ANY edit to compose.showcase-combined.yaml.
# That is unavoidable through compose, so this script re-starts anything the down stopped and reports
# honestly what it touched rather than claiming a containment it cannot guarantee.
#
# EXPECTED (ALARMING-LOOKING) OUTPUT: compose walks every service and you will see, for each one that
# is already running, `Error: ... name is already in use` followed by `podman start <name>`. That is
# landmine (2) firing harmlessly - `podman start` on an ALREADY-RUNNING container is a no-op, so those
# services are not restarted and keep their uptime. Verified 2026-08-05: after a run of this script
# the backing services still showed hours of uptime while only Caddy and the generators were new. Do
# not "fix" those errors by adding --force-recreate; that is landmine (1) and it genuinely does bounce
# the stack. To confirm containment after a run, compare `podman ps` uptimes.
#
# NO ZERO-DOWNTIME here, unlike deploy-site.sh: Caddy owns host :80/:443, so a second overlapping
# backend cannot bind them. Expect a few-seconds apex + subdomain blip while Caddy is recreated.
#
# WHEN A `caddy reload` IS ENOUGH - AND WHEN IT SILENTLY IS NOT. The Caddyfile is bind-mounted as a
# FILE, so the mount is pinned to that file's inode at container start. A reload:
#   sudo podman exec showcase_caddy_1 caddy reload --config /etc/caddy/Caddyfile
# only picks up an edit that kept the SAME inode (`cat new > Caddyfile`, i.e. truncate-and-write).
# Anything that replaces the file - `git pull`, `sed -i`, `mv`, most editors' write-new-then-rename -
# leaves the container reading the OLD inode: the file on the host is new, the one inside the
# container is not, and `caddy reload` cheerfully logs "config is unchanged" and exits 0. On a host
# that updates by `git pull` (this one), reload is therefore NOT usable for a Caddyfile change - use
# this script, which recreates the container and so re-resolves the mount. `assert_caddyfile_fresh`
# below fails the run if the mounted copy still does not match the host's.
#
# Run as root - the showcase containers live under root podman:
#   sudo ./showcase/deploy-caddy.sh
#
# Override the env file location if it is not the install default:
#   sudo SHOWCASE_ENV=/path/to/showcase.env ./showcase/deploy-caddy.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/compose.showcase-combined.yaml"
CADDYFILE="${SCRIPT_DIR}/caddy/Caddyfile.combined"
CADDY_SERVICE="caddy"
GEN_SERVICES=(hippocampus-gen-book hippocampus-gen-logs hippocampus-bluesky-bridge)

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

# cid - a container's full id, empty if it does not exist.
cid() {
  podman inspect -f '{{.Id}}' "$1" 2>/dev/null || true
}

# running_services - the compose service name of every RUNNING container in this project, sorted. Used
# to spot (and undo) collateral from a full-project down that podman-compose may fire behind our back.
running_services() {
  podman ps \
    --filter "label=io.podman.compose.project=${PROJECT}" \
    --format '{{ index .Labels "com.docker.compose.service"}}' | sort
}

# assert_caddyfile_fresh - prove the Caddyfile the container is actually serving matches the host's.
# This is the check that would have caught the stale-inode bind mount described in the header, where
# the host file was updated but the container kept reading the pre-update inode.
assert_caddyfile_fresh() {
  local name="$1" host_sum container_sum

  host_sum="$(md5sum <"${CADDYFILE}" | awk '{print $1}')"
  container_sum="$(podman exec "${name}" md5sum /etc/caddy/Caddyfile 2>/dev/null | awk '{print $1}')"

  if [[ -z "${container_sum}" ]]; then
    echo "deploy-caddy: WARNING - could not read the Caddyfile inside ${name} to verify it" >&2

    return 0
  fi

  if [[ "${host_sum}" != "${container_sum}" ]]; then
    echo "deploy-caddy: ERROR - the mounted Caddyfile does not match ${CADDYFILE}." >&2
    echo "deploy-caddy: the container is serving a stale copy (host ${host_sum}, container ${container_sum})." >&2

    return 1
  fi

  return 0
}

CADDY_NAME="$(cname "${CADDY_SERVICE}")"
OLD_CADDY_ID="$(cid "${CADDY_NAME}")"
BEFORE_RUNNING="$(running_services)"

# The generators carry a `--requires caddy` edge, so Caddy cannot be removed while they exist. Remove
# them first - they are recreated once Caddy is healthy again. This only pauses the demo's load briefly.
echo "deploy-caddy: removing the generators so Caddy can be recreated (they require it)"
for svc in "${GEN_SERVICES[@]}"; do
  podman rm -f "$(cname "${svc}")" >/dev/null 2>&1 || true
done

# Free the name ourselves rather than asking compose to recreate. This is landmine (2) in the header:
# leaving the old container in place lets `podman run` clash on the name and silently degrade to
# `podman start`, which revives the OLD container - same image, same STALE bind mounts - while every
# log line still reads like a successful recreate. With the name free that path cannot be taken.
echo "deploy-caddy: removing the existing Caddy container (brief apex + subdomain blip starts here)"
podman rm -f "${CADDY_NAME}" >/dev/null 2>&1 || true

# Create Caddy again from the current definition. --no-deps keeps compose from walking the depends_on
# tree. NOTE: deliberately NO --force-recreate - see landmine (1); the container is already gone, so
# there is nothing left for it to force.
echo "deploy-caddy: creating the front Caddy from the current definition"
podman compose -f "${COMPOSE_FILE}" up -d --no-deps "${CADDY_SERVICE}"

NEW_CADDY_ID="$(cid "${CADDY_NAME}")"

if [[ -z "${NEW_CADDY_ID}" ]]; then
  echo "deploy-caddy: ERROR - no Caddy container exists after the recreate; the apex is DOWN." >&2
  echo "deploy-caddy: recover with 'sudo systemctl restart hippocampus-showcase'." >&2

  exit 1
fi

# The failure this script previously reported as success: same container id means it was restarted,
# not replaced, so the new definition and any updated bind-mounted file never took effect.
if [[ -n "${OLD_CADDY_ID}" && "${NEW_CADDY_ID}" == "${OLD_CADDY_ID}" ]]; then
  echo "deploy-caddy: ERROR - Caddy was restarted, not recreated (id unchanged ${NEW_CADDY_ID:0:12})." >&2
  echo "deploy-caddy: the new definition is NOT live. Recover with 'sudo systemctl restart hippocampus-showcase'." >&2

  exit 1
fi

# Gate the generators on Caddy actually serving the issuer again: its healthcheck probes the exact
# OIDC discovery path the generators authenticate against, so once it is healthy their first token
# attempt succeeds.
echo "deploy-caddy: waiting for Caddy to report healthy"
if ! wait_healthy "${CADDY_NAME}"; then
  echo "deploy-caddy: WARNING - Caddy did not report healthy in time; starting generators anyway" >&2
fi

assert_caddyfile_fresh "${CADDY_NAME}"

# Undo any collateral: a diff_hashes-triggered full-project down (landmine (1), which fires after any
# edit to the compose file) can stop backing services that --no-deps then declines to bring back up,
# which would leave the stack half down behind a healthy Caddy.
for svc in $(comm -23 <(echo "${BEFORE_RUNNING}") <(running_services)); do
  case " ${GEN_SERVICES[*]} " in
    *" ${svc} "*) continue ;;
  esac

  echo "deploy-caddy: restarting ${svc}, which compose stopped as collateral"
  podman start "$(cname "${svc}")" >/dev/null 2>&1 || true
done

# Bring the generators back. --no-deps again so recreating them does not drag Caddy (and its whole
# tree) through another recreate.
echo "deploy-caddy: recreating the generators"
podman compose -f "${COMPOSE_FILE}" up -d --no-deps "${GEN_SERVICES[@]}"

# Report what actually happened rather than asserting a containment compose does not guarantee.
COLLATERAL="$(comm -13 <(printf '%s\n' "${CADDY_SERVICE}" "${GEN_SERVICES[@]}" | sort) \
  <(comm -23 <(echo "${BEFORE_RUNNING}") <(running_services)))"

if [[ -n "${COLLATERAL}" ]]; then
  echo "deploy-caddy: WARNING - these services did not come back and need attention:" >&2
  echo "${COLLATERAL}" >&2

  exit 1
fi

echo "deploy-caddy: done - Caddy recreated (${OLD_CADDY_ID:0:12} -> ${NEW_CADDY_ID:0:12}) on the current definition"
