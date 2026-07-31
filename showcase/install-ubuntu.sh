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
# reader-demo login); the writing is done by the hippocampus-gen service account.
#
# ARCHITECTURE: the hippocampus-gen images are published for linux/amd64 only, so this targets an
# x86-64 host. On arm64 the servers still run, but the generators will not - see docs/showcase-oci.md
# for the from-source Arm build.
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
#                            with ports 80/443 reachable, for Caddy's automatic HTTPS. Required.
#   --acme-email  <email>    Address Let's Encrypt uses for the ACME account and expiry notices.
#                            Required.
#   --gen-secret  <secret>   Secret for the hippocampus-gen client; must match the value in
#                            keycloak/realm-hippocampus.json. Defaults to the demo secret. Change it
#                            (here AND in the realm) for anything beyond a throwaway showcase.
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
  sed -n '3,35p' "$0" | sed 's/^# \{0,1\}//'
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

# The hippocampus-gen images are amd64-only; warn (don't fail) on other arches so the servers can
# still be brought up while the operator arranges an Arm generator build.
ARCH="$(uname -m)"
if [[ "$ARCH" != "x86_64" && "$ARCH" != "amd64" ]]; then
  echo "WARNING: host arch is ${ARCH}, but the hippocampus-gen images are linux/amd64 only." >&2
  echo "WARNING: the servers will run, but the generators will not - see docs/showcase-oci.md." >&2
fi

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
