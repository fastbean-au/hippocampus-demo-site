#!/usr/bin/env python3
"""Probe the hosted showcase from outside it, and print one line per problem found.

Run by .github/workflows/watchdog.yml. It prints nothing and exits 0 when the showcase is healthy;
it exits non-zero only when it could not run at all (no site blocks found in the Caddyfile), so that
a broken probe is never mistaken for a healthy showcase.

Two kinds of problem, because the 2026-10-19 outage had both and the host could report neither:

- a host that does not answer: every site block in the Caddyfile (the authority on what the stack
  serves - see showcase/check-consistency.sh), so a console added there is watched with no edit here;
- a critical Grafana rule that is firing, read through Grafana's anonymous API. This is what sees
  trouble the endpoints cannot, such as the disk filling while everything still answers.

Each probe is retried before it counts, so a deploy's minute-long bounce or one dropped connection
does not open an issue.

With --warnings it probes nothing and instead prints one line per WARNING rule that has been firing
for at least WARNING_DAYS days (3 by default). A warning is not a problem to page on, but one that
fires for weeks cannot report a change either, and nobody opens Grafana to find out (TODO-3 item 184
in the hippocampus repository), so the workflow reports these on an issue of their own. The firing
time is Grafana's activeAt, which a restart of Grafana resets, so a warning is reported only once it
has stood that long since the last bounce. It exits 3 if Grafana cannot be read, which the workflow
takes as "unknown" and leaves the issue as it was: the main probe already reports that, and treating
it as "no warnings" would close the issue on every outage.

A warning that has been looked at and judged to be standing by design is listed in ACCEPTED, and is
not reported while its entry holds. An entry names a rule AND a service, so accepting one store's
warning never hides the same rule firing somewhere else. It holds until its end date, or for good
when the date is `never`. An expired entry reports its warning again, with a line asking for the
entry to be renewed or removed, and an entry whose warning is not firing at all is reported too, so
the list cannot quietly fill with entries nobody needs. --accepted-out names a file to write the
warnings that were held back to, which the workflow uses to say so rather than "recovered" when it
closes the issue.
"""

import argparse

import json
import os
import re
import sys
import time
from datetime import date, datetime, timedelta, timezone
import urllib.error
import urllib.request

CADDYFILE = "showcase/caddy/Caddyfile.combined"
ACCEPTED = ".github/watchdog/accepted-warnings.txt"
ATTEMPTS = 3
RETRY_SECONDS = 20
TIMEOUT_SECONDS = 15

# What to ask each host for. A console answers /healthz; the rest are not Hippocampus.
PATHS = {
    "": "/",
    "auth": "/realms/hippocampus/.well-known/openid-configuration",
    "grafana": "/api/health",
}


def served_hosts(base_domain):
    with open(CADDYFILE, encoding="utf-8") as f:
        text = f.read()

    subdomains = sorted(set(re.findall(r"^([a-z][a-z0-9-]*)\.\{\$BASE_DOMAIN", text, re.MULTILINE)))
    if not subdomains:
        sys.exit(f"probe: found no site blocks in {CADDYFILE} - has its syntax changed?")

    hosts = []
    if re.search(r"^\{\$BASE_DOMAIN", text, re.MULTILINE):
        hosts.append(("", base_domain))

    hosts += [(s, f"{s}.{base_domain}") for s in subdomains]

    return hosts


def fetch(url):
    """Return the body of a 200 response, or raise with a short reason."""
    request = urllib.request.Request(url, headers={"User-Agent": "hippocampus-showcase-watchdog"})
    with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
        return response.read()


def with_retries(url):
    """Return (body, None) on success, or (None, reason) once every attempt has failed."""
    reason = None
    for attempt in range(ATTEMPTS):
        if attempt:
            time.sleep(RETRY_SECONDS)

        try:
            return fetch(url), None
        except urllib.error.HTTPError as e:
            reason = f"HTTP {e.code}"
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            reason = str(getattr(e, "reason", e))

    return None, reason


def alert_rules(base_domain):
    """Return (rules, None) from Grafana's alert state, or (None, reason) if it could not be read."""
    body, reason = with_retries(f"https://grafana.{base_domain}/api/prometheus/grafana/api/v1/rules")
    if body is None:
        return None, reason

    return [rule for group in json.loads(body)["data"]["groups"] for rule in group["rules"]], None


def firing_critical_rules(base_domain):
    rules, reason = alert_rules(base_domain)
    if rules is None:
        return [f"Grafana's alert state could not be read: {reason}"]

    problems = []
    for rule in rules:
        if rule.get("state") != "firing" or rule.get("labels", {}).get("severity") != "critical":
            continue

        names = sorted(
            {a.get("labels", {}).get("service_name", "") for a in rule.get("alerts", [])} - {""}
        )
        where = f" ({', '.join(names)})" if names else ""
        problems.append(f"Critical alert firing: {rule['name']}{where}")

    return problems


def active_since(alert):
    """When an alert instance began firing, or None for one that is not firing or has no time."""
    if alert.get("state") != "Alerting" or not alert.get("activeAt"):
        return None

    return datetime.fromisoformat(alert["activeAt"].replace("Z", "+00:00"))


def parse_accepted(text):
    """Return {(rule, service): (until, why)} from the accepted-warnings list.

    One entry a line: the rule, the service, the last day it holds (YYYY-MM-DD) or `never`, then
    why. Blank lines and `#` comments are skipped. Anything else raises ValueError naming the line,
    since a list read wrongly would either hide a warning or report an accepted one.
    """
    accepted = {}
    for number, line in enumerate(text.splitlines(), start=1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue

        fields = line.split(None, 3)
        if len(fields) < 4:
            raise ValueError(f"line {number}: want <rule> <service> <YYYY-MM-DD|never> <why>")

        rule, service, until_text, why = fields
        if until_text == "never":
            until = None
        else:
            try:
                until = date.fromisoformat(until_text)
            except ValueError:
                raise ValueError(
                    f"line {number}: '{until_text}' is neither YYYY-MM-DD nor never"
                ) from None

        if (rule, service) in accepted:
            raise ValueError(f"line {number}: {rule} ({service}) is listed twice")

        accepted[(rule, service)] = (until, why)

    return accepted


def load_accepted(path):
    """The accepted-warnings list at `path`, or none at all when the file does not exist."""
    try:
        with open(path, encoding="utf-8") as f:
            return parse_accepted(f.read())
    except FileNotFoundError:
        return {}


def long_firing_warnings(rules, days, accepted, now):
    """Return (reported, held back): the lines to report, and the accepted warnings not reported.

    A warning line covers one rule's instances that have fired for at least `days`, less those an
    entry in `accepted` holds back. Each line names the date the oldest of them began, not how long
    ago that was, so the line - and the digest the workflow keeps of the list - stays the same from
    one run to the next, and a standing warning is reported once rather than daily. After them come
    one line per expired entry still firing, then one per entry whose warning is not firing at all.
    """
    cutoff = now - timedelta(days=days)

    lines = []
    expired = []
    held = []
    present = set()
    for rule in rules:
        if rule.get("labels", {}).get("severity") != "warning":
            continue

        stood = []
        for alert in rule.get("alerts", []):
            labels = alert.get("labels", {})
            key = (rule["name"], labels.get("service_name", ""))

            # Pending counts as present: a Grafana restart sends every instance back through
            # pending, and that must not read as the accepted warning having stopped.
            if alert.get("state") in ("Alerting", "Pending"):
                present.add(key)

            since = active_since(alert)
            if since is None or since > cutoff:
                continue

            if key in accepted:
                until, why = accepted[key]
                name, service = key
                if until is None or now.date() <= until:
                    holds = f"until {until}" if until else "with no end date"
                    held.append(f"{name} ({service}), {holds}: {why}")

                    continue

                expired.append(
                    f"Acceptance expired on {until}: {name} ({service})"
                    f" - renew or remove its entry in {ACCEPTED}"
                )

            stood.append((since, labels))

        if not stood:
            continue

        oldest = min(since for since, _ in stood)
        names = sorted({labels.get("service_name", "") for _, labels in stood} - {""})
        where = f" ({', '.join(names)})" if names else ""
        lines.append(f"Warning firing since {oldest:%Y-%m-%d}: {rule['name']}{where}")

    stale = [
        f"Accepted warning no longer firing: {rule} ({service}) - remove its entry from {ACCEPTED}"
        for rule, service in sorted(set(accepted) - present)
    ]

    return lines + sorted(expired) + stale, sorted(held)


def warnings_main(base_domain, accepted_out):
    try:
        accepted = load_accepted(ACCEPTED)
    except ValueError as e:
        sys.exit(f"probe: {ACCEPTED}: {e}")

    rules, reason = alert_rules(base_domain)
    if rules is None:
        print(f"probe: Grafana's alert state could not be read: {reason}", file=sys.stderr)
        sys.exit(3)

    reported, held = long_firing_warnings(
        rules,
        float(os.environ.get("WARNING_DAYS") or 3),
        accepted,
        datetime.now(timezone.utc),
    )

    for line in reported:
        print(line)

    if accepted_out:
        with open(accepted_out, "w", encoding="utf-8") as f:
            f.writelines(f"{line}\n" for line in held)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--warnings",
        action="store_true",
        help="report only warning rules that have fired for WARNING_DAYS days",
    )
    parser.add_argument(
        "--accepted-out",
        metavar="PATH",
        help="with --warnings, write the accepted warnings that were not reported to PATH",
    )
    args = parser.parse_args()

    base_domain = os.environ.get("BASE_DOMAIN", "hippocampus-demo.com")

    if args.warnings:
        warnings_main(base_domain, args.accepted_out)

        return

    problems = []
    for subdomain, host in served_hosts(base_domain):
        url = f"https://{host}{PATHS.get(subdomain, '/healthz')}"
        body, reason = with_retries(url)
        if body is None:
            problems.append(f"{host} is not answering: {reason} from {url}")

    problems += firing_critical_rules(base_domain)

    for p in problems:
        print(p)


if __name__ == "__main__":
    main()
