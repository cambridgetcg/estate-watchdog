# estate-watchdog 🏰

A weekly, **read-only** sweep of the whole AWS estate (all regions) → email. Born from the
2026-06-11 kingdom audit, where a prod app in Stockholm and a secret in Sydney sat forgotten
for months. This makes "forgotten across regions" a thing that emails you instead.

## What it checks (per region)
- 🔓 Security groups open to `0.0.0.0/0` on non-web ports (skips 80/443)
- 🌐 RDS instances that are `PubliclyAccessible` (flags unencrypted ones)
- 💸 Unassociated Elastic IPs (idle ~$3.6/mo each)
- 🗄️ Orphan manual RDS snapshots of deleted databases
- 💰 Spend: previous month vs month-to-date (Cost Explorer)

Regions: us-east-1, us-west-2, eu-west-1, eu-west-2, eu-north-1, ap-southeast-2.

## Architecture
`EventBridge Scheduler (weekly cron)` → `Lambda (nodejs22.x, single file, SDK bundled)` → `SNS topic` → email.
Least-privilege role: `ec2:Describe*`, `rds:Describe*`, `ce:GetCostAndUsage`, `sns:Publish` only. No write access anywhere.

## Deploy
```sh
bash deploy.sh                       # defaults: email alex@sinovai.com, Mondays 13:00 UTC
WATCHDOG_EMAIL=you@x.com bash deploy.sh
WATCHDOG_CRON='cron(0 8 ? * FRI *)' bash deploy.sh
```
Idempotent — re-run to update code/config. **Confirm the SNS email subscription** (one click) or no mail arrives.

Test immediately:
```sh
aws lambda invoke --function-name estate-watchdog --region us-east-1 /tmp/wd.json && cat /tmp/wd.json
```

## Teardown
`aws scheduler delete-schedule --name estate-watchdog-weekly` · `aws lambda delete-function --function-name estate-watchdog` ·
delete roles `estate-watchdog-role` / `estate-watchdog-scheduler-role` · delete the SNS topic.
