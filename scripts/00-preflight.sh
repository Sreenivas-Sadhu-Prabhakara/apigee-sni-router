#!/usr/bin/env bash
# Preflight: confirm we can reach the Apigee org before doing anything.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source ./config.env; set +a

TOKEN="$(gcloud auth print-access-token)"
API="https://apigee.googleapis.com/v1/organizations/${ORG}"

echo "==> Account:      $(gcloud config get-value account 2>/dev/null)"
echo "==> Org:          ${ORG}"
echo "==> Environment:  ${ENVIRONMENT}"
echo "==> Runtime host: ${BASE_URL}"
echo

echo "==> Org reachable?"
curl -s -H "Authorization: Bearer ${TOKEN}" "${API}" \
  | jq '{name, runtimeType, state, subscriptionType}' \
  || { echo "!! cannot read org — check IAM (need roles/apigee.admin or similar)"; exit 1; }

echo "==> Environment '${ENVIRONMENT}' exists?"
curl -s -H "Authorization: Bearer ${TOKEN}" "${API}/environments" | jq .

echo "==> Env-group hostnames (routing entry points):"
curl -s -H "Authorization: Bearer ${TOKEN}" "${API}/envgroups" \
  | jq '.environmentGroups[] | {name, hostnames}'

echo
echo "Preflight OK. Next: scripts/10-deploy.sh"
