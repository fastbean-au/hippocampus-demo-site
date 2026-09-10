#!/usr/bin/env bash
#
# Hold every copy of "which consoles the combined stack serves" to one another.
#
# WHY THIS EXISTS. The combined stack's console list is written down in SEVEN places, none of which
# executes any of the others, and on 2026-08-27 a console (`logs`) was retired from the stack while
# five of the seven went on describing it — including the DNS instruction install-ubuntu.sh prints
# to an operator, which named a console that no longer existed and omitted four that did. A fresh
# install following it would have left bluesky/agent/agent-flat/observer with no certificates.
#
# That is the same failure this project's upstream repo already learned once (a documentation table
# that is a second copy of a table in the code, with nothing executing it — see the alert-rule drift
# guard in the hippocampus repo), and it is the half of the drift problem a release-tag check cannot
# see: nothing shipped, no tag moved, the site repo simply changed its own deployment.
#
# THE AUTHORITY IS THE CADDYFILE. It is the only one of the seven that a visitor's request actually
# passes through, so it decides what "served" means and everything else is held to it. The checks run
# in BOTH directions, because the two failures are different: a console missing from a copy is a
# console that half-works, and a console named by a copy but served by nobody is the `logs` case.
#
#   ./showcase/check-consistency.sh          # report and exit non-zero on any disagreement
#
# It reads files only, touches no host and no container, so it is safe anywhere.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

CADDYFILE=showcase/caddy/Caddyfile.combined
COMPOSE=showcase/compose.showcase-combined.yaml
INIT_SQL=showcase/postgres/init-showcase-combined.sql
REALM=showcase/keycloak/realm-hippocampus.json
INSTALL=showcase/install-ubuntu.sh
DEPLOY=showcase/deploy-servers.sh
DOC=docs/showcase.md

# Hosts the combined stack serves that are NOT a Hippocampus console. Each is shared infrastructure
# or a static tool, so it has no database, no gRPC port and no realm redirect URI, and holding it to
# the per-console checks below would fail for reasons that are not drift.
NON_CONSOLE=(auth grafana config-builder)

# Failures are recorded in a FILE rather than a variable: the reverse checks below run their
# comparison on the right-hand side of a pipe, which bash runs in a subshell, so an incremented
# counter would be lost in a child process and the script would report every drift and then exit 0.
FAIL_LOG=$(mktemp)
trap 'rm -f "${FAIL_LOG}"' EXIT
fail() {
  printf '  ✗ %s\n' "$1" >&2
  printf '%s\n' "$1" >>"${FAIL_LOG}"
}

is_non_console() {
  local h
  for h in "${NON_CONSOLE[@]}"; do
    [[ ${1} == "${h}" ]] && return 0
  done
  return 1
}

# ---- The authority: every `<host>.{$BASE_DOMAIN...} {` site block in the Caddyfile --------------
SERVED=()
while IFS= read -r host; do
  [[ -n ${host} ]] && SERVED+=("${host}")
done < <(
  grep -oE '^[a-z][a-z0-9-]*\.\{\$BASE_DOMAIN' "${CADDYFILE}" | sed 's/\.{\$BASE_DOMAIN$//' | sort -u
)

if [[ ${#SERVED[@]} -eq 0 ]]; then
  echo "check-consistency: found no site blocks in ${CADDYFILE} — has its syntax changed?" >&2
  exit 2
fi

CONSOLES=()
for host in "${SERVED[@]}"; do
  is_non_console "${host}" || CONSOLES+=("${host}")
done

echo "Caddyfile serves ${#SERVED[@]} hosts; ${#CONSOLES[@]} of them are consoles: ${CONSOLES[*]}"
echo

# ---- Forward: every console appears in all six other copies -------------------------------------
echo "Every console is accounted for in:"
for c in "${CONSOLES[@]}"; do
  db="hippocampus_${c//-/_}"

  grep -qE "^  hippocampus-${c}:$" "${COMPOSE}" ||
    fail "${COMPOSE}: no 'hippocampus-${c}' service"

  grep -qE "^  hippocampus-${c}:$" "${COMPOSE}" &&
    ! awk -v svc="  hippocampus-${c}:" '
        $0 == svc { inside = 1; next }
        inside && /^  [a-z]/ { exit }
        inside && /:50051"$/ { found = 1; exit }
        END { exit !found }' "${COMPOSE}" &&
    fail "${COMPOSE}: 'hippocampus-${c}' publishes no gRPC port"

  grep -qi "CREATE DATABASE ${db};" "${INIT_SQL}" ||
    fail "${INIT_SQL}: no database '${db}'"

  grep -q "https://${c}\.hippocampus\.example/ui" "${REALM}" ||
    fail "${REALM}: console client has no redirect URI for '${c}' (sign-in would 400)"

  grep -qE "^\| \`${c}\.\\\$\{BASE_DOMAIN\}\`" "${DOC}" ||
    fail "${DOC}: the subdomain table has no row for '${c}'"

  grep -q "${c}\.\${BASE_DOMAIN}" "${INSTALL}" ||
    fail "${INSTALL}: the DNS instruction does not name '${c}' (no certificate for it)"

  grep -q "hippocampus-${c}" "${DEPLOY}" ||
    fail "${DEPLOY}: cannot deploy 'hippocampus-${c}'"
done
printf '  the compose services and their gRPC ports, %s,\n' "${INIT_SQL##*/}"
printf '  the realm redirect URIs, the %s subdomain table,\n' "${DOC##*/}"
printf '  the %s DNS instruction, and %s.\n\n' "${INSTALL##*/}" "${DEPLOY##*/}"

# ---- Reverse: nothing claims a console the Caddyfile does not serve ------------------------------
# This is the direction that catches a RETIRED console. Each source is scanned only where it keeps
# its own inventory of the stack, so the standalone book/logs stacks — which legitimately appear
# elsewhere in the same files — are not mistaken for drift.
echo "Nothing claims a console that is not served:"

claimed() { # <file> <extraction command output on stdin>
  while read -r name; do
    [[ -z ${name} ]] && continue
    is_non_console "${name}" && continue
    [[ ${name} == "hippocampus" ]] && continue # the apex/realm name, not a console
    local found=0 s
    for s in "${SERVED[@]}"; do [[ ${s} == "${name}" ]] && found=1; done
    [[ ${found} -eq 1 ]] || fail "$1: names '${name}', which ${CADDYFILE##*/} does not serve"
  done
}

# The Caddy container's network aliases in the compose file.
awk '/^  caddy:/ { inside = 1 } inside && /aliases:/ { grab = 1; next }
     grab && /^ *- "/ { print; next } grab { exit }' "${COMPOSE}" |
  sed -E 's/.*- "([a-z0-9-]+)\.\$\{BASE_DOMAIN.*/\1/' | claimed "${COMPOSE} (caddy aliases)"

# The databases the shared Postgres creates on first boot.
grep -oiE 'CREATE DATABASE hippocampus_[a-z_]+' "${INIT_SQL}" |
  sed -E 's/.*hippocampus_//' | tr '_' '-' | claimed "${INIT_SQL}"

# The console client's redirect URIs in the realm.
grep -oE 'https://[a-z0-9-]+\.hippocampus\.example/ui' "${REALM}" |
  sed -E 's#https://([a-z0-9-]+)\..*#\1#' | sort -u | claimed "${REALM}"

# The subdomain table in the entry-point document.
grep -oE '^\| `[a-z0-9-]+\.\$\{BASE_DOMAIN\}`' "${DOC}" |
  sed -E 's/.*`([a-z0-9-]+)\..*/\1/' | claimed "${DOC} (subdomain table)"

# The DNS instruction install-ubuntu.sh prints when it finishes.
awk '/Point DNS for these names/ { grab = 1 } grab && /^$/ && seen { exit }
     grab && /\$\{BASE_DOMAIN\}/ { seen = 1; print }' "${INSTALL}" |
  grep -oE '[a-z0-9-]+\.\$\{BASE_DOMAIN\}' | sed -E 's/\..*//' | claimed "${INSTALL} (DNS instruction)"

# The services deploy-servers.sh moves onto a new image when given no arguments.
sed -nE 's/^ *SERVICES=\(hippocampus-(.*)\)$/\1/p' "${DEPLOY}" | tr ' ' '\n' |
  sed -E 's/^hippocampus-//; s/^config-builder$/config-builder/' | claimed "${DEPLOY}"

echo "  (checked the caddy aliases, the created databases, the realm redirect URIs,"
echo "   the subdomain table, the printed DNS instruction, and the deploy list.)"
echo

FAILURES=$(wc -l <"${FAIL_LOG}" | tr -d ' ')
if [[ ${FAILURES} -ne 0 ]]; then
  echo "check-consistency: ${FAILURES} disagreement(s) — the combined stack's console list has drifted." >&2
  exit 1
fi

echo "check-consistency: all seven copies agree on ${#CONSOLES[@]} consoles."
