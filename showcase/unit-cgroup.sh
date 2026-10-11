# shellcheck shell=bash
#
# unit-cgroup.sh - sourced by every script that creates or starts a showcase container, so that what
# it starts belongs to the hippocampus-showcase unit rather than to whoever ran the script.
#
# WHY THIS EXISTS. Each container's payload runs in its own machine.slice scope, but its CONMON - the
# monitor that holds the container's stdio, reaps its exit and runs its cleanup - is forked into the
# cgroup of the process that ran `podman`. When the unit starts the stack that is
# system.slice/hippocampus-showcase.service, which is what a healthy host shows for every container.
# When a deploy script started one, it was the caller's: an ssh session scope, or the transient unit
# of a `systemd-run`. Whatever ends that cgroup ends the conmons in it. On 2026-10-08 a v0.52.0 deploy
# run under `systemd-run --collect` lost every container it had recreated the moment the transient
# unit exited, and the generators restarted by hand from a plain ssh session became phantoms -
# "running" to podman with neither conmon nor payload alive - when that session closed. All five
# servers were down for ~24 minutes, and `systemctl restart hippocampus-showcase` could not clear
# them, because `compose down` fails on a phantom and `up` then skips its name.
#
# THE FIX is for the script to join the unit's cgroup before it runs podman, so everything it forks
# from then on is the unit's - exactly as if the unit had started it - and lives until the unit
# stops, whatever happens to the shell that launched the deploy. systemd's own API for this,
# AttachProcessesToUnit, refuses ("Process migration not available on non-delegated units"), and
# making the unit Delegate=yes would change how systemd manages its cgroup and need a reinstall to
# land. Root writing its own pid into the unit's cgroup.procs needs neither; systemd tolerates it, and
# the unit's ExecStop (`compose down`) is what ends those containers either way.
#
#   source "${SCRIPT_DIR}/unit-cgroup.sh"
#   join_unit_cgroup deploy-servers          # the argument prefixes every message
#
# It is a no-op when the script is already in the unit (start-generators.sh as the unit's
# ExecStartPost) and only warns where there is no such unit at all (a stack brought up by hand on a
# machine that never ran install-ubuntu.sh, where nothing reaps a session's processes on its behalf).
# It REFUSES when the unit is installed but not running: the stack is down, so a deploy would build a
# fragment of it outside the unit - the phantom case again - and `systemctl start` is the fix.

SHOWCASE_UNIT="${SHOWCASE_UNIT:-hippocampus-showcase.service}"

# join_unit_cgroup - move this script into ${SHOWCASE_UNIT}'s cgroup, or exit non-zero saying why not.
join_unit_cgroup() {
  local tag="$1"
  local load_state cgroup

  if ! command -v systemctl >/dev/null 2>&1; then
    echo "${tag}: WARNING - no systemctl; containers started here belong to this shell" >&2

    return 0
  fi

  load_state="$(systemctl show -p LoadState --value "${SHOWCASE_UNIT}" 2>/dev/null || true)"
  if [[ ${load_state} != "loaded" ]]; then
    echo "${tag}: WARNING - ${SHOWCASE_UNIT} is not installed; containers started here belong to" \
      "this shell" >&2

    return 0
  fi

  # Empty while the unit is inactive: systemd removes the cgroup with its last process.
  cgroup="$(systemctl show -p ControlGroup --value "${SHOWCASE_UNIT}")"
  if [[ -z ${cgroup} ]]; then
    echo "${tag}: ${SHOWCASE_UNIT} is not running, so the stack is down. Start it with" \
      "\`systemctl start ${SHOWCASE_UNIT}\` rather than deploying into it - anything started now" \
      "would sit outside the unit and die with this session." >&2

    exit 1
  fi

  if grep -qx "0::${cgroup}" "/proc/$$/cgroup"; then
    return 0
  fi

  # Grouped so the 2>/dev/null covers the redirection itself, which is what fails without root.
  if ! { echo "$$" >"/sys/fs/cgroup${cgroup}/cgroup.procs"; } 2>/dev/null; then
    echo "${tag}: cannot join ${SHOWCASE_UNIT}'s cgroup (${cgroup}) - run as root. Containers" \
      "started from this shell would die with it." >&2

    exit 1
  fi

  # Confirm rather than trust the write: a container started outside the unit is the failure this
  # guards against, and it is silent until the shell that started it goes away.
  if ! grep -qx "0::${cgroup}" "/proc/$$/cgroup"; then
    echo "${tag}: joined ${cgroup} but /proc/$$/cgroup says $(cat "/proc/$$/cgroup"); refusing to" \
      "start containers outside the unit" >&2

    exit 1
  fi

  echo "${tag}: running inside ${SHOWCASE_UNIT} (${cgroup}), so what this starts outlives this shell"
}
