#!/usr/bin/env bash
#
# deploy-generators.sh - pull the current image for a load-bearing container and recreate ONLY that
# container, leaving every other service in the combined showcase - Caddy, the consoles, Keycloak,
# the stores, the landing site - untouched.
#
# It covers five services, in two groups:
#
#   hippocampus-gen-book / hippocampus-gen-logs / hippocampus-gen-agent   the generators (the default selection)
#   hippocampus-bluesky / hippocampus-bluesky-bridge / hippocampus-bluesky-bridge-worldnews
#                                                 the Bluesky demo's service and its TWO bridges
#
# The Bluesky group is here because it has exactly the same problem and exactly the same answer: the
# bridges are that demo's loaders AND its load, and they track `:latest` from the hippocampus repo's
# releases. They are NOT in the default selection, though - deploying a service is heavier than
# deploying a generator, so it must be asked for by name.
#
# THE TWO BRIDGES ARE NOT INTERCHANGEABLE. `hippocampus-bluesky-bridge` reads the Trending News feed
# and is the ONLY firehose consumer: it alone reinforces and honours deletes, blind by id, for every
# memory in the shared store - the WorldNews bridge's included. So while it is down or being
# recreated, nothing reinforces anything on that console, whereas the WorldNews bridge is a plain feed
# poller whose absence costs only new WorldNews headlines.
#
# WHY THIS EXISTS: these containers track `:latest` from a repo whose CI publishes without touching
# this host. Nothing here pulls that image on its own: `podman compose up -d` reuses the local copy,
# and the systemd unit's ExecStartPost (start-generators.sh) only STARTS the existing containers - it
# never pulls, so it cannot pick a new build up. Even `systemctl restart hippocampus-showcase`, which
# is a full-stack outage, leaves them on the stale image. So shipping a fix meant a hand-run pull +
# rm + up, straight through the two podman-compose 1.0.6 landmines below. This script is that
# sequence, done safely and verified.
#
# ORDER MATTERS WITHIN THE BLUESKY PAIR, so the selection is sorted rather than taken in the order
# given: the service is recreated before its bridge, because the bridge dials it and exits on a dial
# failure rather than waiting. Recreating the bridge alone is safe at any time; recreating it while
# its service is down means one immediate restart.
#
# REMOVAL RUNS IN THE OPPOSITE ORDER, and every name in the selection is freed before any of them is
# recreated. compose stamps depends_on as a podman `--requires` edge, and podman refuses to remove a
# container while something requires it - so the bridge must go first, and the service cannot be
# removed at all until it has. Interleaving the two (remove service, recreate service, remove bridge,
# ...) is what broke this script's first bluesky run: the removal was refused, the `|| true` hid it,
# the taken name sent compose down landmine (2), and the "deploy" started the old container again.
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
# THE FIRST RUN AFTER A COMPOSE-FILE EDIT IS NOT A TARGETED DEPLOY - it is a full-stack bounce, and
# this script cannot prevent it. Landmine (1) is not only reached by --force-recreate: the same
# handler fires on `len(diff_hashes)`, and podman-compose stamps a hash of the WHOLE YAML into every
# container, so after any edit to compose.showcase-combined.yaml every container's stored hash
# differs and the full-project down runs on the next `up` - whatever service was named, and with
# --no-deps ignored (get_excluded does not consult it). Naming one service buys nothing on that run:
# Postgres, OpenSearch, Keycloak and Ollama go down with it. So after editing the compose file, take
# the outage deliberately - `systemctl restart hippocampus-showcase`, or a run of this script with
# the blast radius understood - and use the targeted form from the run AFTER that, once every
# container carries the current hash. The collateral wait at the end of a run exists precisely
# because this happens; it restarts what the down stopped, but it cannot make the deploy contained.
#
# EXPECTED (ALARMING-LOOKING) OUTPUT: compose walks every service, so for each one already running
# you will see `Error: ... name is already in use` and an `exit code: 125`. That is landmine (2)
# firing harmlessly - `podman start` on an already-running container is a no-op, so those services
# keep their uptime. Confirm containment after a run by comparing `podman ps` uptimes; do NOT try to
# silence those errors with --force-recreate, which is landmine (1) and does bounce the stack.
#
# A run ends by WAITING for anything the stack lost as collateral to come back, rather than reading
# `podman ps` once. A hippocampus server restart-looping on a booting Keycloak's 502s is regularly
# caught between restarts by a single reading, which used to fail the run over a service that was
# fine seconds later. Only a service still down after COLLATERAL_WAIT_SECONDS now fails it.
#
# NEITHER BLUESKY CONTAINER LOSES DATA on a recreate - that store is in Postgres - but the bridge
# holds three things only in memory, all by design: its Jetstream cursor (a restart resumes at the
# live tip, so the gap is skipped), its capture and author indexes, and its topic-term index. The
# indexes are rebuilt by the startup feed backfill within a poll or two; the gap is simply lost, which
# is what "a stream of the present, not a ledger" means.
#
# Run as root - the showcase containers live under root podman:
#   sudo ./showcase/deploy-generators.sh                # both generators, skipping any already current
#   sudo ./showcase/deploy-generators.sh book           # just the book generator
#   sudo ./showcase/deploy-generators.sh --force logs   # recreate even if already on the pulled image
#   sudo ./showcase/deploy-generators.sh bluesky        # the bluesky service AND both bridges, in that order
#   sudo ./showcase/deploy-generators.sh bluesky-bridge # just the Trending News bridge (a flag change, no new service image)
#   sudo ./showcase/deploy-generators.sh bluesky-bridge-worldnews   # just the WorldNews bridge
#
# Override the env file location if it is not the install default:
#   sudo SHOWCASE_ENV=/path/to/showcase.env ./showcase/deploy-generators.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/compose.showcase-combined.yaml"
CADDY_SERVICE="caddy"

# How long a service knocked over as collateral is given to come back before the run calls it stuck,
# and how often that is re-checked. The wait costs nothing when nothing was knocked over - the poll
# below exits on the first empty reading - so this is sized for the slow case: Keycloak booting, and
# the hippocampus servers restart-looping on its 502s until it answers (see the poll for why).
COLLATERAL_WAIT_SECONDS=90
COLLATERAL_POLL_SECONDS=3

FORCE=0
SERVICES=()

while [[ $# -gt 0 ]]; do
  case "$1" in

    --force)
      FORCE=1
      ;;

    book | logs | agent | observer)
      SERVICES+=("hippocampus-gen-$1")
      ;;

    # A release updates the service image and the bridge image together, so the bare name selects the
    # service and both bridges; the names below select any one of them on its own.
    bluesky)
      SERVICES+=(
        "hippocampus-bluesky"
        "hippocampus-bluesky-bridge"
        "hippocampus-bluesky-bridge-worldnews"
      )
      ;;

    bluesky-bridge)
      SERVICES+=("hippocampus-bluesky-bridge")
      ;;

    bluesky-bridge-worldnews)
      SERVICES+=("hippocampus-bluesky-bridge-worldnews")
      ;;

    hippocampus-gen-book | hippocampus-gen-logs | hippocampus-gen-agent | \
      hippocampus-gen-observer | hippocampus-bluesky | \
      hippocampus-bluesky-bridge | hippocampus-bluesky-bridge-worldnews)
      SERVICES+=("$1")
      ;;

    -h | --help)
      # Print the header block itself as the usage text, stopping at the first line of code so this
      # can never drift from the documentation above.
      awk 'NR > 1 { if (!/^#/) exit; print }' "${BASH_SOURCE[0]}"

      exit 0
      ;;

    *)
      echo "deploy-generators: unknown argument '$1' (expected: book, logs, bluesky, bluesky-bridge, bluesky-bridge-worldnews, --force)" >&2

      exit 1
      ;;

  esac

  shift
done

# The default stays the two generators. Recreating a SERVICE is heavier than recreating its load, so
# the bluesky group is only ever deployed when named.
if [[ ${#SERVICES[@]} -eq 0 ]]; then
  SERVICES=(hippocampus-gen-book hippocampus-gen-logs)
fi

# Sort the selection into a canonical order, which also dedupes `bluesky bluesky-bridge`. The order is
# the reason this exists rather than taking argv as given: a bridge recreated before its service dials
# a socket that is not there and exits (see the header).
ORDER=(
  hippocampus-bluesky
  hippocampus-bluesky-bridge
  hippocampus-bluesky-bridge-worldnews
  hippocampus-gen-book
  hippocampus-gen-logs
  hippocampus-gen-agent
  hippocampus-gen-observer
)
SELECTED=()

for candidate in "${ORDER[@]}"; do
  case " ${SERVICES[*]} " in
    *" ${candidate} "*) SELECTED+=("${candidate}") ;;
  esac
done

# Anything the loop above did not match is silently gone, and a service missing from ORDER looks
# exactly like a successful no-op run ("nothing to do"). That is how the agent and observer
# generators were unshippable for a day: they were added to the argument parsing and not here. Fail
# loudly instead - a selection that empties itself is a bug in this script, never a valid request.
if [[ ${#SERVICES[@]} -gt 0 && ${#SELECTED[@]} -eq 0 ]]; then
  echo "deploy-generators: ERROR - none of '${SERVICES[*]}' appear in ORDER; add them there" >&2

  exit 1
fi

SERVICES=("${SELECTED[@]}")

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

# dependents_of - the containers in this project holding a podman `--requires` edge on the given
# container id: the ones podman insists are removed BEFORE it. compose stamps those edges from
# depends_on, which is why the bluesky bridge pins the bluesky service.
dependents_of() {
  local target="$1" name

  if [[ -z "${target}" ]]; then
    return 0
  fi

  for name in $(podman ps -a --filter "label=io.podman.compose.project=${PROJECT}" --format '{{.Names}}'); do
    case " $(podman inspect -f '{{range .Dependencies}}{{.}} {{end}}' "${name}" 2>/dev/null) " in
      *" ${target} "*) echo "${name}" ;;
    esac
  done
}

# remove_service - free a service's container name so the recreate below cannot degrade to `podman
# start` (landmine (2)). The refusal is NOT swallowed: podman declines to remove a container while
# another one `--requires` it, and swallowing that is exactly how a stale container survives an
# otherwise "successful" deploy. Callers must work in reverse creation order, so that a dependent
# INSIDE this run's selection is already gone by the time its service is removed; anything still
# blocking at this point is therefore outside the selection, and is named in the error.
remove_service() {
  local service="$1" name id blockers

  name="$(cname "${service}")"
  id="$(cid "${name}")"

  if [[ -z "${id}" ]]; then
    return 0
  fi

  if podman rm -f "${name}" >/dev/null 2>&1; then
    return 0
  fi

  blockers="$(dependents_of "${id}" | tr '\n' ' ')"

  echo "deploy-generators: ERROR - podman refused to remove ${name}." >&2

  if [[ -n "${blockers}" ]]; then
    echo "deploy-generators: it is --require'd by: ${blockers}" >&2
    echo "deploy-generators: select those in the same run so they are removed first - 'bluesky' takes the whole group." >&2
  fi

  return 1
}

# running_services - the compose service name of every RUNNING container in this project, sorted.
# Used to spot (and undo) collateral from a full-project down that compose may fire behind our back.
running_services() {
  podman ps \
    --filter "label=io.podman.compose.project=${PROJECT}" \
    --format '{{ index .Labels "com.docker.compose.service"}}' | sort
}

# missing_services - the services that were running when this script started, are not running now,
# and are not part of this run's selection (those are assert_deployed's business, not collateral).
# Depends on BEFORE_RUNNING and SERVICES, both sorted, as `comm` requires.
missing_services() {
  comm -13 <(printf '%s\n' "${SERVICES[@]}" | sort) \
    <(comm -23 <(echo "${BEFORE_RUNNING}") <(running_services))
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

# The run is planned before anything is touched, so that the teardown below can work through the
# whole selection in reverse - which is the only order podman permits (see remove_service).
PLAN=()
PLAN_WANT_REV=()
PLAN_OLD_ID=()
PLAN_OLD_REV=()

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

  echo "deploy-generators: recreating ${service}"

  case "${service}" in

    hippocampus-gen-book)
      echo "deploy-generators: NOTE - --reset purges the book store, which reloads over ~2h"
      ;;

    hippocampus-bluesky)
      echo "deploy-generators: NOTE - the bluesky console is unavailable for a few seconds; its store is in postgres and survives"
      ;;

    hippocampus-bluesky-bridge)
      echo "deploy-generators: NOTE - the bridge resumes at the firehose's live tip (that gap is lost) and rebuilds its in-memory indexes from the feed backfill"
      echo "deploy-generators: NOTE - it is the store's ONLY reinforcement and delete consumer, so nothing on that console is reinforced until it is back"
      ;;

    hippocampus-bluesky-bridge-worldnews)
      echo "deploy-generators: NOTE - a feed poller only; it rebuilds its topic-term index from the feed backfill and reinforces nothing either way"
      ;;

  esac

  PLAN+=("${service}")
  PLAN_WANT_REV+=("${NEW_REV}")
  PLAN_OLD_ID+=("${OLD_ID}")
  PLAN_OLD_REV+=("${OLD_REV}")
done

# Free every name up front, walking the selection BACKWARDS. Removal is the mirror of creation: the
# bridge is created after the service because it dials it, and so must be removed before it, because
# podman refuses to remove a container that another one `--requires`. Doing this per-service inside
# the recreate loop below - service, then bridge - is what left the service's name taken, compose
# degrading to `podman start` on the old container, and the deploy shipping nothing.
for (( i = ${#PLAN[@]} - 1; i >= 0; i-- )); do
  remove_service "${PLAN[i]}"
done

for (( i = 0; i < ${#PLAN[@]}; i++ )); do
  service="${PLAN[i]}"

  # --no-deps keeps compose from walking the depends_on tree (keycloak, caddy, the stores). NOTE:
  # deliberately no --force-recreate - see landmine (1); the container is already gone in any case.
  # A single `up` may well create a later member of the selection too (compose walks the project and
  # every planned name is now free), which is harmless: its own turn then finds it already running,
  # and assert_deployed still holds it to the pulled revision.
  podman compose -f "${COMPOSE_FILE}" up -d --no-deps "${service}"

  assert_deployed "${service}" "${PLAN_WANT_REV[i]}" "${PLAN_OLD_ID[i]}"

  DEPLOYED+=("${service}:${PLAN_OLD_REV[i]:0:12}->${PLAN_WANT_REV[i]:0:12}")
done

# Undo any collateral: a diff_hashes-triggered full-project down (landmine (1), which fires after any
# edit to the compose file) can stop backing services that --no-deps then declines to bring back up,
# which would leave the stack half down behind healthy generators.
#
# This is a WAIT, not a snapshot. A hippocampus server whose Keycloak is still booting exits on the
# 502 from OIDC discovery and is restarted by podman, over and over, for as long as that takes - ~180
# times in a few seconds is normal and self-resolving. A single reading of `podman ps` lands between
# two of those restarts often enough to matter, and reports a service that is fine as one that never
# came back. So poll until the set is empty, and only call what is left after the deadline stuck.
DEADLINE=$(( SECONDS + COLLATERAL_WAIT_SECONDS ))
ANNOUNCED=" "

while :; do
  MISSING="$(missing_services)"

  if [[ -z "${MISSING}" ]]; then
    break
  fi

  for svc in ${MISSING}; do
    case "${ANNOUNCED}" in

      *" ${svc} "*)
        ;;

      *)
        echo "deploy-generators: ${svc} is down as collateral; starting it and waiting for it to settle"
        ANNOUNCED+="${svc} "
        ;;

    esac

    podman start "$(cname "${svc}")" >/dev/null 2>&1 || true
  done

  if (( SECONDS >= DEADLINE )); then
    break
  fi

  sleep "${COLLATERAL_POLL_SECONDS}"
done

# Report what actually happened rather than asserting a containment compose does not guarantee.
MISSING="$(missing_services)"

if [[ -n "${MISSING}" ]]; then
  echo "deploy-generators: WARNING - these services did not come back within ${COLLATERAL_WAIT_SECONDS}s and need attention:" >&2
  echo "${MISSING}" >&2

  exit 1
fi

if [[ ${#DEPLOYED[@]} -eq 0 ]]; then
  echo "deploy-generators: done - nothing to do; ${SKIPPED[*]} already current"

  exit 0
fi

echo "deploy-generators: done - deployed ${DEPLOYED[*]}"
