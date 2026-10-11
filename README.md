# aws-access-key-hygiene

A daily Lambda function that reads the **IAM credential report** and flags the access-key and MFA problems that cause real incidents.

**Status:** linted and unit-tested offline. Not yet run against a live AWS account; this line changes when it has been.

## What it builds (CloudFormation, `access-key-hygiene.yaml`)

* Lambda (`python3.12`) that generates and reads the credential report, then writes a JSON report to S3 (`reports/YYYY/MM/DD/...json` plus `reports/latest.json`).
* S3 bucket: Block Public Access on, SSE-S3, ACLs disabled, TLS-only bucket policy, reports expire after 30 days.
* EventBridge rule `rate(1 day)` plus invoke permission.
* Explicit log group (14-day retention) so teardown leaves nothing behind.
* IAM role scoped to `iam:GenerateCredentialReport`, `iam:GetCredentialReport`, `s3:PutObject` on `reports/*`, and its own log group.

Flags (thresholds are stack parameters, default 90 days):

| Finding | Rule |
|---|---|
| `key_too_old` | active key not rotated in `MaxKeyAgeDays` (falls back to user creation date if rotation is unknown) |
| `key_unused` | active key unused for `MaxUnusedDays`. A never-used key ages from its rotation date. |
| `console_without_mfa` | IAM user with a console password and no MFA device |
| `root_without_mfa` / `root_access_key` | root user without MFA / root user with an active access key |

The report holds user names, key slots and day counts, never ARNs. The analysis logic lives in `src/hygiene.py`. The stack ships a placeholder function, and `deploy.sh` zips and uploads the real code.

Architecture: [`diagram.mmd`](diagram.mmd).

## Run it (AWS CloudShell, admin IAM user)

```bash
./deploy.sh                      # stack access-key-hygiene in us-east-2; MAX_KEY_AGE_DAYS / MAX_UNUSED_DAYS to override
./run-once.sh                    # invoke now, download report.json, print findings
./verify.sh                      # BPA + encryption + schedule checks, then a run
./teardown.sh                    # empties the bucket (all versions) FIRST, deletes the stack, lists leftovers
```

Offline tests use a synthetic credential report (`tests/fixtures/credential-report.csv`) with a fixed clock: `python3 -m unittest discover -s tests -t .`

## The learning

Long-lived access keys are the credential most often leaked. The credential report already knows which keys are old, which are unused and which console users lack MFA. Nobody reads it unless something reads it on a schedule. Automate the read, keep the output private and short-lived, and treat an unused key as a key to delete, not to rotate.

## Guardrails

Stays within the AWS Free plan: one Lambda run a day, a few KB in S3, scheduled EventBridge rules. No EC2, no NAT, no AWS Config, no Access Analyzer analyzers.

---

Independent project by Alex Alvord, CloudLab Works. MIT licensed.
