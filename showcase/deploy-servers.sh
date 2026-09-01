#!/usr/bin/env bash
#
# deploy-servers.sh - pull the images a Hippocampus release publishes and move the containers built
# from them onto it, then put back everything podman made us tear down to get there. That is the five
# SERVERS (hippocampus-book / hippocampus-bluesky / hippocampus-observer / the hippocampus-agent
# pair), which share ghcr.io/fastbean-au/hippocampus, plus config-builder, which is the same release's
# ghcr.io/fastbean-au/hippocampus-config-wizard image.
#
# WHY THIS EXISTS: nothing on this host ships a released image on its own. `podman compose up -d`
# reuses the local copy, start-generators.sh only starts existing containers, deploy-generators.sh
# covers the `-gen-*` images, deploy-site.sh covers the static landing page, and even
# `systemctl restart hippocampus-showcase` - a full-stack outage - leaves the servers on the stale
# image. Shipping a release from the hippocampus repo was therefore a hand-run pull + rm + up through
# a dependency graph that punishes getting the order wrong. This script is that sequence, verified.
#
# THE DEPENDENCY GRAPH IS THE WHOLE PROBLEM. compose stamps every depends_on as a podman `--requires`
# edge, and podman refuses to remove a container while something requires it. For the servers those
# edges run:
#
#   caddy                     --requires-->  hippocampus-book
#   hippocampus-gen-book      --requires-->  caddy, hippocampus-book
#   hippocampus-gen-agent     --requires-->  caddy, hippocampus-agent, hippocampus-agent-flat
#   hippocampus-gen-observer  --requires-->  caddy, hippocampus-observer, hippocampus-bluesky
#   hippocampus-bluesky-bridge--requires-->  caddy, hippocampus-bluesky
#   hippocampus-bluesky-bridge-worldnews
#                             --requires-->  caddy, hippocampus-bluesky
#
# BOOK IS THE EXPENSIVE ONE, and it is expensive alone: caddy requires it, and every generator and
# both bridges require caddy, so touching book tears down the entire front of the stack. Removal runs
# in reverse creation order and every name is freed before anything is recreated; bring-up runs
# forwards.
#
# EVERYTHING ELSE IS CHEAP, because nothing but a generator or a bridge requires it and caddy is not
# in the way:
#
#   agent          -> the two agent servers + hippocampus-gen-agent      (3 containers)
#   observer       -> hippocampus-observer + hippocampus-gen-observer    (2 containers)
#   bluesky        -> hippocampus-bluesky + gen-observer + both bridges  (4 containers)
#   config-builder -> config-builder                                    (1 container)
#
# All four keep the apex up and touch no store. Prefer them when a release only needs proving on one
# service. Note that gen-observer requires bluesky as well as observer, so the two overlap - naming
# both costs no more than naming either.
#
# CONFIG-BUILDER IS THE CHEAPEST THING HERE and the only one with no edges in either direction: it
# declares no depends_on and nothing declares one on it, so its blast radius is itself. It is also the
# one that was going undeployed. It is not a demo of the memory store - it is the browser config/
# deployment builder, served at config-builder.${BASE_DOMAIN} - but the release publishes its image
# alongside the server's, and until it was named here NOTHING on this host ever pulled that image: it
# moved only when a full-stack bounce happened to recreate the container. A wizard whose validation
# mirrors `validateConfig` and whose defaults mirror the service's `viper.SetDefault` list is exactly
# the thing that must not silently sit a few releases back, because what it gets wrong it gets wrong
# in a config file someone then deploys. It is in the bare form's selection for that reason.
#
# THIS LIST IS NOT WHAT THE SCRIPT ACTS ON. The set it touches is discovered from podman's live
# --requires edges at run time; the ORDER array below only fixes the sequence, and discovery fails
# loudly if it turns up a container ORDER does not name. That is what caught the logs services
# staying here after the compose file dropped them - the bare, no-argument form could not run at all.
#
# TWO COSTS ARE UNAVOIDABLE once book is in the selection, and the script states both before
# it touches anything:
#
#   1. THE BOOK STORE IS WIPED. hippocampus-gen-book has to be recreated because it requires the
#      servers, and its compose command carries `--reset` with `--loop` whose first cycle runs
#      immediately - so it purges hippocampus_book and reloads Great Expectations across its 2h pace
#      window. The book console looks sparse until that finishes. This is a consequence of the graph,
#      not a choice; the store already resets daily, so a deploy pulls that forward rather than
#      losing anything permanently. It still needs consent - see --yes.
#   2. THE APEX GOES DOWN. caddy owns :80/:443, so while it is gone every public hostname is dead -
#      the consoles, the IdP, the config wizard and the landing site alike. Expect roughly a minute.
#
# CADDY COMES BACK STUCK IN `Created` often enough to handle it here rather than leave it to whoever
# is watching the apex 502. podman creates the container and never starts it, and `podman start` does
# not reliably clear it; the fix is to remove and recreate it, which start_service does automatically
# for any container that lands in that state.
#
# THE SERVERS RESTART-LOOP UNTIL CADDY IS HEALTHY, and that is normal. They resolve the OIDC issuer
# through the front Caddy at https://auth.${BASE_DOMAIN}/realms/hippocampus and exit on its 502 rather
# than waiting, so between "servers up" and "caddy healthy" podman restarts them over and over - a
# RestartCount in the hundreds after a run is expected and self-resolving. That is also why the
# generators and the bridge are brought up only AFTER caddy reports healthy: they die on a failed
# token request and podman does not reliably restart them afterwards, which is the whole reason
# start-generators.sh exists.
#
# TWO podman-compose 1.0.6 LANDMINES this script routes around (see podman_compose.py ~2053-2069, and
# the fuller write-up in deploy-caddy.sh):
#
#   1. `--force-recreate` triggers a FULL-PROJECT down that ignores --no-deps and the named service
#      alike - the exact opposite of containment. Never passed here; containers are removed by hand.
#   2. When `podman run` hits a name already in use, compose SILENTLY degrades to `podman start
#      <name>`, reviving the OLD container - and the OLD image - while the output still reads like a
#      successful recreate. Freeing every name first makes that unreachable; assert_deployed catches
#      it regardless by comparing the running container's image revision against the pulled one.
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
# EXPECTED (ALARMING-LOOKING) OUTPUT: compose walks every service, so for each one already running you
# will see `Error: ... name is already in use` and `exit code: 125`. That is landmine (2) firing
# harmlessly - `podman start` on a running container is a no-op. Do NOT silence it with
# --force-recreate, which is landmine (1) and does bounce the stack.
#
# NO SERVER LOSES DATA on a recreate: every store is in Postgres and OpenSearch, and the config is a
# read-only bind mount. What the book store loses, it loses to the generator's --reset above.
#
# Run as root - the showcase containers live under root podman:
#   sudo ./showcase/deploy-servers.sh                      # the five servers + config-builder, skipping any already current
#   sudo ./showcase/deploy-servers.sh agent                # both agent halves + their generator; apex stays up, no wipe
#   sudo ./showcase/deploy-servers.sh bluesky              # bluesky + gen-observer + both bridges; apex stays up
#   sudo ./showcase/deploy-servers.sh config-builder       # just the config wizard; one container, no edges
#   sudo ./showcase/deploy-servers.sh book                 # the one that costs the apex and the book store
#   sudo ./showcase/deploy-servers.sh --yes                # non-interactive; required when there is no TTY
#   sudo ./showcase/deploy-servers.sh --force bluesky      # recreate even if already on the pulled image
#   sudo ./showcase/deploy-servers.sh --dry-run            # print the plan and the blast radius, change nothing
#
# Override the env file location if it is not the install default:
#   sudo SHOWCASE_ENV=/path/to/showcase.env ./showcase/deploy-servers.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/compose.showcase-combined.yaml"
CADDY_SERVICE="caddy"

# How long caddy is given to report healthy before the generators are brought up anyway, and how long
# a service knocked over as collateral is given to come back before the run calls it stuck. The health
# wait is sized for a cold Caddy re-issuing nothing (it keeps its certs in a volume); the collateral
# wait for the slow case of Keycloak booting with the servers restart-looping on its 502s.
HEALTH_WAIT_SECONDS=90
COLLATERAL_WAIT_SECONDS=90
POLL_SECONDS=3

FORCE=0
ASSUME_YES=0
DRY_RUN=0
SERVICES=()

while [[ $# -gt 0 ]]; do
  case "$1" in

    --force)
      FORCE=1
      ;;

    --yes | -y)
      ASSUME_YES=1
      ;;

    --dry-run)
      DRY_RUN=1
      ;;

    book | bluesky | agent-flat | observer)
      SERVICES+=("hippocampus-$1")
      ;;

    # The one selectable container whose compose service name carries no `hippocampus-` prefix, so it
    # is both the friendly name and the real one.
    config-builder)
      SERVICES+=("config-builder")
      ;;

    # The bare name selects BOTH halves of the agent pair. They are one demonstration - a comparison
    # between two stores - so deploying one without the other leaves the site showing a comparison
    # against a store running a different build. Name `agent-flat` explicitly to move just that half.
    agent)
      SERVICES+=("hippocampus-agent" "hippocampus-agent-flat")
      ;;

    hippocampus-book | hippocampus-bluesky | \
      hippocampus-agent | hippocampus-agent-flat | hippocampus-observer)
      SERVICES+=("$1")
      ;;

    -h | --help)
      # Print the header block itself as the usage text, stopping at the first line of code so this
      # can never drift from the documentation above.
      awk 'NR > 1 { if (!/^#/) exit; print }' "${BASH_SOURCE[0]}"

      exit 0
      ;;

    *)
      echo "deploy-servers: unknown argument '$1' (expected: book, agent, agent-flat, observer, bluesky, config-builder, --force, --yes, --dry-run)" >&2

      exit 1
      ;;

  esac

  shift
done

if [[ ${#SERVICES[@]} -eq 0 ]]; then
  SERVICES=(hippocampus-book hippocampus-agent hippocampus-agent-flat hippocampus-observer hippocampus-bluesky config-builder)
fi

# Every container this script may touch, in CREATION order: a container appears after everything it
# requires. Removal walks this backwards, bring-up walks it forwards. The set that actually gets
# touched is discovered from podman's live edges below - this list only fixes the ORDER, and the
# discovery fails loudly if it ever turns up something that is not named here.
#
# config-builder is first because it has no edges at all, in either direction - it can be removed and
# recreated at any point without reference to anything else, so the position is free and the top is
# where a reader looks for the thing nothing waits on.
ORDER=(
  config-builder
  hippocampus-book
  hippocampus-agent
  hippocampus-agent-flat
  hippocampus-observer
  hippocampus-bluesky
  caddy
  hippocampus-gen-book
  hippocampus-gen-agent
  hippocampus-gen-observer
  hippocampus-bluesky-bridge
  hippocampus-bluesky-bridge-worldnews
)

# Match the systemd unit: load BASE_DOMAIN / ACME_EMAIL / GEN_SECRET so compose interpolation uses the
# real deployment's values rather than the compose defaults (hippocampus.example). The servers stamp
# BASE_DOMAIN into HIPPOCAMPUS_AUTH_ISSUER and the bridge authenticates with GEN_SECRET, so a hand-run
# compose without these builds containers pointing at a domain that does not exist.
SHOWCASE_ENV="${SHOWCASE_ENV:-/etc/hippocampus-showcase/showcase.env}"
if [[ -f "${SHOWCASE_ENV}" ]]; then
  set -a

  # shellcheck disable=SC1090
  source "${SHOWCASE_ENV}"

  set +a
else
  echo "deploy-servers: WARNING - ${SHOWCASE_ENV} not found; compose will use its built-in defaults" >&2
fi

# podman-compose derives the project name from the compose file's directory (see start-generators.sh),
# so scope every container lookup to it - a stray container from another project is never matched.
PROJECT="$(basename "${SCRIPT_DIR}")"

# cname - the compose container name for a service in this project.
cname() {
  echo "${PROJECT}_${1}_1"
}

# cid - a container's full id, empty if it does not exist.
cid() {
  podman inspect -f '{{.Id}}' "$1" 2>/dev/null || true
}

# image_for - the image a service is pinned to, read from the compose file so this script cannot drift
# from it. Relies on the file's `  <service>:` / `    image: <ref>` shape.
image_for() {
  grep -A2 "^  ${1}:$" "${COMPOSE_FILE}" | sed -n 's/^ *image: *//p' | head -n1
}

# revision_of - the git commit an image or container was built from, via the OCI revision label the
# hippocampus workflow stamps on. This is the identity assert_deployed trusts, because the `:latest`
# tag is shared by every server and says nothing about which build is actually running.
revision_of() {
  podman inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$1" 2>/dev/null || true
}

# version_of - the human-readable release (e.g. 0.31.0), for the summary line only.
version_of() {
  podman inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$1" 2>/dev/null || true
}

# contains - whether a value appears in the remaining arguments. Kept explicit because every set
# operation below is over container names, where a substring match would be wrong (hippocampus-book
# is a prefix of nothing here today, but hippocampus-bluesky is a prefix of hippocampus-bluesky-bridge).
contains() {
  local needle="$1" item

  shift

  for item in "$@"; do
    if [[ "${item}" == "${needle}" ]]; then
      return 0
    fi
  done

  return 1
}

# dependents_of - the services in this project holding a podman `--requires` edge on the given
# container id: the ones podman insists are removed BEFORE it.
dependents_of() {
  local target="$1" name service

  if [[ -z "${target}" ]]; then
    return 0
  fi

  for name in $(podman ps -a --filter "label=io.podman.compose.project=${PROJECT}" --format '{{.Names}}'); do
    case " $(podman inspect -f '{{range .Dependencies}}{{.}} {{end}}' "${name}" 2>/dev/null) " in

      *" ${target} "*)
        service="$(podman inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' "${name}" 2>/dev/null || true)"

        if [[ -n "${service}" ]]; then
          echo "${service}"
        fi
        ;;

    esac
  done
}

# blast_radius - the selection plus everything that transitively requires it: the full set of
# containers that must be removed to free the selected servers' names. Discovered from podman rather
# than hardcoded, so a new depends_on edge in the compose file is picked up without editing this
# script - and anything outside ORDER stops the run instead of being silently mis-ordered.
blast_radius() {
  local -a queue=("$@") found=()
  local name dep

  while [[ ${#queue[@]} -gt 0 ]]; do
    name="${queue[0]}"
    queue=("${queue[@]:1}")

    if contains "${name}" ${found[@]+"${found[@]}"}; then
      continue
    fi

    found+=("${name}")

    for dep in $(dependents_of "$(cid "$(cname "${name}")")"); do
      queue+=("${dep}")
    done
  done

  printf '%s\n' ${found[@]+"${found[@]}"}
}

# wait_running - poll until a container is running, tolerating the servers' restart loop (a reading
# taken between two restarts says "not running" about a container that is fine).
wait_running() {
  local name="$1" deadline=$(( SECONDS + HEALTH_WAIT_SECONDS ))

  while :; do
    if [[ "$(podman inspect -f '{{.State.Running}}' "${name}" 2>/dev/null || true)" == "true" ]]; then
      return 0
    fi

    if (( SECONDS >= deadline )); then
      return 1
    fi

    sleep "${POLL_SECONDS}"
  done
}

# wait_healthy - poll a container's healthcheck until it passes. Services without a healthcheck return
# immediately, so this is safe to call for anything. This is the gate that keeps the generators from
# being recreated against an issuer path that is not serving yet.
wait_healthy() {
  local name="$1" deadline=$(( SECONDS + HEALTH_WAIT_SECONDS )) status

  status="$(podman inspect -f '{{.State.Health.Status}}' "${name}" 2>/dev/null || true)"

  if [[ -z "${status}" ]]; then
    return 0
  fi

  while :; do
    status="$(podman inspect -f '{{.State.Health.Status}}' "${name}" 2>/dev/null || true)"

    if [[ "${status}" == "healthy" ]]; then
      return 0
    fi

    if (( SECONDS >= deadline )); then
      echo "deploy-servers: WARNING - $(basename "${name}") is '${status}' after ${HEALTH_WAIT_SECONDS}s" >&2

      return 1
    fi

    sleep "${POLL_SECONDS}"
  done
}

# remove_service - free a service's container name so the recreate cannot degrade to `podman start`
# (landmine (2)). The refusal is NOT swallowed: swallowing it is exactly how a stale container
# survives an otherwise "successful" deploy. Callers work in reverse creation order, so anything still
# blocking here is outside the computed blast radius, and is named in the error.
remove_service() {
  local service="$1" name id blockers

  name="$(cname "${service}")"
  id="$(cid "${name}")"

  if [[ -z "${id}" ]]; then
    return 0
  fi

  if podman rm -f "${name}" >/dev/null 2>&1; then
    echo "deploy-servers: removed ${service}"

    return 0
  fi

  blockers="$(dependents_of "${id}" | tr '\n' ' ')"

  echo "deploy-servers: ERROR - podman refused to remove ${name}." >&2

  if [[ -n "${blockers}" ]]; then
    echo "deploy-servers: it is --require'd by: ${blockers}" >&2
    echo "deploy-servers: that edge is not in this script's ORDER; add it and retry." >&2
  fi

  return 1
}

# start_service - recreate one container and make sure it is actually up. Handles the `Created`
# deadlock described in the header: podman occasionally creates the container without starting it,
# and `podman start` does not reliably clear that, so the container is removed and recreated once.
start_service() {
  local service="$1" name state

  name="$(cname "${service}")"

  # --no-deps keeps compose from walking the depends_on tree (keycloak, the stores, and - for the
  # generators - caddy). Deliberately no --force-recreate: see landmine (1). The name is already free.
  podman compose -f "${COMPOSE_FILE}" up -d --no-deps "${service}" >/dev/null 2>&1 || true

  state="$(podman inspect -f '{{.State.Status}}' "${name}" 2>/dev/null || true)"

  if [[ "${state}" == "created" ]]; then
    echo "deploy-servers: ${service} landed in 'Created'; removing and recreating it"
    podman rm -f "${name}" >/dev/null 2>&1 || true
    podman compose -f "${COMPOSE_FILE}" up -d --no-deps "${service}" >/dev/null 2>&1 || true
  fi

  if ! wait_running "${name}"; then
    echo "deploy-servers: ERROR - ${service} is not running after ${HEALTH_WAIT_SECONDS}s; last output:" >&2
    podman logs --tail 20 "${name}" 2>&1 | sed 's/^/  /' >&2

    return 1
  fi

  return 0
}

# assert_deployed - prove the recreate actually took: a container that exists, is a DIFFERENT
# container than before, and carries the revision of the image just pulled. The revision check is what
# catches landmine (2), where a silent `podman start` leaves the old image in place while every
# preceding log line claims success.
assert_deployed() {
  local service="$1" want_rev="$2" old_id="$3" name new_id got_rev

  name="$(cname "${service}")"
  new_id="$(cid "${name}")"

  if [[ -z "${new_id}" ]]; then
    echo "deploy-servers: ERROR - ${service} does not exist after the recreate." >&2

    return 1
  fi

  if [[ -n "${old_id}" && "${new_id}" == "${old_id}" ]]; then
    echo "deploy-servers: ERROR - ${service} was restarted, not recreated (id unchanged ${new_id:0:12})." >&2
    echo "deploy-servers: it is still on the old image." >&2

    return 1
  fi

  got_rev="$(revision_of "${name}")"

  if [[ -n "${want_rev}" && "${got_rev}" != "${want_rev}" ]]; then
    echo "deploy-servers: ERROR - ${service} is running revision ${got_rev:-<none>}, expected ${want_rev}." >&2

    return 1
  fi

  return 0
}

# running_services - the compose service name of every RUNNING container in this project, sorted.
running_services() {
  podman ps \
    --filter "label=io.podman.compose.project=${PROJECT}" \
    --format '{{ index .Labels "com.docker.compose.service"}}' | sort
}

# ---- plan ---------------------------------------------------------------------------------------
#
# Everything is decided before anything is touched, so the confirmation below can state the true cost
# and the teardown can work through the whole set in one pass.

PLAN=()
PLAN_WANT_REV=()
PLAN_OLD_ID=()
PLAN_OLD_REV=()
SKIPPED=()
PULLED=" "

for service in "${SERVICES[@]}"; do
  IMAGE="$(image_for "${service}")"

  if [[ -z "${IMAGE}" ]]; then
    echo "deploy-servers: ERROR - no image found for ${service} in ${COMPOSE_FILE}" >&2

    exit 1
  fi

  # The five servers share one image reference and config-builder has its own, so pull per DISTINCT
  # image rather than per service - a bare run pulls twice, not six times.
  case "${PULLED}" in

    *" ${IMAGE} "*)
      ;;

    *)
      echo "deploy-servers: pulling ${IMAGE}"
      podman pull -q "${IMAGE}" >/dev/null
      PULLED+="${IMAGE} "
      ;;

  esac

  NAME="$(cname "${service}")"
  OLD_ID="$(cid "${NAME}")"
  OLD_REV="$(revision_of "${NAME}")"
  NEW_REV="$(revision_of "${IMAGE}")"

  # Nothing to ship: the running container is already built from the image just pulled. Skipping here
  # is what keeps a routine run from taking the apex down and wiping the book store for no gain.
  if [[ ${FORCE} -eq 0 && -n "${OLD_ID}" && -n "${NEW_REV}" && "${OLD_REV}" == "${NEW_REV}" ]]; then
    echo "deploy-servers: ${service} is already on ${NEW_REV:0:12}; skipping (use --force to recreate anyway)"
    SKIPPED+=("${service}")

    continue
  fi

  PLAN+=("${service}")
  PLAN_WANT_REV+=("${NEW_REV}")
  PLAN_OLD_ID+=("${OLD_ID}")
  PLAN_OLD_REV+=("${OLD_REV}")
done

if [[ ${#PLAN[@]} -eq 0 ]]; then
  echo "deploy-servers: done - nothing to do; ${SKIPPED[*]:-everything} already current"

  exit 0
fi

# The set that must actually be torn down: the planned servers plus everything requiring them.
RADIUS="$(blast_radius "${PLAN[@]}")"
TOUCHED=()

for candidate in "${ORDER[@]}"; do
  if contains "${candidate}" ${RADIUS}; then
    TOUCHED+=("${candidate}")
  fi
done

# Anything podman says depends on the selection but that ORDER does not name cannot be sequenced
# safely, and guessing is how the removal gets refused halfway through. Stop instead.
for found in ${RADIUS}; do
  if ! contains "${found}" "${ORDER[@]}"; then
    echo "deploy-servers: ERROR - ${found} requires the selection but is not in ORDER." >&2
    echo "deploy-servers: add it to ORDER in creation order and retry." >&2

    exit 1
  fi
done

WANT_VERSION="$(version_of "$(image_for "${PLAN[0]}")")"

echo
echo "deploy-servers: deploying ${WANT_VERSION:-the pulled image} to: ${PLAN[*]}"
echo "deploy-servers: podman requires tearing down, in this order: $(printf '%s ' "${TOUCHED[@]}")"

DESTRUCTIVE=0

if contains "${CADDY_SERVICE}" "${TOUCHED[@]}"; then
  echo "deploy-servers: THE APEX WILL BE DOWN for roughly a minute - every public hostname, including the landing site."
  DESTRUCTIVE=1
fi

if contains "hippocampus-gen-book" "${TOUCHED[@]}"; then
  echo "deploy-servers: THE BOOK STORE WILL BE PURGED - gen-book's --reset runs on recreate; it reloads over ~2h."
  DESTRUCTIVE=1
fi

echo

if [[ ${DRY_RUN} -eq 1 ]]; then
  echo "deploy-servers: --dry-run; nothing was changed"

  exit 0
fi

# Consent is required only when the graph forces a cost beyond the selection itself - so a bluesky
# deploy, which touches nothing but its own pair, never stops to ask.
if [[ ${DESTRUCTIVE} -eq 1 && ${ASSUME_YES} -eq 0 ]]; then
  if [[ ! -t 0 ]]; then
    echo "deploy-servers: ERROR - refusing to proceed without a TTY; pass --yes to accept the above." >&2

    exit 1
  fi

  read -r -p "deploy-servers: proceed? [y/N] " reply

  if [[ ! "${reply}" =~ ^[Yy]$ ]]; then
    echo "deploy-servers: aborted; nothing was changed"

    exit 1
  fi
fi

BEFORE_RUNNING="$(running_services)"

# ---- teardown -----------------------------------------------------------------------------------
#
# Free every name up front, walking the set BACKWARDS through ORDER. Removal is the mirror of
# creation: the generators and the bridge are created after caddy because they require it, and so must
# be removed before it; caddy in turn goes before the servers it requires. Interleaving removal with
# recreation is what leaves a name taken and sends compose down landmine (2).

for (( i = ${#TOUCHED[@]} - 1; i >= 0; i-- )); do
  remove_service "${TOUCHED[i]}"
done

# ---- bring-up -----------------------------------------------------------------------------------
#
# Forwards through ORDER, so the servers come back before caddy and caddy before its consumers. Each
# container is waited on before the next is started - and because wait_healthy blocks on caddy's
# healthcheck, the generators are only recreated once the issuer path is actually serving.

DEPLOYED=()

for service in "${TOUCHED[@]}"; do
  echo "deploy-servers: recreating ${service}"

  start_service "${service}"
  wait_healthy "$(cname "${service}")" || true
done

# Verify only the servers this run set out to deploy. The torn-down collaterals are checked for being
# up, not for carrying a particular revision - deploy-generators.sh owns their images.
for (( i = 0; i < ${#PLAN[@]}; i++ )); do
  service="${PLAN[i]}"

  assert_deployed "${service}" "${PLAN_WANT_REV[i]}" "${PLAN_OLD_ID[i]}"

  DEPLOYED+=("${service}:${PLAN_OLD_REV[i]:0:12}->${PLAN_WANT_REV[i]:0:12}")
done

# ---- collateral ---------------------------------------------------------------------------------
#
# Undo anything the stack lost that this run did not intend to touch: a diff_hashes-triggered
# full-project down (landmine (1), which fires after any edit to the compose file) can stop backing
# services that --no-deps then declines to bring back up.
#
# This is a WAIT, not a snapshot, for the reason in the header: a server restart-looping on a booting
# Keycloak's 502s is regularly caught between restarts by a single reading of `podman ps`, which
# reports a service that is fine as one that never came back.

DEADLINE=$(( SECONDS + COLLATERAL_WAIT_SECONDS ))
ANNOUNCED=" "

while :; do
  MISSING="$(comm -13 <(printf '%s\n' "${TOUCHED[@]}" | sort) \
    <(comm -23 <(echo "${BEFORE_RUNNING}") <(running_services)))"

  if [[ -z "${MISSING}" ]]; then
    break
  fi

  for svc in ${MISSING}; do
    case "${ANNOUNCED}" in

      *" ${svc} "*)
        ;;

      *)
        echo "deploy-servers: ${svc} is down as collateral; starting it and waiting for it to settle"
        ANNOUNCED+="${svc} "
        ;;

    esac

    podman start "$(cname "${svc}")" >/dev/null 2>&1 || true
  done

  if (( SECONDS >= DEADLINE )); then
    break
  fi

  sleep "${POLL_SECONDS}"
done

# ---- report -------------------------------------------------------------------------------------

STUCK=()

for service in "${TOUCHED[@]}"; do
  if [[ "$(podman inspect -f '{{.State.Running}}' "$(cname "${service}")" 2>/dev/null || true)" != "true" ]]; then
    STUCK+=("${service}")
  fi
done

MISSING="$(comm -13 <(printf '%s\n' "${TOUCHED[@]}" | sort) \
  <(comm -23 <(echo "${BEFORE_RUNNING}") <(running_services)))"

if [[ ${#STUCK[@]} -gt 0 || -n "${MISSING}" ]]; then
  echo "deploy-servers: WARNING - these services are not running and need attention:" >&2
  printf '%s\n' ${STUCK[@]+"${STUCK[@]}"} ${MISSING} >&2

  exit 1
fi

echo
echo "deploy-servers: done - deployed ${DEPLOYED[*]}"

if [[ ${#SKIPPED[@]} -gt 0 ]]; then
  echo "deploy-servers: skipped (already current) ${SKIPPED[*]}"
fi

if contains "hippocampus-gen-book" "${TOUCHED[@]}"; then
  echo "deploy-servers: NOTE - the book store is reloading; that console stays sparse for ~2h"
fi
