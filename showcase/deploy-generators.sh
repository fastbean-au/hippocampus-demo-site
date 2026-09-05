#!/usr/bin/env bash
#
# deploy-generators.sh - pull the current image for a load-bearing container and recreate ONLY that
# container, leaving every other service in the combined showcase - Caddy, the consoles, Keycloak,
# the stores, the landing site - untouched.
#
# It covers five services, in two groups:
#
#   hippocampus-gen-book / hippocampus-gen-agent / hippocampus-gen-observer   the generators (the default selection)
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
# REMOVAL RUNS IN THE OPPOSITE ORDER, and every name is freed before any of them is recreated.
# compose stamps depends_on as a podman `--requires` edge, and podman refuses to remove a container
# while something requires it - so the bridge must go first, and the service cannot be removed at all
# until it has. Interleaving the two (remove service, recreate service, remove bridge, ...) is what
# broke this script's first bluesky run: the removal was refused, the `|| true` hid it, the taken name
# sent compose down landmine (2), and the "deploy" started the old container again.
#
# WHAT COMES DOWN IS COMPUTED, NOT SELECTED. The set is the selection plus everything that
# transitively `--requires` it, discovered from podman's live edges (blast_radius), and the extras are
# torn down and put straight back on the image they already had. Before that, the `bluesky` target was
# not merely incomplete but DESTRUCTIVE: hippocampus-gen-observer requires hippocampus-bluesky and was
# in no argument this script accepted, so the teardown removed both bridges, was refused on the
# service, and exited under `set -e` with the bridges deleted and never recreated - the store's only
# reinforcement and delete consumer gone, while the apex stayed green and the run looked like a
# failed deploy rather than an outage. Use deploy-servers.sh for the bluesky SERVICE if you want only
# its image moved; this script's `bluesky` target is now safe either way.
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
# VERSION PINNING AND ROLLBACK. Every image reference in the compose file is `:latest`, so without
# --version a run ships whatever that resolves to at the moment it runs: "deploy 0.41.0" and "go back
# to 0.40.1" are both unexpressible, and assert_deployed can only confirm that SOMETHING moved, not
# that the requested thing did. `--version <tag>` redirects the pull to that tag, reads the planned
# revisions from it, and holds each container to it. It defaults to `latest`, so every existing
# invocation is unchanged.
#
# THE SELECTION SPANS TWO RELEASE TRAINS, and that is the thing to know before reaching for it here.
# hippocampus-bluesky and its two bridges come from the hippocampus repo's releases and carry real
# release numbers (0.41.0, and the rolling 0.41). The three generators come from hippocampus-gen,
# which has never been tagged: its images carry only `latest`, `main` and `sha-<commit>`. So a
# release number pins the bluesky group, a `sha-<commit>` pins a generator, and asking for a release
# number on a generator fails on the pull - loudly, during the plan, before anything is torn down.
# One --version applies to everything selected, so pinning across the two groups is two runs.
#
# A leading `v` is accepted and stripped, because the git tag an operator remembers is `v0.40.1` while
# the image tag the release publishes is `0.40.1`. A release number is additionally cross-checked
# against the pulled image's `org.opencontainers.image.version` label, so a tag resolving to a build
# other than the one it names fails rather than deploying quietly; a `sha-<commit>` tag skips that
# check, since it already names one exact build.
#
# IT WORKS BY RETAGGING LOCALLY, and that is a decision rather than a shortcut. podman-compose creates
# a container from whatever the compose file's image reference resolves to ON THIS HOST, and offers no
# per-run override; editing the YAML to name the tag would work exactly once and cost the whole stack,
# because any edit to that file fires the full-project down described above. So the requested tag is
# pulled and then `podman tag`ged onto the reference the compose file names. Two consequences, both
# wanted: this host's `:latest` stops meaning "the newest build" until something pulls it again (the
# first thing an unversioned run does, so it is not sticky), and the pin therefore SURVIVES a reboot
# or a full-stack bounce, both of which recreate every container from the local `:latest`.
#
# NEITHER BLUESKY CONTAINER LOSES DATA on a recreate - that store is in Postgres - but the bridge
# holds three things only in memory, all by design: its Jetstream cursor (a restart resumes at the
# live tip, so the gap is skipped), its capture and author indexes, and its topic-term index. The
# indexes are rebuilt by the startup feed backfill within a poll or two; the gap is simply lost, which
# is what "a stream of the present, not a ledger" means.
#
# Run as root - the showcase containers live under root podman:
#   sudo ./showcase/deploy-generators.sh                # all three generators, skipping any already current
#   sudo ./showcase/deploy-generators.sh book           # just the book generator
#   sudo ./showcase/deploy-generators.sh --force book   # recreate even if already on the pulled image
#   sudo ./showcase/deploy-generators.sh bluesky        # the bluesky service AND both bridges, in that order
#                                                       # (gen-observer requires the service, so it is recreated too)
#   sudo ./showcase/deploy-generators.sh bluesky-bridge # just the Trending News bridge (a flag change, no new service image)
#   sudo ./showcase/deploy-generators.sh bluesky-bridge-worldnews   # just the WorldNews bridge
#   sudo ./showcase/deploy-generators.sh --dry-run      # print the plan and everything the graph forces down, change nothing
#   sudo ./showcase/deploy-generators.sh --version 0.40.1 bluesky-bridge         # pin, or roll back, a bridge
#   sudo ./showcase/deploy-generators.sh --version sha-<commit> book             # the generators carry no release numbers
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
DRY_RUN=0
VERSION=latest
SERVICES=()

while [[ $# -gt 0 ]]; do
  case "$1" in

    # The image tag to deploy: a release number for the bluesky group (0.40.1, or v0.40.1 - the
    # leading v is stripped, since the git tag and the image tag differ only by it), a `sha-<commit>`
    # for a generator, or any other tag the registry carries. `latest` is the default and the
    # pre-existing behaviour. See the header on the two release trains this script spans.
    --version | --version=*)
      if [[ "$1" == --version=* ]]; then
        VERSION="${1#--version=}"
      else
        shift
        VERSION="${1:-}"
      fi

      VERSION="${VERSION#v}"

      if [[ -z "${VERSION}" ]] || [[ "${VERSION}" =~ [[:space:]/:] ]]; then
        echo "deploy-generators: ERROR - --version wants an image tag (e.g. 0.40.1), not '${VERSION}'" >&2

        exit 1
      fi
      ;;

    --force)
      FORCE=1
      ;;

    --dry-run)
      DRY_RUN=1
      ;;

    book | agent | observer)
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

    hippocampus-gen-book | hippocampus-gen-agent | \
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
      echo "deploy-generators: unknown argument '$1' (expected: book, agent, observer, bluesky, bluesky-bridge, bluesky-bridge-worldnews, --version, --force, --dry-run)" >&2

      exit 1
      ;;

  esac

  shift
done

# The default is the three generators. Recreating a SERVICE is heavier than recreating its load, so
# the bluesky group is only ever deployed when named.
if [[ ${#SERVICES[@]} -eq 0 ]]; then
  SERVICES=(hippocampus-gen-book hippocampus-gen-agent hippocampus-gen-observer)
fi

# Every container this script may touch, in CREATION order: a container appears after everything it
# requires. It does two jobs. It sorts the SELECTION into a canonical order, which also dedupes
# `bluesky bluesky-bridge` - the reason this exists rather than taking argv as given, since a bridge
# recreated before its service dials a socket that is not there and exits (see the header). And it
# sequences the wider TOUCHED set the blast radius computes below, where hippocampus-gen-observer's
# position after hippocampus-bluesky is what makes it removable first and recreated last.
ORDER=(
  hippocampus-bluesky
  hippocampus-bluesky-bridge
  hippocampus-bluesky-bridge-worldnews
  hippocampus-gen-book
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

# version_of - the human-readable release an image or container was built from, via the OCI version
# label. Empty for anything from a repo that publishes no release numbers - which is every generator
# here, so nothing may treat its absence as a fault.
version_of() {
  podman inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$1" 2>/dev/null || true
}

# is_release_number - whether a requested version names a release (0.41.0, 0.41, 0.42.0-rc.1) rather
# than an arbitrary tag. Only a release number is cross-checked against an image's version label: a
# `sha-<commit>` tag - the only way to pin a generator - already names one exact build, so there is
# nothing left for a label to confirm.
is_release_number() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?(-[0-9A-Za-z.-]+)?$ ]]
}

# pull_ref - the compose file's image reference with its tag replaced by the requested version, which
# under the default `latest` is usually the reference itself. The tag is the part after the LAST
# colon, and only when that colon follows the last slash, so a registry:port host keeps its port -
# none here uses one today, but getting that wrong would be silent rather than loud.
pull_ref() {
  local ref="$1" base tag

  base="${ref%:*}"
  tag="${ref##*:}"

  if [[ "${base}" == "${ref}" || "${tag}" == */* ]]; then
    echo "${ref}:${VERSION}"

    return 0
  fi

  echo "${base}:${VERSION}"
}

# dependents_of - the services in this project holding a podman `--requires` edge on the given
# container id: the ones podman insists are removed BEFORE it. compose stamps those edges from
# depends_on, which is why the bluesky bridge pins the bluesky service. Emits compose SERVICE names,
# not container names, because that is what blast_radius, ORDER and the selection are all keyed on.
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

# contains - whether a value appears in the remaining arguments. Explicit rather than a substring
# match, which would be wrong here: hippocampus-bluesky is a prefix of hippocampus-bluesky-bridge.
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

# blast_radius - the selection plus everything that transitively requires it: the full set of
# containers that must be removed to free the selected names. Discovered from podman's live edges
# rather than hardcoded, so a new depends_on in the compose file is picked up without editing this
# script.
#
# THIS IS THE FIX FOR THE `bluesky` TARGET, which before it was destructive rather than merely wrong.
# hippocampus-gen-observer holds a --requires on hippocampus-bluesky but was in neither the bluesky
# group nor any other argument, so no invocation could include it: the teardown removed both bridges,
# was then refused on the service, and exited under `set -e` with the bridges DELETED AND NOT
# RECREATED - taking the store's only reinforcement and delete consumer down while the apex stayed
# green. The old advice ("select those in the same run") named no argument that existed. Nothing is
# asked of the operator now; the set is computed.
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
    echo "deploy-generators: that edge is not in this script's ORDER; add it in creation order and retry." >&2
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
# and are not part of this run's TOUCHED set (those this run took down deliberately and puts back
# itself, so they are the report's business rather than the collateral loop's). Depends on
# BEFORE_RUNNING and TOUCHED, both sorted, as `comm` requires.
missing_services() {
  comm -13 <(printf '%s\n' ${TOUCHED[@]+"${TOUCHED[@]}"} | sort) \
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
  local service="$1" want_rev="$2" old_id="$3" name new_id got_rev got_version

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

  # Held to the release number first, where one was asked for, so the failure speaks in the units the
  # request was made in; the revision below is the same fact stated as an identity.
  if is_release_number "${VERSION}"; then
    got_version="$(version_of "${name}")"

    if [[ -n "${got_version}" && "${got_version}" != "${VERSION}" ]]; then
      echo "deploy-generators: ERROR - ${service} is running version ${got_version}, expected ${VERSION}." >&2

      return 1
    fi
  fi

  got_rev="$(revision_of "${name}")"

  if [[ -n "${want_rev}" && "${got_rev}" != "${want_rev}" ]]; then
    echo "deploy-generators: ERROR - ${service} is running revision ${got_rev:-<none>}, expected ${want_rev}." >&2

    return 1
  fi

  return 0
}

if [[ ${DRY_RUN} -eq 1 ]]; then
  assert_caddy_healthy || true
else
  assert_caddy_healthy
fi

BEFORE_RUNNING="$(running_services)"
DEPLOYED=()
SKIPPED=()

# The run is planned before anything is touched, so that the teardown below can work through the
# whole selection in reverse - which is the only order podman permits (see remove_service).
PLAN=()
PLAN_WANT_REV=()
PLAN_OLD_ID=()
PLAN_OLD_REV=()
PULLED=" "
PIN_FROM=()
PIN_TO=()

if [[ "${VERSION}" != "latest" ]]; then
  echo "deploy-generators: pinning to tag ${VERSION}; this host's :latest will point at it until an unversioned run pulls again."
fi

for service in "${SERVICES[@]}"; do
  IMAGE="$(image_for "${service}")"

  if [[ -z "${IMAGE}" ]]; then
    echo "deploy-generators: ERROR - no image found for ${service} in ${COMPOSE_FILE}" >&2

    exit 1
  fi

  NAME="$(cname "${service}")"
  OLD_ID="$(cid "${NAME}")"
  OLD_REV="$(revision_of "${NAME}")"

  # WANTED is what this run fetches and reads labels from; IMAGE is what compose will create the
  # container from. They are the same reference under an unversioned run and differ only in the tag
  # otherwise, and keeping them apart all the way through is what the retag below reconciles.
  WANTED="$(pull_ref "${IMAGE}")"

  # The two bridges share one image reference, so pull per DISTINCT image rather than per service.
  case "${PULLED}" in

    *" ${WANTED} "*)
      ;;

    *)
      echo "deploy-generators: pulling ${WANTED}"

      # Named rather than left to podman's own "manifest unknown", which is the most likely failure of
      # a pinned run here: a release number asked of a generator, whose repo publishes none, looks
      # exactly like this and is a bad argument rather than an infrastructure fault.
      if ! podman pull -q "${WANTED}" >/dev/null; then
        echo "deploy-generators: ERROR - could not pull ${WANTED}; is ${VERSION} a tag that image carries?" >&2

        exit 1
      fi

      PULLED+="${WANTED} "

      # A tag that resolves to a build other than the one it names fails the run HERE, while nothing
      # has been touched, rather than being discovered from a revision mismatch after the teardown.
      if is_release_number "${VERSION}"; then
        GOT_VERSION="$(version_of "${WANTED}")"

        if [[ -n "${GOT_VERSION}" && "${GOT_VERSION}" != "${VERSION}" ]]; then
          echo "deploy-generators: ERROR - ${WANTED} is labelled version ${GOT_VERSION}, not ${VERSION}." >&2

          exit 1
        fi
      fi

      if [[ "${WANTED}" != "${IMAGE}" ]]; then
        PIN_FROM+=("${WANTED}")
        PIN_TO+=("${IMAGE}")
      fi
      ;;

  esac

  NEW_REV="$(revision_of "${WANTED}")"

  # Nothing to ship: the running container is already built from the image we just pulled. Skipping
  # here is what keeps a routine run from purging the book store (see the header) for no gain.
  if [[ ${FORCE} -eq 0 && -n "${OLD_ID}" && -n "${NEW_REV}" && "${OLD_REV}" == "${NEW_REV}" ]]; then
    echo "deploy-generators: ${service} is already on ${NEW_REV:0:12}; skipping (use --force to recreate anyway)"
    SKIPPED+=("${service}")

    continue
  fi

  if [[ ${DRY_RUN} -eq 1 ]]; then
    echo "deploy-generators: would recreate ${service}"
  else
    echo "deploy-generators: recreating ${service}"
  fi

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

# The set that must actually come down: the planned services plus everything that requires them. It
# is a SUPERSET of the plan - hippocampus-gen-observer requires hippocampus-bluesky without ever
# being a thing this script deploys - and those extras are torn down and put straight back on the
# image they already had. They are collateral of the graph, not of a mistake, so they are stated.
TOUCHED=()

if [[ ${#PLAN[@]} -gt 0 ]]; then
  RADIUS="$(blast_radius "${PLAN[@]}")"

  for candidate in "${ORDER[@]}"; do
    if contains "${candidate}" ${RADIUS}; then
      TOUCHED+=("${candidate}")
    fi
  done

  # Anything podman says requires the selection but that ORDER does not name cannot be sequenced
  # safely, and guessing is how a removal gets refused halfway through with names already freed.
  for found in ${RADIUS}; do
    if ! contains "${found}" "${ORDER[@]}"; then
      echo "deploy-generators: ERROR - ${found} requires the selection but is not in ORDER." >&2
      echo "deploy-generators: add it to ORDER in creation order and retry." >&2

      exit 1
    fi
  done

  for service in "${TOUCHED[@]}"; do
    if ! contains "${service}" "${PLAN[@]}"; then
      echo "deploy-generators: NOTE - ${service} requires the selection, so it is recreated too (same image)"
    fi
  done
fi

if [[ ${DRY_RUN} -eq 1 ]]; then
  if [[ ${#TOUCHED[@]} -gt 0 ]]; then
    echo
    echo "deploy-generators: would deploy: ${PLAN[*]}"
    echo "deploy-generators: podman requires tearing down, in this order: $(printf '%s ' "${TOUCHED[@]}")"
  fi

  echo
  echo "deploy-generators: --dry-run; nothing was changed"

  exit 0
fi

# Move the compose file's image reference onto the build that was pulled. compose creates containers
# from whatever that reference resolves to here and takes no per-run override, and editing the YAML to
# name the tag would fire the full-project down (landmine (1)) - so the tag is moved locally instead,
# which is what keeps a pinned deploy as contained as an unpinned one.
#
# DELIBERATELY AFTER THE DRY-RUN EXIT AND BEFORE EVERYTHING ELSE: this is the first thing a run
# changes, and a run that then fails partway leaves the tag moved. That is the right way round - the
# operator asked for that build, and the next unversioned run pulls `:latest` back over it - but it
# does mean an abandoned deploy still decides what the next reboot brings up. It is also why this sits
# outside the `${#PLAN[@]}` guards above: a pinned run whose services are ALL already current still
# has to leave the tag where it was asked to point, or "already on 0.40.1" is true now and false after
# the next restart.
for (( i = 0; i < ${#PIN_FROM[@]}; i++ )); do
  echo "deploy-generators: tagging ${PIN_FROM[i]} as ${PIN_TO[i]}"
  podman tag "${PIN_FROM[i]}" "${PIN_TO[i]}"
done

# Free every name up front, walking the TOUCHED set BACKWARDS through ORDER. Removal is the mirror of
# creation: the bridge is created after the service because it dials it, and so must be removed
# before it, because podman refuses to remove a container that another one `--requires`. Doing this
# per-service inside the recreate loop below - service, then bridge - is what left the service's name
# taken, compose degrading to `podman start` on the old container, and the deploy shipping nothing.
for (( i = ${#TOUCHED[@]} - 1; i >= 0; i-- )); do
  remove_service "${TOUCHED[i]}"
done

# Forwards through ORDER, so a service comes back before the bridge that dials it. Only the PLANNED
# services are held to a revision: the extras pulled in by the blast radius were never pulled for, so
# asserting a revision on them would compare them against an image this run never fetched. They are
# checked for being back UP, in the report below, exactly like any other collateral.
for service in "${TOUCHED[@]}"; do
  # --no-deps keeps compose from walking the depends_on tree (keycloak, caddy, the stores). NOTE:
  # deliberately no --force-recreate - see landmine (1); the container is already gone in any case.
  # A single `up` may well create a later member of the set too (compose walks the project and every
  # touched name is now free), which is harmless: its own turn then finds it already running, and
  # assert_deployed still holds it to the pulled revision.
  podman compose -f "${COMPOSE_FILE}" up -d --no-deps "${service}"

  for (( i = 0; i < ${#PLAN[@]}; i++ )); do
    if [[ "${PLAN[i]}" != "${service}" ]]; then
      continue
    fi

    assert_deployed "${service}" "${PLAN_WANT_REV[i]}" "${PLAN_OLD_ID[i]}"

    DEPLOYED+=("${service}:${PLAN_OLD_REV[i]:0:12}->${PLAN_WANT_REV[i]:0:12}")

    break
  done
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

# Report what actually happened rather than asserting a containment compose does not guarantee. The
# TOUCHED set is checked here rather than in the collateral loop above: this run took those down on
# purpose and put them back itself, so one still down is a failure of THIS script, not something to
# be quietly restarted and waited on.
MISSING="$(missing_services)"
STUCK=()

for service in ${TOUCHED[@]+"${TOUCHED[@]}"}; do
  if [[ "$(podman inspect -f '{{.State.Running}}' "$(cname "${service}")" 2>/dev/null || true)" != "true" ]]; then
    STUCK+=("${service}")
  fi
done

if [[ ${#STUCK[@]} -gt 0 || -n "${MISSING}" ]]; then
  echo "deploy-generators: WARNING - these services are not running and need attention:" >&2
  printf '%s\n' ${STUCK[@]+"${STUCK[@]}"} ${MISSING} >&2

  exit 1
fi

if [[ ${#DEPLOYED[@]} -eq 0 ]]; then
  echo "deploy-generators: done - nothing to do; ${SKIPPED[*]} already current"

  exit 0
fi

echo "deploy-generators: done - deployed ${DEPLOYED[*]}"
