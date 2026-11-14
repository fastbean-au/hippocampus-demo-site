"""Tests for the watchdog's warning reporting: the accepted-warnings list and how it is applied.

Run from the repository root:

    python3 -I -m unittest discover -s .github/watchdog
"""

import os
import subprocess
import sys
import tempfile
import unittest
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import probe  # noqa: E402

NOW = datetime(2026, 11, 15, 12, 0, tzinfo=timezone.utc)
RULE = "HippocampusAncillaryStorageHigh"
BLUESKY = "hippocampus-bluesky"


def alert(service, state="Alerting", days_ago=5.0):
    return {
        "state": state,
        "activeAt": (NOW - timedelta(days=days_ago)).isoformat().replace("+00:00", "Z"),
        "labels": {"service_name": service},
    }


def rule(alerts, name=RULE, severity="warning"):
    return {"name": name, "labels": {"severity": severity}, "alerts": alerts}


def accept(until=None, service=BLUESKY, name=RULE):
    return {(name, service): (until, "by design")}


class ParseAccepted(unittest.TestCase):
    def test_reads_a_dated_entry_and_a_never_entry(self):
        got = probe.parse_accepted(
            "# a comment\n"
            "\n"
            f"{RULE} hippocampus-bluesky 2027-02-12 forgotten log at its cap (TODO 184)\n"
            f"{RULE} hippocampus-agent never   outbox by design\n"
        )

        self.assertEqual(
            got,
            {
                (RULE, BLUESKY): (date(2027, 2, 12), "forgotten log at its cap (TODO 184)"),
                (RULE, "hippocampus-agent"): (None, "outbox by design"),
            },
        )

    def test_refuses_an_entry_without_a_reason(self):
        with self.assertRaisesRegex(ValueError, "line 1"):
            probe.parse_accepted(f"{RULE} hippocampus-bluesky never\n")

    def test_refuses_an_end_date_that_is_neither_a_date_nor_never(self):
        for until in ("2027-13-01", "forever", "12/02/2027"):
            with self.subTest(until=until), self.assertRaisesRegex(ValueError, "neither"):
                probe.parse_accepted(f"{RULE} hippocampus-bluesky {until} why\n")

    def test_refuses_the_same_rule_and_service_twice(self):
        with self.assertRaisesRegex(ValueError, "line 2: .* twice"):
            probe.parse_accepted(f"{RULE} {BLUESKY} never a\n{RULE} {BLUESKY} 2027-01-01 b\n")

    def test_the_shipped_list_parses(self):
        probe.parse_accepted((HERE / "accepted-warnings.txt").read_text(encoding="utf-8"))

    def test_a_missing_list_accepts_nothing(self):
        self.assertEqual(probe.load_accepted(str(HERE / "no-such-file.txt")), {})


class LongFiringWarnings(unittest.TestCase):
    def warnings(self, rules, accepted):
        return probe.long_firing_warnings(rules, 3, accepted, NOW)

    def test_an_unaccepted_warning_is_reported(self):
        reported, held = self.warnings([rule([alert(BLUESKY)])], {})

        self.assertEqual(reported, [f"Warning firing since 2026-11-10: {RULE} ({BLUESKY})"])
        self.assertEqual(held, [])

    def test_a_never_entry_holds_the_warning_back_however_long_it_fires(self):
        reported, held = self.warnings([rule([alert(BLUESKY, days_ago=400)])], accept())

        self.assertEqual(reported, [])
        self.assertEqual(held, [f"{RULE} (hippocampus-bluesky), with no end date: by design"])

    def test_a_dated_entry_holds_through_its_last_day(self):
        reported, held = self.warnings([rule([alert(BLUESKY)])], accept(until=NOW.date()))

        self.assertEqual(reported, [])
        self.assertEqual(held, [f"{RULE} (hippocampus-bluesky), until 2026-11-15: by design"])

    def test_an_expired_entry_reports_the_warning_and_asks_for_renewal(self):
        expired = NOW.date() - timedelta(days=1)
        reported, held = self.warnings([rule([alert(BLUESKY)])], accept(until=expired))

        self.assertEqual(
            reported,
            [
                f"Warning firing since 2026-11-10: {RULE} (hippocampus-bluesky)",
                f"Acceptance expired on 2026-11-14: {RULE} (hippocampus-bluesky)"
                f" - renew or remove its entry in {probe.ACCEPTED}",
            ],
        )
        self.assertEqual(held, [])

    def test_an_entry_hides_only_its_own_service(self):
        rules = [rule([alert(BLUESKY), alert("hippocampus-agent", days_ago=4)])]
        reported, held = self.warnings(rules, accept())

        self.assertEqual(reported, [f"Warning firing since 2026-11-11: {RULE} (hippocampus-agent)"])
        self.assertEqual(len(held), 1)

    def test_an_entry_hides_only_its_own_rule(self):
        other = "HippocampusIndexBloated"
        rules = [rule([alert(BLUESKY)]), rule([alert(BLUESKY)], name=other)]
        reported, _ = self.warnings(rules, accept())

        self.assertEqual(reported, [f"Warning firing since 2026-11-10: {other} ({BLUESKY})"])

    def test_an_entry_whose_warning_has_stopped_is_reported(self):
        for name, rules in {
            "no instance at all": [],
            "instance back to normal": [rule([alert(BLUESKY, state="Normal")])],
        }.items():
            with self.subTest(name):
                reported, held = self.warnings(rules, accept())

                self.assertEqual(
                    reported,
                    [
                        f"Accepted warning no longer firing: {RULE} (hippocampus-bluesky)"
                        f" - remove its entry from {probe.ACCEPTED}"
                    ],
                )
                self.assertEqual(held, [])

    def test_a_misspelt_entry_is_reported_as_not_firing(self):
        rules = [rule([alert(BLUESKY)])]
        reported, _ = self.warnings(rules, accept(service="hippocampus-blusky"))

        self.assertIn(f"Warning firing since 2026-11-10: {RULE} (hippocampus-bluesky)", reported)
        self.assertIn(
            f"Accepted warning no longer firing: {RULE} (hippocampus-blusky)"
            f" - remove its entry from {probe.ACCEPTED}",
            reported,
        )

    def test_a_pending_or_recently_restarted_instance_is_not_stale(self):
        # A Grafana restart resets activeAt and sends instances back through pending, so neither a
        # pending instance nor one firing for less than WARNING_DAYS means the warning has stopped.
        for name, a in {
            "pending": alert(BLUESKY, state="Pending"),
            "firing for an hour": alert(BLUESKY, days_ago=1 / 24),
        }.items():
            with self.subTest(name):
                reported, held = self.warnings([rule([a])], accept())

                self.assertEqual(reported, [])
                self.assertEqual(held, [])

    def test_critical_rules_are_left_to_the_main_probe(self):
        rules = [rule([alert(BLUESKY)], severity="critical")]
        reported, _ = self.warnings(rules, {})

        self.assertEqual(reported, [])

    def test_the_report_is_stable_from_run_to_run(self):
        accepted = {
            **accept(service="hippocampus-zeta"),
            **accept(service="hippocampus-alpha"),
            **accept(service=BLUESKY),
        }
        rules = [rule([alert(BLUESKY)])]

        first = self.warnings(rules, accepted)
        second = self.warnings(list(reversed(rules)), dict(reversed(list(accepted.items()))))

        self.assertEqual(first, second)


class ReportClosing(unittest.TestCase):
    """report.sh's closing comment, run against a stub gh that records what it was asked to do."""

    def run_report(self, accepted_lines):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            log = tmp / "gh.log"
            stub = tmp / "gh"
            stub.write_text(
                "#!/usr/bin/env bash\n"
                f'printf "%s\\n" "$*" >> "{log}"\n'
                'if [[ $1 == issue && $2 == list ]]; then echo 6; fi\n',
                encoding="utf-8",
            )
            stub.chmod(0o755)

            problems = tmp / "warnings.txt"
            problems.write_text("", encoding="utf-8")

            args = [str(HERE / "report.sh"), "watchdog-warning", str(problems), "title", "opening"]
            if accepted_lines is not None:
                accepted = tmp / "accepted.txt"
                text = "".join(f"{line}\n" for line in accepted_lines)
                accepted.write_text(text, encoding="utf-8")
                args.append(str(accepted))

            env = {
                **os.environ,
                "PATH": f"{tmp}{os.pathsep}{os.environ['PATH']}",
                "GITHUB_SERVER_URL": "https://github.com",
                "GITHUB_REPOSITORY": "owner/repo",
                "GITHUB_RUN_ID": "1",
                "OWNER": "owner",
            }
            subprocess.run(args, check=True, env=env, capture_output=True)

            return log.read_text(encoding="utf-8")

    def test_an_issue_closed_by_recovery_says_recovered(self):
        for name, accepted_lines in {"no accepted file": None, "empty accepted file": []}.items():
            with self.subTest(name):
                log = self.run_report(accepted_lines)

                self.assertIn("issue comment 6 --body Recovered: nothing to report", log)
                self.assertIn("issue close 6", log)

    def test_an_issue_closed_by_acceptance_says_accepted_and_lists_them(self):
        log = self.run_report([f"{RULE} (hippocampus-bluesky), with no end date: by design"])

        self.assertNotIn("Recovered", log)
        self.assertIn("accepted in `.github/watchdog/accepted-warnings.txt`", log)
        self.assertIn(f"- {RULE} (hippocampus-bluesky), with no end date: by design", log)
        self.assertIn("issue close 6", log)


if __name__ == "__main__":
    unittest.main()
