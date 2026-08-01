#!/usr/bin/env bash
#
# uninstall-ubuntu.sh - stop the Hippocampus combined showcase and undo what install-ubuntu.sh set up
# on an Ubuntu 24.04 host.
#
# It reverses the installer step for step: it stops and disables the systemd unit, brings the combined
# stack down with `podman compose ... down`, then removes the unit file and the environment directory.
# By default it leaves the pulled/built images, the named volumes (Postgres, OpenSearch, Keycloak,
# Grafana, Caddy data), and the Podman/compose packages in place, so a later re-install comes back
# quickly and with its data intact. Flags opt into the more destructive cleanups.
#
# ARCHITECTURE: this only touches host state the installer created; the container images themselves are
# multi-arch and untouched unless --remove-images is given.
#
# Usage (run as root, from a checkout of this repository):
#
#   sudo ./showcase/uninstall-ubuntu.sh
#
# Options:
#   --remove-volumes         Also delete the stack's named volumes (`down --volumes`). THIS DESTROYS
#                            all showcase data - Postgres databases, OpenSearch indices, the Keycloak
#                            realm state, Grafana, and Caddy's provisioned TLS certificates. Off by
#                            default.
#   --remove-images          Also remove the images the stack pulled/built (`down --rmi all`, plus the
#                            locally built hippocampus-site image). Off by default.
#   --remove-packages        Also apt-get purge podman and podman-compose. Only do this if nothing else
#                            on the host uses them. Off by default.
#   -h, --help               Show this help and exit.
#
set -euo pipefail

SERVICE_NAME="hippocampus-showcase"
ENV_DIR="/etc/hippocampus-showcase"
ENV_FILE="${ENV_DIR}/showcase.env"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
COMPOSE_FILE="showcase/compose.showcase-combined.yaml"

REMOVE_VOLUMES=0
REMOVE_IMAGES=0
REMOVE_PACKAGES=0

die() {
  echo "ERROR: $*" >&2

  exit 1
}

usage() {
  # Print the leading comment block (the lines between the shebang and `set -euo pipefail`) as help.
  sed -n '3,29p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in

    --remove-volumes)
      REMOVE_VOLUMES=1
      shift
      ;;

    --remove-images)
      REMOVE_IMAGES=1
      shift
      ;;

    --remove-packages)
      REMOVE_PACKAGES=1
      shift
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

[[ $EUID -eq 0 ]] || die "run as root (e.g. with sudo) - it removes ${UNIT_FILE}."

# Resolve the repository root from this script's location (showcase/uninstall-ubuntu.sh -> repo root),
# so `podman compose ... down` runs against the same compose file the installer used.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "==> Stopping and disabling ${SERVICE_NAME}"
if systemctl list-unit-files "${SERVICE_NAME}.service" >/dev/null 2>&1 &&
  [[ -n "$(systemctl list-unit-files "${SERVICE_NAME}.service" --no-legend 2>/dev/null)" ]]; then
  systemctl disable --now "${SERVICE_NAME}.service" || true
else
  echo "    ${SERVICE_NAME}.service not registered; skipping."
fi

# Bring the stack down directly too, in case it was started by hand rather than by the unit. Assemble
# the `down` flags from the destructive options, then run it against the combined compose file.
DOWN_ARGS=(down --remove-orphans)
if [[ "$REMOVE_VOLUMES" -eq 1 ]]; then
  DOWN_ARGS+=(--volumes)
fi
if [[ "$REMOVE_IMAGES" -eq 1 ]]; then
  DOWN_ARGS+=(--rmi all)
fi

if [[ -f "${REPO_DIR}/${COMPOSE_FILE}" ]]; then
  echo "==> Bringing the combined stack down (podman compose ${DOWN_ARGS[*]})"

  # Feed the recorded settings back in so the compose file interpolates without warnings; the values
  # do not matter for a teardown, but an absent env file would leave BASE_DOMAIN et al. unset.
  ENV_ARG=()
  if [[ -f "${ENV_FILE}" ]]; then
    ENV_ARG=(--env-file "${ENV_FILE}")
  fi

  ( cd "${REPO_DIR}" && podman compose "${ENV_ARG[@]}" -f "${COMPOSE_FILE}" "${DOWN_ARGS[@]}" ) ||
    echo "    compose down reported an error (already down?); continuing."
else
  echo "==> ${COMPOSE_FILE} not found under ${REPO_DIR}; skipping compose down."
fi

echo "==> Removing ${UNIT_FILE}"
rm -f "${UNIT_FILE}"
systemctl daemon-reload
systemctl reset-failed "${SERVICE_NAME}.service" 2>/dev/null || true

echo "==> Removing ${ENV_DIR}"
rm -rf "${ENV_DIR}"

if [[ "$REMOVE_PACKAGES" -eq 1 ]]; then
  echo "==> Purging podman and podman-compose"
  export DEBIAN_FRONTEND=noninteractive
  apt-get purge -y podman podman-compose || true
  apt-get autoremove -y || true
fi

cat <<EOF

==> Done.

The ${SERVICE_NAME} unit is stopped and removed and the combined stack has been brought down.
EOF

if [[ "$REMOVE_VOLUMES" -eq 0 ]]; then
  cat <<EOF

The named volumes were KEPT, so a re-install reuses the existing data. To wipe them, either re-run
with --remove-volumes or remove them by hand with \`podman volume ls\` / \`podman volume rm\`.
EOF
fi
