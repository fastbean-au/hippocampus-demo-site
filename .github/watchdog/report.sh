#!/usr/bin/env bash
#
# Keep one open GitHub issue in step with a list of problems, one per line in a file.
#
#   report.sh <label> <problems file> <title prefix> <opening line>
#
# Run by .github/workflows/watchdog.yml, once for the outage list and once for the long-standing
# warnings, each under its own label so that a warning nobody can fix today never holds an outage
# issue open, and an outage never closes a warning issue as recovered.
#
# - problems and no open issue with the label: open one, mentioning the repository owner, so GitHub
#   notifies them by email and on the mobile app;
# - problems that changed since the issue's last report: comment the new list (another notification);
# - the same problems again: nothing, so a standing problem is one notification, not one a run;
# - no problems and an open issue: comment that it recovered, and close it.
#
# Expects GH_TOKEN, GH_REPO and OWNER in the environment, and the GITHUB_* variables Actions sets.

set -euo pipefail

label=$1
problems=$2
title_prefix=$3
opening=$4

gh label create "${label}" --color B60205 \
  --description "Opened and closed by the showcase watchdog" 2>/dev/null || true

issue=$(gh issue list --label "${label}" --state open --json number --jq '.[0].number // empty')
run_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
now=$(date -u '+%Y-%m-%d %H:%M UTC')

if [[ ! -s ${problems} ]]; then
  if [[ -n ${issue} ]]; then
    gh issue comment "${issue}" --body "Recovered: nothing to report at ${now} ([run](${run_url}))."
    gh issue close "${issue}"
  fi

  exit 0
fi

# The problem list's hash rides along in a hidden marker, so a repeat of the same list stays quiet
# and a changed one is reported.
digest=$(sha256sum "${problems}" | cut -c1-16)
marker="<!-- watchdog:${digest} -->"
list=$(sed 's/^/- /' "${problems}")

if [[ -z ${issue} ]]; then
  gh issue create --label "${label}" \
    --title "${title_prefix}: $(head -1 "${problems}" | cut -c1-80)" \
    --body "@${OWNER} ${opening} at ${now}:

${list}

[Run](${run_url}). This issue closes itself once there is nothing left to report.

${marker}"

  exit 0
fi

last=$(gh issue view "${issue}" --json body,comments \
  --jq '[.body] + [.comments[].body] | map(select(contains("<!-- watchdog:"))) | last')

if [[ ${last} != *"${marker}"* ]]; then
  gh issue comment "${issue}" --body "@${OWNER} the list changed at ${now}:

${list}

[Run](${run_url}).

${marker}"
fi
