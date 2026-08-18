#!/usr/bin/env bash
#
# install-ubuntu.sh - install and start the Hippocampus combined showcase on a fresh Ubuntu 24.04
# (minimal) host, and arrange for it to come back up automatically on reboot.
#
# It installs a container engine (Podman + the compose provider), records the two site-specific
# settings - the base domain and the ACME email - in an environment file, and registers a systemd
# system unit that runs `podman compose ... up -d` for the combined stack at boot. The per-container
# `restart: unless-stopped` policy handles crashes; the systemd unit handles reboots.
#
# The combined stack is fully self-driving: it brings up the landing site, both consoles, the shared
# Keycloak / Grafana, the data stores, AND the containerised data generators that feed them, so there
# is nothing else to run. Visitors who sign in to a console are read-only (the realm ships a single
# demo/demo login); the writing is done by two service accounts - hippocampus-gen for the
# generators and hippocampus-bluesky-bridge for the Bluesky bridge, which is a separate client so
# that the bridge is identifiable in the consoles' Deployment tab rather than merged with them.
#
# ARCHITECTURE: every image (servers, sidecars, and generators) is published multi-arch, so this runs
# on both linux/amd64 and linux/arm64 hosts.
#
# Usage (run as root, from a checkout of this repository):
#
#   sudo ./showcase/install-ubuntu.sh \
#     --base-domain hippocampus.example \
#     --acme-email  you@example.com
#
# Options:
#   --base-domain <domain>   Parent domain for the showcase. The apex plus the book./logs./auth./
#                            grafana./config-builder. subdomains must have DNS A/AAAA records
#                            pointing at this host,
#                            with ports 80/443 reachable, for Caddy's automatic HTTPS. Also rendered
#                            into the Keycloak realm's console redirect URIs so sign-in works.
#                            Required.
#   --acme-email  <email>    Address Let's Encrypt uses for the ACME account and expiry notices.
#                            Required.
#   --gen-secret  <secret>   Secret for the two machine-to-machine clients (hippocampus-gen and
#                            hippocampus-bluesky-bridge, which share it), substituted into BOTH the
#                            generators and the rendered realm so they always match. Matches
#                            [A-Za-z0-9._~+=/-]+. Defaults to the demo secret; change it for real use.
#   -h, --help               Show this help and exit.
#
set -euo pipefail

SERVICE_NAME="hippocampus-showcase"
ENV_DIR="/etc/hippocampus-showcase"
ENV_FILE="${ENV_DIR}/showcase.env"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
COMPOSE_FILE="showcase/compose.showcase-combined.yaml"
# Records the sha256 of the realm JSON currently imported into Keycloak, so a re-run can tell whether
# the rendered realm actually changed (domain, gen secret, or a template edit) and needs re-importing.
IMPORTED_REALM_HASH_FILE="${ENV_DIR}/realm-imported.sha256"

BASE_DOMAIN=""
ACME_EMAIL=""
GEN_SECRET="showcase-gen-secret-change-me"

die() {
  echo "ERROR: $*" >&2

  exit 1
}

usage() {
  # Print the leading comment block (the lines between the shebang and `set -euo pipefail`) as help.
  sed -n '3,36p' "$0" | sed 's/^# \{0,1\}//'
}

# Resolve THIS stack's Keycloak volume, so a reset never touches an unrelated one (a host can carry
# leftover *_combined-keycloak-data volumes from earlier project names). The compose project defaults
# to the basename of the compose file's directory (confirmed: `showcase`), so the volume is
# `<project>_combined-keycloak-data`. Sets the global KC_VOLUME_RESOLVED and returns: 0 = resolved,
# 1 = none exists yet (fresh host), 2 = the derived name is absent and the suffix is ambiguous (the
# caller must abort rather than guess). NOTE: called via `if resolve_kc_volume`, never in a `$(...)`
# subshell, so its non-zero returns reach the caller. Requires podman and SCRIPT_DIR to be set.
KC_VOLUME_RESOLVED=""
resolve_kc_volume() {
  local project derived matches
  project="$(basename "${SCRIPT_DIR}")"
  derived="${project}_combined-keycloak-data"
  KC_VOLUME_RESOLVED=""

  if podman volume exists "${derived}" 2>/dev/null; then
    KC_VOLUME_RESOLVED="${derived}"

    return 0
  fi

  # Derived name absent: fall back to any compose keycloak volume, but only if it is unambiguous.
  matches=()
  mapfile -t matches < <(podman volume ls --format '{{.Name}}' 2>/dev/null | grep -E '_combined-keycloak-data$' || true)

  case "${#matches[@]}" in

    0)
      return 1
      ;;

    1)
      KC_VOLUME_RESOLVED="${matches[0]}"

      return 0
      ;;

    *)
      return 2
      ;;

  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in

    --base-domain)
      BASE_DOMAIN="${2:-}"
      shift 2
      ;;

    --acme-email)
      ACME_EMAIL="${2:-}"
      shift 2
      ;;

    --gen-secret)
      GEN_SECRET="${2:-}"
      shift 2
      ;;

    -h | --help)
      usage

      exit 0
      ;;

    *)
      die "unknown option: $1 (try --help)"
      ;;

  esac
done

[[ $EUID -eq 0 ]] || die "run as root (e.g. with sudo) - it writes ${UNIT_FILE}."
[[ -n "$BASE_DOMAIN" ]] || die "--base-domain is required (try --help)."
[[ -n "$ACME_EMAIL" ]] || die "--acme-email is required (try --help)."

# The gen secret is substituted verbatim into the rendered realm JSON (below), so constrain it to
# characters that are safe both as a sed replacement and inside a JSON string - no quotes, backslash,
# ampersand, pipe, or whitespace. This keeps the render simple and total; loosen it only alongside a
# JSON-aware injector. The generated demo default satisfies it.
[[ "$GEN_SECRET" =~ ^[A-Za-z0-9._~+=/-]+$ ]] ||
  die "--gen-secret must match [A-Za-z0-9._~+=/-]+ (it is injected into the realm JSON)."

# Resolve the repository root from this script's location (showcase/install-ubuntu.sh -> repo root),
# so the systemd unit gets an absolute WorkingDirectory and the compose build context resolves.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

[[ -f "${REPO_DIR}/${COMPOSE_FILE}" ]] ||
  die "expected ${COMPOSE_FILE} under ${REPO_DIR}; run this from a checkout of the repository."

echo "==> Installing Podman and the compose provider"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends podman podman-compose

# Render the Keycloak realm from the tracked template, substituting two things so the running stack
# never drifts from the realm:
#
#   1. The base domain. The template ships placeholder redirect URIs (bluesky./book./logs.hippocampus.example);
#      Keycloak rejects a sign-in whose redirect_uri is not listed ("Invalid parameter:
#      redirect_uri"), so the real BASE_DOMAIN is substituted in. The 'admin@example.com' style ACME
#      default and the realm name 'hippocampus' contain no 'hippocampus.example', so the replace only
#      touches the redirect URIs (and the demo user's email domain, which is harmless).
#   2. The machine-to-machine client secret. The generators and the Bluesky bridge authenticate with
#      GEN_SECRET (passed into the compose file); the realm's client secrets must be the SAME value
#      or the client-credentials grant fails. Both come from GEN_SECRET here, so they always match -
#      no second place to edit. The template's secret equals the GEN_SECRET default, so the default
#      render is a no-op for it. The two clients deliberately SHARE the secret: they differ by
#      client_id (which is what the topology view identifies a caller by) and by role (admin vs
#      writer), and a second secret in the same env file on the same host would separate nothing.
#
# The generated file is pointed at via KEYCLOAK_REALM_FILE; its path in the env file is relative to
# the compose file's directory (showcase/), matching the other realm mount.
REALM_TEMPLATE="${SCRIPT_DIR}/keycloak/realm-hippocampus.json"
REALM_GENERATED="${SCRIPT_DIR}/keycloak/realm-hippocampus.generated.json"
REALM_RELATIVE="./keycloak/realm-hippocampus.generated.json"
REALM_PLACEHOLDER_SECRET="showcase-gen-secret-change-me"

[[ -f "${REALM_TEMPLATE}" ]] || die "expected realm template at ${REALM_TEMPLATE}."

echo "==> Rendering ${REALM_GENERATED} for base domain ${BASE_DOMAIN}"
sed \
  -e "s|hippocampus\.example|${BASE_DOMAIN}|g" \
  -e "s|${REALM_PLACEHOLDER_SECRET}|${GEN_SECRET}|g" \
  "${REALM_TEMPLATE}" >"${REALM_GENERATED}"

# Decide whether Keycloak needs to RE-import. --import-realm only imports into an empty volume and
# skips a realm that already exists, so a changed realm (new domain, new gen secret, or a template
# edit) will not take effect on a re-run unless we drop the volume. Compare the freshly rendered realm
# against the hash of what was last imported (recorded after a successful start below) rather than
# against the base domain alone - that catches every kind of change, and a plain re-run with no change
# resets nothing. The reset itself happens in the apply phase, once the stack is down.
NEW_REALM_HASH="$(sha256sum "${REALM_GENERATED}" | awk '{print $1}')"
PREV_IMPORTED_HASH=""
if [[ -f "${IMPORTED_REALM_HASH_FILE}" ]]; then
  PREV_IMPORTED_HASH="$(cat "${IMPORTED_REALM_HASH_FILE}")"
fi

REALM_CHANGED=0
if [[ "${NEW_REALM_HASH}" != "${PREV_IMPORTED_HASH}" ]]; then
  REALM_CHANGED=1
fi

# Render the Grafana dashboard the same way, for the same reason: a visitor who follows the landing
# page's Grafana link lands on this dashboard (it is Grafana's configured home dashboard) inside a
# whole other app, with nothing to bring them back. A Grafana dashboard link is the way back, and it
# needs an absolute URL - so the tracked dashboard ships an empty "links": [] and the real
# BASE_DOMAIN is filled in here. Leaving it empty in the tracked file (rather than shipping a
# hippocampus.example placeholder link) means a hand run, and the standalone book/logs stacks that
# have no landing page at all, get NO link instead of a dead one.
#
# The link is kept on one line so this stays a plain sed substitution; the generated file is
# gitignored, so its formatting does not matter.
DASHBOARD_TEMPLATE="${SCRIPT_DIR}/observability/hippocampus-dashboard.json"
DASHBOARD_GENERATED="${SCRIPT_DIR}/observability/hippocampus-dashboard.generated.json"
DASHBOARD_RELATIVE="./observability/hippocampus-dashboard.generated.json"

[[ -f "${DASHBOARD_TEMPLATE}" ]] || die "expected dashboard template at ${DASHBOARD_TEMPLATE}."

DASHBOARD_LINK="{\"asDropdown\":false,\"icon\":\"external link\",\"includeVars\":false,\"keepTime\":false,\"tags\":[],\"targetBlank\":false,\"title\":\"Back to ${BASE_DOMAIN}\",\"tooltip\":\"Return to the Hippocampus landing page\",\"type\":\"link\",\"url\":\"https://${BASE_DOMAIN}\"}"

echo "==> Rendering ${DASHBOARD_GENERATED} with a link back to https://${BASE_DOMAIN}"
sed \
  -e "s|\"links\": \[\]|\"links\": [${DASHBOARD_LINK}]|" \
  "${DASHBOARD_TEMPLATE}" >"${DASHBOARD_GENERATED}"

grep -q "https://${BASE_DOMAIN}" "${DASHBOARD_GENERATED}" ||
  die "rendered dashboard has no landing-page link; the tracked template's \"links\": [] is missing."

echo "==> Writing ${ENV_FILE}"
install -d -m 0755 "${ENV_DIR}"
umask 077
cat >"${ENV_FILE}" <<EOF
# Site-specific settings for the Hippocampus combined showcase, read by the ${SERVICE_NAME} unit and
# interpolated into ${COMPOSE_FILE}. Written by install-ubuntu.sh; to change the domain or gen secret
# re-run install-ubuntu.sh (it re-renders the realm and re-imports it when needed) rather than editing
# here - a bare \`systemctl restart\` would not re-render or re-import the realm.
BASE_DOMAIN=${BASE_DOMAIN}
ACME_EMAIL=${ACME_EMAIL}
GEN_SECRET=${GEN_SECRET}
# Domain-rendered realm produced above, so the console redirect URIs match ${BASE_DOMAIN}.
KEYCLOAK_REALM_FILE=${REALM_RELATIVE}
# Domain-rendered dashboard produced above, so Grafana's home dashboard carries a link back to the
# landing page at ${BASE_DOMAIN}.
GRAFANA_DASHBOARD_FILE=${DASHBOARD_RELATIVE}
EOF
umask 022

echo "==> Writing ${UNIT_FILE}"
cat >"${UNIT_FILE}" <<EOF
[Unit]
Description=Hippocampus combined showcase (podman compose)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${REPO_DIR}
EnvironmentFile=${ENV_FILE}
# Bring the whole stack (site + consoles + IdP + generators) up; build the site image on first run
# and reuse the cached layers thereafter. Give the build/pull as long as it needs on a cold start.
ExecStart=/usr/bin/podman compose -f ${COMPOSE_FILE} up -d --build
# After the stack is up, wait for the auth path to serve and (re)start the data generators. up -d does
# not honour their depends_on health conditions and podman does not reliably restart them after their
# cold-start failure, so this closes the generator race. See showcase/start-generators.sh.
ExecStartPost=/usr/bin/bash ${REPO_DIR}/showcase/start-generators.sh ${COMPOSE_FILE}
ExecStop=/usr/bin/podman compose -f ${COMPOSE_FILE} down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service"

# Force the config to APPLY. The unit is a oneshot with RemainAfterExit, so on an already-running host
# `enable --now` would be a no-op and the new compose/env/realm would never take effect. Bring the
# stack down first (so the new config re-applies and the Keycloak volume is free), reset that volume
# when the rendered realm changed, then start. On a fresh host the stop is a harmless no-op.
echo "==> Stopping ${SERVICE_NAME} if running, to apply the new configuration"
systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true

if [[ "${REALM_CHANGED}" -eq 1 ]]; then
  if resolve_kc_volume; then
    echo "==> Rendered realm changed; resetting ${KC_VOLUME_RESOLVED} so Keycloak re-imports it"
    podman volume rm -f "${KC_VOLUME_RESOLVED}"
  else
    rc=$?

    if [[ "${rc}" -eq 2 ]]; then
      die "cannot tell which Keycloak volume is this stack's; remove the stale *_combined-keycloak-data volume(s) and re-run."
    fi

    echo "==> Rendered realm changed; no existing Keycloak volume to reset (fresh host) - it will import on first start"
  fi
fi

echo "==> Starting ${SERVICE_NAME} (this builds the site image and pulls images on first run)"
systemctl start "${SERVICE_NAME}.service"

# Record the realm that is now imported, so the next re-run only resets the volume when it truly
# changes. Written after a successful start so a failed start does not claim a phantom import.
echo "${NEW_REALM_HASH}" >"${IMPORTED_REALM_HASH_FILE}"

cat <<EOF

==> Done.

The showcase is starting and will come back up on reboot. Point DNS for these names at this host,
with 80/443 reachable, for Caddy to provision TLS:

  ${BASE_DOMAIN}, book.${BASE_DOMAIN}, logs.${BASE_DOMAIN}, auth.${BASE_DOMAIN}, grafana.${BASE_DOMAIN},
  config-builder.${BASE_DOMAIN}

Handy commands:

  systemctl status ${SERVICE_NAME}                       # unit state
  podman compose -f ${COMPOSE_FILE} ps                   # container state (run from ${REPO_DIR})
  podman compose -f ${COMPOSE_FILE} logs -f hippocampus-gen-book
  sudo ./showcase/install-ubuntu.sh --base-domain ... --acme-email ...   # re-apply after pulling
                                                         # updates or changing the domain/gen secret
                                                         # (re-renders + re-imports the realm as needed)
EOF
