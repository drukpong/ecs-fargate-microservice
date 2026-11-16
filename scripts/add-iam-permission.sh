#!/usr/bin/env bash
set -euo pipefail

POLICY_FILE="aws-iam/dev-terraform-extra-policy.json"
POLICY_ARN="arn:aws:iam::189750305972:policy/ecs-fargate-github-dev-terraform-extra-policy"
ROLE_ARN="arn:aws:iam::189750305972:role/ecs-fargate-github-dev"

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 SID ACTION RESOURCE"
  echo "Example:"
  echo "$0 ListECSScalableTargetTags application-autoscaling:ListTagsForResource 'arn:aws:application-autoscaling:us-east-1:189750305972:scalable-target/*'"
  exit 1
fi

SID="$1"
ACTION="$2"
RESOURCE="$3"

echo "===== 1. UPDATE POLICY DOCUMENT ====="

python3 - "$POLICY_FILE" "$SID" "$ACTION" "$RESOURCE" <<'PY'
import json
import sys

path, sid, action, resource = sys.argv[1:]

with open(path) as f:
    policy = json.load(f)

policy["Statement"] = [
    s for s in policy["Statement"]
    if s.get("Sid") != sid
]

policy["Statement"].append({
    "Sid": sid,
    "Effect": "Allow",
    "Action": [action],
    "Resource": resource
})

with open(path, "w") as f:
    json.dump(policy, f, indent=2)
    f.write("\n")

print(f"Added {action} under {sid}")
PY

echo "===== 2. VALIDATE POLICY ====="

TMP_FILE=$(mktemp)
trap 'rm -f "$TMP_FILE"' EXIT

aws accessanalyzer validate-policy \
  --policy-document "file://$POLICY_FILE" \
  --policy-type IDENTITY_POLICY \
  --output json > "$TMP_FILE"

python3 - "$TMP_FILE" <<'PY'
import json
import sys

with open(sys.argv[1]) as f:
    result = json.load(f)

findings = result.get("findings", [])

if findings:
    print(json.dumps(findings, indent=2))
    print("Validation returned findings. Stopping before publishing.")
    sys.exit(1)

print("Validation passed: no findings.")
PY

echo "===== 3. CHECK IAM POLICY VERSION LIMIT ====="

VERSION_COUNT=$(aws iam list-policy-versions \
  --policy-arn "$POLICY_ARN" \
  --query 'length(Versions)' \
  --output text)

if (( VERSION_COUNT >= 5 )); then
  echo "Policy already has 5 versions."
  echo "Delete an old non-default version before continuing."
  exit 1
fi

echo "Current versions: $VERSION_COUNT"

echo "===== 4. PUBLISH NEW POLICY VERSION ====="

aws iam create-policy-version \
  --policy-arn "$POLICY_ARN" \
  --policy-document "file://$POLICY_FILE" \
  --set-as-default

echo "===== 5. VERIFY PERMISSION ====="

aws iam simulate-principal-policy \
  --policy-source-arn "$ROLE_ARN" \
  --action-names "$ACTION" \
  --resource-arns "$RESOURCE" \
  --query 'EvaluationResults[].{Action:EvalActionName,Decision:EvalDecision}' \
  --output table

echo "===== COMPLETE ====="
