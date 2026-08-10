#!/usr/bin/env bash
#
# deploy-generators.sh - pull the current hippocampus-gen images and recreate ONLY the generator
# containers (hippocampus-gen-book / hippocampus-gen-logs), leaving every other service in the
# combined showcase - Caddy, the consoles, Keycloak, the stores, the landing site - untouched.
#
# WHY THIS EXISTS: the generators track `:latest` from the separate hippocampus-gen repo, whose CI
# publishes on every push to main. Nothing on this host pulls that image on its own: `podman compose
# up -d` reuses the local copy, and the systemd unit's ExecStartPost (start-generators.sh) only
# STARTS the existing containers - it never pulls, so it cannot pick a new build up. Even
# `systemctl restart hippocampus-showcase`, which is a full-stack outage, leaves the generators on
# the stale image. So shipping a generator fix previously meant a hand-run pull + rm + up, straight
# through the two podman-compose 1.0.6 landmines below. This script is that sequence, done safely
# and verified.
#
# THE BOOK GENERATOR WIPES ITS STORE ON EVERY RECREATE. Its compose command carries `--reset` and
# `--loop`, and the loop's first cycle runs immediately, so a new container purges hippocampus_book
# and reloads Great Expectations from scratch across its 2h pace window. The book console therefore
# looks sparse for a while after a deploy. That is inherent to recreating this generator, not
# something the script chooses - which is why the script skips a service that is ALREADY on the
# pulled image unless --force is given, so a routine run cannot wipe the store for no reason.
#
# TWO podman-compose 1.0.6 LANDMINES this script routes around (see podman_compose.py ~2053-2069, and
# the fuller write-up in deploy-caddy.sh):
#
#   1. `--force-recreate` triggers a FULL-PROJECT down that ignores --no-deps and the named service
#      alike - the exact opposite of containment. This script never passes it, and instead removes
#      by hand the one container it wants replaced.
#   2. When `podman run` hits a name that is already in use, compose SILENTLY degrades to
#      `podman start <name>`, reviving the OLD container - and therefore the OLD image - while the
#      output still reads like a successful recreate. Freeing the name first makes that path
#      unreachable; assert_deployed below catches it regardless, by comparing the running
#      container's image revision against the one that was pulled.
#
# EXPECTED (ALARMING-LOOKING) OUTPUT: compose walks every service, so for each one already running
# you will see `Error: ... name is already in use` and an `exit code: 125`. That is landmine (2)
# firing harmlessly - `podman start` on an already-running container is a no-op, so those services
# keep their uptime. Confirm containment after a run by comparing `podman ps` uptimes; do NOT try to
# silence those errors with --force-recreate, which is landmine (1) and does bounce the stack.
#
# Run as root - the showcase containers live under root podman:
#   sudo ./showcase/deploy-generators.sh              # both generators, skipping any already current
#   sudo ./showcase/deploy-generators.sh book         # just the book generator
#   sudo ./showcase/deploy-generators.sh --force logs # recreate even if already on the pulled image
#
# Override the env file location if it is not the install default:
#   sudo SHOWCASE_ENV=/path/to/showcase.env ./showcase/deploy-generators.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/compose.showcase-combined.yaml"
CADDY_SERVICE="caddy"

FORCE=0
SERVICES=()

while [[ $# -gt 0 ]]; do
  case "$1" in

    --force)
      FORCE=1
      ;;

    book | logs)
      SERVICES+=("hippocampus-gen-$1")
      ;;

    hippocampus-gen-book | hippocampus-gen-logs)
      SERVICES+=("$1")
      ;;

    -h | --help)
      # Print the header block itself as the usage text, stopping at the first line of code so this
      # can never drift from the documentation above.
      awk 'NR > 1 { if (!/^#/) exit; print }' "${BASH_SOURCE[0]}"

      exit 0
      ;;

    *)
      echo "deploy-generators: unknown argument '$1' (expected: book, logs, --force)" >&2

      exit 1
      ;;

  esac

  shift
done

if [[ ${#SERVICES[@]} -eq 0 ]]; then
  SERVICES=(hippocampus-gen-book hippocampus-gen-logs)
fi

# Match the systemd unit: load BASE_DOMAIN / ACME_EMAIL / GEN_SECRET so compose interpolation uses the
# real deployment's values rather than the compose defaults (hippocampus.example). This matters more
# here than anywhere else - the generators authenticate against
# https://auth.${BASE_DOMAIN}/realms/hippocampus with GEN_SECRET, so a hand-run compose without these
# builds a container that points at a domain that does not exist and dies on its first token request.
SHOWCASE_ENV="${SHOWCASE_ENV:-/etc/hippocampus-showcase/showcase.env}"
if [[ -f "${SHOWCASE_ENV}" ]]; then
  set -a

  # shellcheck disable=SC1090
  source "${SHOWCASE_ENV}"

  set +a
else
  echo "deploy-generators: WARNING - ${SHOWCASE_ENV} not found; compose will use its built-in defaults" >&2
fi

# podman-compose derives the project name from the compose file's directory (see start-generators.sh),
# so scope every container lookup to it - a stray generator from another project is never matched.
PROJECT="$(basename "${SCRIPT_DIR}")"

# cname - the compose container name for a service in this project.
cname() {
  echo "${PROJECT}_${1}_1"
}

# cid - a container's full id, empty if it does not exist.
cid() {
  podman inspect -f '{{.Id}}' "$1" 2>/dev/null || true
}

# image_for - the image a service is pinned to, read from the compose file so this script cannot
# drift from it. Relies on the file's `  <service>:` / `    image: <ref>` shape.
image_for() {
  grep -A2 "^  ${1}:$" "${COMPOSE_FILE}" | sed -n 's/^ *image: *//p' | head -n1
}

# revision_of - the git commit an image or container was built from, via the OCI revision label that
# hippocampus-gen's workflow stamps on. Empty if the label is absent.
revision_of() {
  podman inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$1" 2>/dev/null || true
}

# running_services - the compose service name of every RUNNING container in this project, sorted.
# Used to spot (and undo) collateral from a full-project down that compose may fire behind our back.
running_services() {
  podman ps \
    --filter "label=io.podman.compose.project=${PROJECT}" \
    --format '{{ index .Labels "com.docker.compose.service"}}' | sort
}

# assert_caddy_healthy - the generators authenticate through the front Caddy, and on failure they
# exit rather than retry indefinitely (podman does not reliably restart them afterwards - the whole
# reason start-generators.sh exists). So refuse to recreate them while the issuer path is not
# serving, rather than replacing a working container with one that dies immediately.
assert_caddy_healthy() {
  local name status

  name="$(cname "${CADDY_SERVICE}")"
  status="$(podman inspect -f '{{.State.Health.Status}}' "${name}" 2>/dev/null || true)"

  if [[ -z "${status}" ]]; then
    echo "deploy-generators: WARNING - no ${CADDY_SERVICE} healthcheck to read; continuing" >&2

    return 0
  fi

  if [[ "${status}" != "healthy" ]]; then
    echo "deploy-generators: ERROR - ${CADDY_SERVICE} is '${status}', not healthy." >&2
    echo "deploy-generators: the generators would fail their first token request and exit." >&2
    echo "deploy-generators: fix the issuer path first (see deploy-caddy.sh), then retry." >&2

    return 1
  fi

  return 0
}

# assert_deployed - prove the recreate actually took: a container that exists, is still running a
# few seconds in, and carries the revision of the image we just pulled. The revision check is what
# catches landmine (2) - a silent `podman start` leaves the OLD image, and so the OLD revision, in
# place while every preceding log line claims success.
assert_deployed() {
  local service="$1" want_rev="$2" old_id="$3" name new_id got_rev

  name="$(cname "${service}")"
  new_id="$(cid "${name}")"

  if [[ -z "${new_id}" ]]; then
    echo "deploy-generators: ERROR - ${service} does not exist after the recreate." >&2

    return 1
  fi

  if [[ -n "${old_id}" && "${new_id}" == "${old_id}" ]]; then
    echo "deploy-generators: ERROR - ${service} was restarted, not recreated (id unchanged ${new_id:0:12})." >&2
    echo "deploy-generators: it is still on the old image." >&2

    return 1
  fi

  # The generators die on an auth or dial failure rather than restart-looping, and they do it within
  # a second or two, so a container still up after this pause has got past its first token request.
  sleep 5

  if [[ "$(podman inspect -f '{{.State.Running}}' "${name}" 2>/dev/null)" != "true" ]]; then
    echo "deploy-generators: ERROR - ${service} exited immediately after starting; last output:" >&2
    podman logs --tail 20 "${name}" 2>&1 | sed 's/^/  /' >&2

    return 1
  fi

  got_rev="$(revision_of "${name}")"

  if [[ -n "${want_rev}" && "${got_rev}" != "${want_rev}" ]]; then
    echo "deploy-generators: ERROR - ${service} is running revision ${got_rev:-<none>}, expected ${want_rev}." >&2

    return 1
  fi

  return 0
}

assert_caddy_healthy

BEFORE_RUNNING="$(running_services)"
DEPLOYED=()
SKIPPED=()

for service in "${SERVICES[@]}"; do
  IMAGE="$(image_for "${service}")"

  if [[ -z "${IMAGE}" ]]; then
    echo "deploy-generators: ERROR - no image found for ${service} in ${COMPOSE_FILE}" >&2

    exit 1
  fi

  NAME="$(cname "${service}")"
  OLD_ID="$(cid "${NAME}")"
  OLD_REV="$(revision_of "${NAME}")"

  echo "deploy-generators: pulling ${IMAGE}"
  podman pull -q "${IMAGE}" >/dev/null

  NEW_REV="$(revision_of "${IMAGE}")"

  # Nothing to ship: the running container is already built from the image we just pulled. Skipping
  # here is what keeps a routine run from purging the book store (see the header) for no gain.
  if [[ ${FORCE} -eq 0 && -n "${OLD_ID}" && -n "${NEW_REV}" && "${OLD_REV}" == "${NEW_REV}" ]]; then
    echo "deploy-generators: ${service} is already on ${NEW_REV:0:12}; skipping (use --force to recreate anyway)"
    SKIPPED+=("${service}")

    continue
  fi

  # Free the name ourselves rather than asking compose to recreate - with the name taken, `podman
  # run` clashes and silently degrades to `podman start` on the old container (landmine (2)).
  if [[ "${service}" == "hippocampus-gen-book" ]]; then
    echo "deploy-generators: recreating ${service} - NOTE: --reset purges the book store, which reloads over ~2h"
  else
    echo "deploy-generators: recreating ${service}"
  fi

  podman rm -f "${NAME}" >/dev/null 2>&1 || true

  # --no-deps keeps compose from walking the depends_on tree (keycloak, caddy, the stores). NOTE:
  # deliberately no --force-recreate - see landmine (1); the container is already gone in any case.
  podman compose -f "${COMPOSE_FILE}" up -d --no-deps "${service}"

  assert_deployed "${service}" "${NEW_REV}" "${OLD_ID}"

  DEPLOYED+=("${service}:${OLD_REV:0:12}->${NEW_REV:0:12}")
done

# Undo any collateral: a diff_hashes-triggered full-project down (landmine (1), which fires after any
# edit to the compose file) can stop backing services that --no-deps then declines to bring back up,
# which would leave the stack half down behind healthy generators.
for svc in $(comm -23 <(echo "${BEFORE_RUNNING}") <(running_services)); do
  case " ${SERVICES[*]} " in
    *" ${svc} "*) continue ;;
  esac

  echo "deploy-generators: restarting ${svc}, which compose stopped as collateral"
  podman start "$(cname "${svc}")" >/dev/null 2>&1 || true
done

# Report what actually happened rather than asserting a containment compose does not guarantee.
COLLATERAL="$(comm -13 <(printf '%s\n' "${SERVICES[@]}" | sort) \
  <(comm -23 <(echo "${BEFORE_RUNNING}") <(running_services)))"

if [[ -n "${COLLATERAL}" ]]; then
  echo "deploy-generators: WARNING - these services did not come back and need attention:" >&2
  echo "${COLLATERAL}" >&2

  exit 1
fi

if [[ ${#DEPLOYED[@]} -eq 0 ]]; then
  echo "deploy-generators: done - nothing to do; ${SKIPPED[*]} already current"

  exit 0
fi

echo "deploy-generators: done - deployed ${DEPLOYED[*]}"
