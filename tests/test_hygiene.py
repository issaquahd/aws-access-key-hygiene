import json
import os
import sys
import unittest
from datetime import datetime, timezone
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "src"))
import hygiene  # noqa: E402

NOW = datetime(2026, 10, 10, tzinfo=timezone.utc)
FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "credential-report.csv")


def load_csv():
    with open(FIXTURE) as fh:
        return fh.read()


class AnalyzeTest(unittest.TestCase):
    def setUp(self):
        self.report = hygiene.analyze(hygiene.parse_report(load_csv()), NOW, 90, 90)
        self.findings = self.report["findings"]

    def of(self, user, ftype=None):
        return [f for f in self.findings if f["user"] == user and (ftype is None or f["type"] == ftype)]

    def test_summary(self):
        s = self.report["summary"]
        self.assertEqual(s["iam_users"], 6)
        self.assertEqual(s["active_keys"], 6)
        self.assertEqual(s["by_type"], {"console_without_mfa": 2, "key_too_old": 4,
                                        "key_unused": 3, "root_without_mfa": 1})
        self.assertEqual(s["findings"], 10)

    def test_clean_user_has_no_findings(self):
        self.assertEqual(self.of("alice"), [])

    def test_old_but_used_key(self):
        self.assertEqual(self.of("bob", "key_too_old")[0]["age_days"], 647)
        self.assertEqual(self.of("bob", "key_unused"), [])

    def test_console_without_mfa(self):
        self.assertEqual(len(self.of("bob", "console_without_mfa")), 1)
        self.assertEqual(self.of("erin", "console_without_mfa")[0]["password_last_used"], "no_information")

    def test_never_used_key_ages_from_rotation(self):
        unused = self.of("carol", "key_unused")[0]
        self.assertTrue(unused["never_used"])
        self.assertEqual(unused["unused_days"], 223)

    def test_inactive_key_ignored(self):
        self.assertTrue(all(f.get("key") == 1 for f in self.of("carol")))

    def test_second_key_checked_independently(self):
        dave = self.of("dave")
        self.assertEqual(sorted((f["type"], f["key"]) for f in dave), [("key_too_old", 1), ("key_unused", 1)])
        self.assertEqual(self.of("dave", "key_unused")[0]["unused_days"], 162)

    def test_missing_rotation_falls_back_to_creation(self):
        self.assertEqual(self.of("frank", "key_too_old")[0]["age_days"], 273)
        self.assertTrue(self.of("frank", "key_unused")[0]["never_used"])

    def test_root_rows(self):
        self.assertEqual([f["type"] for f in self.of("<root_account>")], ["root_without_mfa"])

    def test_report_has_no_arns(self):
        self.assertNotIn("arn:", json.dumps(self.report))

    def test_thresholds_respected(self):
        lenient = hygiene.analyze(hygiene.parse_report(load_csv()), NOW, 1000, 1000)
        self.assertEqual(lenient["summary"]["by_type"], {"console_without_mfa": 2, "root_without_mfa": 1})


class ParseTimeTest(unittest.TestCase):
    def test_placeholders(self):
        for value in ("N/A", "no_information", "not_supported", "", None):
            self.assertIsNone(hygiene.parse_time(value))

    def test_z_suffix(self):
        self.assertEqual(hygiene.parse_time("2026-10-09T00:00:00Z"), datetime(2026, 10, 9, tzinfo=timezone.utc))

    def test_root_access_key_flagged(self):
        row = {"user": "<root_account>", "mfa_active": "true", "access_key_1_active": "true",
               "access_key_1_last_rotated": "2026-10-01T00:00:00+00:00",
               "access_key_1_last_used_date": "2026-10-09T00:00:00+00:00"}
        report = hygiene.analyze([row], NOW)
        self.assertEqual([f["type"] for f in report["findings"]], ["root_access_key"])


class FakeIam:
    def __init__(self, csv_text):
        self.states = ["STARTED", "INPROGRESS", "COMPLETE"]
        self.csv_text = csv_text

    def generate_credential_report(self):
        return {"State": self.states.pop(0)}

    def get_credential_report(self):
        return {"Content": self.csv_text.encode("utf-8"), "ReportFormat": "text/csv"}


class FakeS3:
    def __init__(self):
        self.puts = []

    def put_object(self, **kwargs):
        self.puts.append(kwargs)


class HandlerTest(unittest.TestCase):
    def test_handler_polls_then_writes_two_objects(self):
        s3 = FakeS3()
        sleeps = []
        env = {"REPORT_BUCKET": "demo-bucket", "MAX_KEY_AGE_DAYS": "90", "MAX_UNUSED_DAYS": "90"}
        with mock.patch.dict(os.environ, env):
            out = hygiene.handler({}, None, iam=FakeIam(load_csv()), s3=s3, now=NOW, sleep=sleeps.append)
        self.assertEqual(len(sleeps), 2)
        self.assertEqual([p["Key"] for p in s3.puts],
                         ["reports/2026/10/10/credential-hygiene-20261010T000000Z.json", "reports/latest.json"])
        self.assertEqual(out["summary"]["findings"], 10)
        body = json.loads(s3.puts[0]["Body"])
        self.assertEqual(body["thresholds"], {"max_key_age_days": 90, "max_unused_days": 90})

    def test_report_never_ready(self):
        class SlowIam:
            def generate_credential_report(self):
                return {"State": "INPROGRESS"}
        with self.assertRaises(RuntimeError):
            hygiene.fetch_credential_report(SlowIam(), sleep=lambda s: None, attempts=3)


if __name__ == "__main__":
    unittest.main()
