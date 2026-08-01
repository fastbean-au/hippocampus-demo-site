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
# demo/demo login); the writing is done by the hippocampus-gen service account.
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
#                            grafana. subdomains must have DNS A/AAAA records pointing at this host,
#                            with ports 80/443 reachable, for Caddy's automatic HTTPS. Also rendered
#                            into the Keycloak realm's console redirect URIs so sign-in works.
#                            Required.
#   --acme-email  <email>    Address Let's Encrypt uses for the ACME account and expiry notices.
#                            Required.
#   --gen-secret  <secret>   Secret for the hippocampus-gen client, substituted into BOTH the
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

# Note the domain from any prior install BEFORE overwriting the env file, so we can tell whether the
# base domain changed and the Keycloak realm needs re-importing (see the volume reset below).
PREV_BASE_DOMAIN=""
if [[ -f "${ENV_FILE}" ]]; then
  PREV_BASE_DOMAIN="$(sed -n 's/^BASE_DOMAIN=//p' "${ENV_FILE}" | head -n1)"
fi

# Render the Keycloak realm from the tracked template, substituting two things so the running stack
# never drifts from the realm:
#
#   1. The base domain. The template ships placeholder redirect URIs (book./logs.hippocampus.example);
#      Keycloak rejects a sign-in whose redirect_uri is not listed ("Invalid parameter:
#      redirect_uri"), so the real BASE_DOMAIN is substituted in. The 'admin@example.com' style ACME
#      default and the realm name 'hippocampus' contain no 'hippocampus.example', so the replace only
#      touches the redirect URIs (and the demo user's email domain, which is harmless).
#   2. The hippocampus-gen client secret. The generators authenticate with GEN_SECRET (passed into
#      the compose file); the realm's client secret must be the SAME value or the client-credentials
#      grant fails. Both come from GEN_SECRET here, so they always match - no second place to edit.
#      The template's secret equals the GEN_SECRET default, so the default render is a no-op for it.
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

echo "==> Writing ${ENV_FILE}"
install -d -m 0755 "${ENV_DIR}"
umask 077
cat >"${ENV_FILE}" <<EOF
# Site-specific settings for the Hippocampus combined showcase, read by the ${SERVICE_NAME} unit and
# interpolated into ${COMPOSE_FILE}. Written by install-ubuntu.sh; edit and re-run
# \`systemctl restart ${SERVICE_NAME}\` to change.
BASE_DOMAIN=${BASE_DOMAIN}
ACME_EMAIL=${ACME_EMAIL}
GEN_SECRET=${GEN_SECRET}
# Domain-rendered realm produced above, so the console redirect URIs match ${BASE_DOMAIN}.
KEYCLOAK_REALM_FILE=${REALM_RELATIVE}
EOF
umask 022

# The realm is imported into an EMPTY combined-keycloak-data volume only (start-dev --import-realm
# skips a realm that already exists), so a first boot with the placeholder domain persists the wrong
# redirect URIs. When the base domain changes (or this is a re-point of an existing box), drop the
# Keycloak volume so the freshly rendered realm re-imports. Match on the name suffix to stay robust to
# the compose project prefix. Only the demo realm + demo user live in that volume, so this is safe.
if [[ "${PREV_BASE_DOMAIN}" != "${BASE_DOMAIN}" ]]; then
  if command -v podman >/dev/null 2>&1; then
    KC_VOLUME="$(podman volume ls --format '{{.Name}}' 2>/dev/null | grep -E 'combined-keycloak-data$' | head -n1 || true)"

    if [[ -n "${KC_VOLUME}" ]]; then
      echo "==> Base domain changed (${PREV_BASE_DOMAIN:-<none>} -> ${BASE_DOMAIN}); resetting ${KC_VOLUME} so the realm re-imports"
      podman volume rm -f "${KC_VOLUME}" || true
    fi
  fi
fi

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
ExecStop=/usr/bin/podman compose -f ${COMPOSE_FILE} down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

echo "==> Enabling and starting ${SERVICE_NAME} (this builds the site image and pulls images on first run)"
systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}.service"

cat <<EOF

==> Done.

The showcase is starting and will come back up on reboot. Point DNS for these names at this host,
with 80/443 reachable, for Caddy to provision TLS:

  ${BASE_DOMAIN}, book.${BASE_DOMAIN}, logs.${BASE_DOMAIN}, auth.${BASE_DOMAIN}, grafana.${BASE_DOMAIN}

Handy commands:

  systemctl status ${SERVICE_NAME}                       # unit state
  podman compose -f ${COMPOSE_FILE} ps                   # container state (run from ${REPO_DIR})
  podman compose -f ${COMPOSE_FILE} logs -f hippocampus-gen-book
  systemctl restart ${SERVICE_NAME}                      # after editing ${ENV_FILE} or pulling updates
EOF
