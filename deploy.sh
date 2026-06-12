#!/usr/bin/env bash
# Deploy estate-watchdog: weekly cross-region read-only sweep → SNS email.
# Run:  ! bash ~/dev/estate-watchdog/deploy.sh
# Idempotent — safe to re-run (updates code/config in place).
set -uo pipefail
export AWS_PAGER=""
cd "$(dirname "$0")"

REGION=us-east-1
ACCT=$(aws sts get-caller-identity --query Account --output text)
EMAIL="${WATCHDOG_EMAIL:-alex@sinovai.com}"
FN=estate-watchdog
ROLE=estate-watchdog-role
SCHED_ROLE=estate-watchdog-scheduler-role
TOPIC=estate-watchdog-alerts
CRON="${WATCHDOG_CRON:-cron(0 13 ? * MON *)}"   # Mondays 13:00 UTC
echo "account=$ACCT region=$REGION email=$EMAIL schedule='$CRON'"

echo "== SNS topic + email subscription =="
TOPIC_ARN=$(aws sns create-topic --name "$TOPIC" --region "$REGION" --query TopicArn --output text)
echo "  $TOPIC_ARN"
if aws sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" --region "$REGION" --query 'Subscriptions[].Endpoint' --output text | grep -q "$EMAIL"; then
  echo "  $EMAIL already subscribed"
else
  aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol email --notification-endpoint "$EMAIL" --region "$REGION" >/dev/null
  echo "  subscribed $EMAIL — ⚠️ CHECK YOUR INBOX and click Confirm, or no emails will arrive"
fi

echo "== IAM role: $ROLE =="
if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE" --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  aws iam attach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
  echo "  created"
fi
aws iam put-role-policy --role-name "$ROLE" --policy-name watchdog-read --policy-document "{
  \"Version\":\"2012-10-17\",\"Statement\":[
    {\"Effect\":\"Allow\",\"Action\":[\"ec2:DescribeSecurityGroups\",\"ec2:DescribeAddresses\",\"rds:DescribeDBInstances\",\"rds:DescribeDBSnapshots\",\"ce:GetCostAndUsage\"],\"Resource\":\"*\"},
    {\"Effect\":\"Allow\",\"Action\":\"sns:Publish\",\"Resource\":\"$TOPIC_ARN\"}
  ]}"
echo "  read policy attached"

echo "== package + deploy Lambda: $FN =="
rm -f function.zip && zip -j function.zip index.mjs >/dev/null
if aws lambda get-function --function-name "$FN" --region "$REGION" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "$FN" --zip-file fileb://function.zip --region "$REGION" >/dev/null
  aws lambda update-function-configuration --function-name "$FN" --region "$REGION" \
    --environment "Variables={TOPIC_ARN=$TOPIC_ARN}" --timeout 180 --memory-size 256 >/dev/null
  echo "  updated"
else
  # retry: IAM role propagation can lag a few seconds
  for i in 1 2 3 4 5; do
    if aws lambda create-function --function-name "$FN" --region "$REGION" \
      --runtime nodejs22.x --handler index.handler --timeout 180 --memory-size 256 \
      --role "arn:aws:iam::$ACCT:role/$ROLE" --zip-file fileb://function.zip \
      --environment "Variables={TOPIC_ARN=$TOPIC_ARN}" >/dev/null 2>/tmp/wd_err; then echo "  created"; break; fi
    echo "  waiting for role propagation ($i/5)…"; sleep 6
    [ $i -eq 5 ] && { echo "  FAILED: $(cat /tmp/wd_err)"; exit 1; }
  done
fi
FN_ARN=$(aws lambda get-function --function-name "$FN" --region "$REGION" --query Configuration.FunctionArn --output text)

echo "== EventBridge Scheduler invoke role: $SCHED_ROLE =="
if ! aws iam get-role --role-name "$SCHED_ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$SCHED_ROLE" --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"scheduler.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  echo "  created"
fi
aws iam put-role-policy --role-name "$SCHED_ROLE" --policy-name invoke --policy-document \
  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"lambda:InvokeFunction\",\"Resource\":\"$FN_ARN\"}]}"

echo "== weekly schedule: $FN-weekly =="
SARGS=(--name "$FN-weekly" --region "$REGION" --schedule-expression "$CRON" \
  --flexible-time-window '{"Mode":"OFF"}' \
  --target "{\"Arn\":\"$FN_ARN\",\"RoleArn\":\"arn:aws:iam::$ACCT:role/$SCHED_ROLE\"}")
if aws scheduler get-schedule --name "$FN-weekly" --region "$REGION" >/dev/null 2>&1; then
  for i in 1 2 3; do aws scheduler update-schedule "${SARGS[@]}" >/dev/null 2>/tmp/wd_err && { echo "  updated"; break; }; sleep 5; done
else
  for i in 1 2 3; do aws scheduler create-schedule "${SARGS[@]}" >/dev/null 2>/tmp/wd_err && { echo "  created"; break; }; sleep 5; [ $i -eq 3 ] && echo "  WARN: $(cat /tmp/wd_err)"; done
fi

echo
echo "✅ Deployed. Confirm the SNS email subscription, then test now with:"
echo "   aws lambda invoke --function-name $FN --region $REGION /tmp/wd-out.json && cat /tmp/wd-out.json"
echo "Teardown: delete-schedule $FN-weekly · delete-function $FN · delete-role $ROLE/$SCHED_ROLE · delete-topic $TOPIC_ARN"
