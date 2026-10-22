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
"""

import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

CADDYFILE = "showcase/caddy/Caddyfile.combined"
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


def firing_critical_rules(base_domain):
    body, reason = with_retries(f"https://grafana.{base_domain}/api/prometheus/grafana/api/v1/rules")
    if body is None:
        return [f"Grafana's alert state could not be read: {reason}"]

    problems = []
    for group in json.loads(body)["data"]["groups"]:
        for rule in group["rules"]:
            if rule.get("state") != "firing" or rule.get("labels", {}).get("severity") != "critical":
                continue

            names = sorted(
                {a.get("labels", {}).get("service_name", "") for a in rule.get("alerts", [])} - {""}
            )
            where = f" ({', '.join(names)})" if names else ""
            problems.append(f"Critical alert firing: {rule['name']}{where}")

    return problems


def main():
    base_domain = os.environ.get("BASE_DOMAIN", "hippocampus-demo.com")

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
