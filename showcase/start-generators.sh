#!/usr/bin/env bash
#
# start-generators.sh - start the showcase data generators once the auth path they depend on is
# actually serving. Run by the hippocampus-showcase systemd unit as an ExecStartPost, after
# `podman compose ... up -d`.
#
# WHY THIS EXISTS: the generators authenticate (OIDC client-credentials) against the issuer, which is
# served THROUGH the front Caddy. On a cold start they otherwise run the instant `up` creates them -
# before Caddy is listening and Keycloak is answering behind it - hit connection-refused/502, and
# exit. On the showcase's podman-compose (1.0.6) that is NOT self-correcting, for three reasons:
#   * `up -d` does not honour depends_on `condition: service_healthy`, so it cannot hold the
#     generators back until the issuer is ready;
#   * the generator image is distroless with a small internal retry budget, so it gives up quickly;
#   * podman's restart policy does not reliably restart the generators after that early exit (unlike
#     the long-running servers, which restart-loop until their stores are ready).
# So we wait here for Caddy to report healthy - its healthcheck probes the issuer discovery endpoint,
# i.e. the exact path the generators use - and only then start the generators, by which point their
# first token attempt succeeds. Starting an already-running generator is a no-op, so this is safe on a
# warm restart too.
set -uo pipefail

COMPOSE_FILE="${1:?usage: start-generators.sh <compose-file>}"

# Bounded wait for Caddy to be healthy, using its container healthcheck as the readiness signal.
# `podman compose ps -q <svc>` returns nothing on podman-compose 1.0.6, so find the Caddy container by
# its compose labels instead, scoped to this project (derived from the compose file's directory, which
# is how podman-compose names the project) so a stray caddy from another project is never matched.
PROJECT="$(basename "$(cd "$(dirname "${COMPOSE_FILE}")" && pwd)")"
CADDY_CID="$(podman ps -aq \
  --filter "label=com.docker.compose.project=${PROJECT}" \
  --filter "label=com.docker.compose.service=caddy" | head -n1)"

if [[ -n "${CADDY_CID}" ]]; then
  for _ in $(seq 1 60); do
    STATUS="$(podman inspect -f '{{.State.Health.Status}}' "${CADDY_CID}" 2>/dev/null || true)"

    if [[ "${STATUS}" == "healthy" ]]; then
      break
    fi

    sleep 3
  done
fi

# Best-effort start: if the issuer never came up there is nothing better to do here, and a failed
# start leaves the stack no worse off - so never fail the unit for this.
GENERATORS=(hippocampus-gen-book hippocampus-gen-agent hippocampus-gen-observer hippocampus-bluesky-bridge hippocampus-bluesky-bridge-worldnews)

echo "start-generators: starting ${GENERATORS[*]}"
podman compose -f "${COMPOSE_FILE}" start "${GENERATORS[@]}" || true

exit 0
