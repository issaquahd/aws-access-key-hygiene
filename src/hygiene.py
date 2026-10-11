"""IAM access key hygiene from the credential report.

Flags:
  * key_too_old          active key not rotated in MAX_KEY_AGE_DAYS
  * key_unused           active key unused for MAX_UNUSED_DAYS (never-used keys age from rotation)
  * console_without_mfa  IAM user with a console password and no MFA
  * root_without_mfa     root user without MFA
  * root_access_key      root user with an active access key

Pure analysis (parse_report / analyze) is separated from AWS calls (handler)
so it can be unit-tested offline. Runs on python3.12 (Lambda) and python3.9.
"""
import csv
import io
import json
import os
import time
from datetime import datetime, timezone

ROOT_USER = "<root_account>"
EMPTY_VALUES = {"", "N/A", "no_information", "not_supported"}


def parse_report(csv_text):
    return list(csv.DictReader(io.StringIO(csv_text)))


def parse_time(value):
    """Credential-report timestamps are ISO 8601; placeholders mean 'no data'."""
    if value is None or value.strip() in EMPTY_VALUES:
        return None
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    parsed = datetime.fromisoformat(text)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed


def days_since(now, then):
    return max(0, (now - then).days)


def _is_true(value):
    return str(value).strip().lower() == "true"


def analyze(rows, now, max_key_age_days=90, max_unused_days=90):
    findings = []
    active_keys = 0
    users = 0
    for row in rows:
        user = row.get("user", "")
        is_root = user == ROOT_USER
        if not is_root:
            users += 1
        if is_root and not _is_true(row.get("mfa_active")):
            findings.append({"type": "root_without_mfa", "user": user})
        if not is_root and _is_true(row.get("password_enabled")) and not _is_true(row.get("mfa_active")):
            findings.append({"type": "console_without_mfa", "user": user,
                             "password_last_used": row.get("password_last_used", "N/A")})
        created = parse_time(row.get("user_creation_time"))
        for n in (1, 2):
            if not _is_true(row.get("access_key_%d_active" % n)):
                continue
            active_keys += 1
            if is_root:
                findings.append({"type": "root_access_key", "user": user, "key": n})
            rotated = parse_time(row.get("access_key_%d_last_rotated" % n)) or created
            last_used = parse_time(row.get("access_key_%d_last_used_date" % n))
            age = days_since(now, rotated) if rotated else None
            if age is not None and age > max_key_age_days:
                findings.append({"type": "key_too_old", "user": user, "key": n, "age_days": age})
            if last_used is not None:
                idle = days_since(now, last_used)
                if idle > max_unused_days:
                    findings.append({"type": "key_unused", "user": user, "key": n, "unused_days": idle,
                                     "never_used": False})
            elif age is not None and age > max_unused_days:
                findings.append({"type": "key_unused", "user": user, "key": n, "unused_days": age,
                                 "never_used": True})
    by_type = {}
    for f in findings:
        by_type[f["type"]] = by_type.get(f["type"], 0) + 1
    return {
        "generated_at": now.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "thresholds": {"max_key_age_days": max_key_age_days, "max_unused_days": max_unused_days},
        "summary": {"iam_users": users, "active_keys": active_keys, "findings": len(findings),
                    "by_type": dict(sorted(by_type.items()))},
        "findings": findings,
    }


def fetch_credential_report(iam, sleep=time.sleep, attempts=30):
    for _ in range(attempts):
        state = iam.generate_credential_report().get("State")
        if state == "COMPLETE":
            break
        sleep(2)
    else:
        raise RuntimeError("credential report not ready after %d attempts" % attempts)
    content = iam.get_credential_report()["Content"]
    return content.decode("utf-8") if isinstance(content, (bytes, bytearray)) else content


def handler(event, context, iam=None, s3=None, now=None, sleep=time.sleep):
    if iam is None or s3 is None:
        import boto3
        iam = iam or boto3.client("iam")
        s3 = s3 or boto3.client("s3")
    now = now or datetime.now(timezone.utc)
    bucket = os.environ["REPORT_BUCKET"]
    report = analyze(parse_report(fetch_credential_report(iam, sleep=sleep)), now,
                     int(os.environ.get("MAX_KEY_AGE_DAYS", "90")),
                     int(os.environ.get("MAX_UNUSED_DAYS", "90")))
    body = json.dumps(report, indent=2).encode("utf-8")
    key = now.strftime("reports/%Y/%m/%d/credential-hygiene-%Y%m%dT%H%M%SZ.json")
    for target in (key, "reports/latest.json"):
        s3.put_object(Bucket=bucket, Key=target, Body=body, ContentType="application/json")
    return {"bucket": bucket, "key": key, "latest": "reports/latest.json", "summary": report["summary"]}
