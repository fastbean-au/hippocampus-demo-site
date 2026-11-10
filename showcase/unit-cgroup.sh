# shellcheck shell=bash
#
# unit-cgroup.sh - sourced by every script that creates or starts a showcase container, so that what
# it starts outlives whoever ran the script.
#
# WHY THIS EXISTS. Each container's payload runs in its own machine.slice scope. Where its CONMON
# goes - the monitor that holds the container's stdio, reaps its exit and runs its cleanup - depends
# on one environment variable. podman (4.9.3 here) leaves conmon in the cgroup of the process that ran
# `podman` when $INVOCATION_ID is set, which systemd sets for every service and every `systemd-run`
# unit. Otherwise it gives conmon a scope of its own, machine.slice/libpod-conmon-<id>.scope, which
# lives as long as the container does.
#
# So a container started from a systemd unit belongs to that unit, and dies with it. For the
# hippocampus-showcase unit itself that is what we want. For a deploy run under `systemd-run
# --collect` it is an outage: on 2026-10-08 a v0.52.0 deploy run that way lost the conmon of every
# container it had recreated the moment the transient unit exited, leaving phantoms - "running" to
# podman with no conmon alive. All five servers were down for ~24 minutes, and `systemctl restart
# hippocampus-showcase` could not clear them, because `compose down` fails on a phantom and `up` then
# skips its name. (Generators restarted by hand from a plain ssh session were lost the same morning.
# A plain ssh session has no $INVOCATION_ID, so their conmons had scopes of their own; why they died
# is still unexplained.)
#
# THE FIX is to unset $INVOCATION_ID before running podman, so every container a script starts gets
# its own conmon scope however the script was launched: from ssh, under nohup, or in a transient
# unit. Verified on the host on 2026-11-11 with throwaway containers under `systemd-run --wait`:
# with the variable kept, conmon was dead once the unit exited; with it unset, conmon was alive in
# its own scope.
#
# This replaces an earlier fix that wrote the script's pid into the unit's cgroup.procs. That only
# worked when $INVOCATION_ID was set, and it moved the deploy script, not the containers, into the
# unit, so a stop of the unit mid-deploy killed the deploy as well.
#
#   source "${SCRIPT_DIR}/unit-cgroup.sh"
#   detach_from_launcher deploy-servers      # the argument prefixes every message
#
# Run by the unit itself (start-generators.sh as its ExecStartPost) it changes nothing, so the
# containers the unit starts stay the unit's. Where there is no such unit at all (a stack brought up
# by hand on a machine that never ran install-ubuntu.sh) it only warns. It REFUSES when the unit is
# installed but not running: the stack is down, so a deploy would build a fragment of it outside the
# unit that `systemctl start` then trips over, and starting the unit is the fix.
#
# A healthy host therefore shows every conmon ALIVE - in the unit's cgroup for what the unit started,
# in its own scope for what a deploy recreated. Where a conmon lives is not the check; whether it is
# alive is.

SHOWCASE_UNIT="${SHOWCASE_UNIT:-hippocampus-showcase.service}"

# detach_from_launcher - make the containers this script starts outlive it, or exit non-zero saying
# why not.
detach_from_launcher() {
  local tag="$1"
  local load_state cgroup

  if ! command -v systemctl >/dev/null 2>&1; then
    echo "${tag}: WARNING - no systemctl, so nothing here manages the stack" >&2

    return 0
  fi

  load_state="$(systemctl show -p LoadState --value "${SHOWCASE_UNIT}" 2>/dev/null || true)"
  if [[ ${load_state} != "loaded" ]]; then
    echo "${tag}: WARNING - ${SHOWCASE_UNIT} is not installed, so nothing here manages the stack" >&2

    return 0
  fi

  # Empty while the unit is inactive: systemd removes the cgroup with its last process.
  cgroup="$(systemctl show -p ControlGroup --value "${SHOWCASE_UNIT}")"
  if [[ -z ${cgroup} ]]; then
    echo "${tag}: ${SHOWCASE_UNIT} is not running, so the stack is down. Start it with" \
      "\`systemctl start ${SHOWCASE_UNIT}\` rather than deploying into it." >&2

    exit 1
  fi

  # Run by the unit: what this starts should belong to the unit, which $INVOCATION_ID arranges.
  if grep -qx "0::${cgroup}" "/proc/$$/cgroup"; then
    return 0
  fi

  if [[ -n ${INVOCATION_ID:-} ]]; then
    echo "${tag}: launched from a systemd unit; unsetting INVOCATION_ID so the containers this" \
      "starts do not die with it"
  fi

  unset INVOCATION_ID
}
