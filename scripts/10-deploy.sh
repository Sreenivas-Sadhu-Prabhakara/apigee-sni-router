#!/usr/bin/env bash
# Zip the apiproxy/ bundle, import it as a new revision, and deploy that revision.
# Usage:  scripts/10-deploy.sh            (import + deploy)
#         scripts/10-deploy.sh validate   (validate the bundle only, no import)
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source ./config.env; set +a

MODE="${1:-deploy}"
TOKEN="$(gcloud auth print-access-token)"
API="https://apigee.googleapis.com/v1/organizations/${ORG}"

echo "==> Building bundle.zip from apiproxy/"
rm -f bundle.zip
zip -qr bundle.zip apiproxy -x '*.DS_Store' '*/.*'

ACTION="import"; [ "$MODE" = "validate" ] && ACTION="validate"
echo "==> ${ACTION} ${PROXY_NAME}"
RESP="$(curl -s -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: multipart/form-data" \
  --form "file=@bundle.zip" \
  "${API}/apis?name=${PROXY_NAME}&action=${ACTION}")"
echo "${RESP}" | jq . 2>/dev/null || { echo "${RESP}"; exit 1; }

# Any response carrying an .error object is a real failure.
if echo "${RESP}" | jq -e '.error' >/dev/null 2>&1; then
  echo "!! ${ACTION} failed. See error above."
  exit 1
fi

# validate mode returns the parsed config (no revision) — success = no error + policies parsed.
if [ "$MODE" = "validate" ]; then
  echo "==> Validation OK — bundle parsed: $(echo "${RESP}" | jq -r '.policies | length') policies, $(echo "${RESP}" | jq -r '.targetEndpoints | length') targets. Not deploying."
  exit 0
fi

REV="$(echo "${RESP}" | jq -r '.revision // empty')"
if [ -z "${REV}" ]; then
  echo "!! import failed (no revision in response). See error above."
  exit 1
fi
echo "==> import OK — revision ${REV}"

echo "==> Deploying revision ${REV} to environment '${ENVIRONMENT}' (override=true)"
DEP="$(curl -s -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  "${API}/environments/${ENVIRONMENT}/apis/${PROXY_NAME}/revisions/${REV}/deployments?override=true")"
echo "${DEP}" | jq . 2>/dev/null || echo "${DEP}"
if echo "${DEP}" | jq -e '.error' >/dev/null 2>&1; then
  echo "!! deploy failed. See error above."
  exit 1
fi

echo
echo "==> Deployment requested. It takes ~30-90s to become ACTIVE."
echo "    Check status:"
echo "    curl -s -H \"Authorization: Bearer \$(gcloud auth print-access-token)\" \\"
echo "      \"${API}/environments/${ENVIRONMENT}/apis/${PROXY_NAME}/deployments\" | jq ."
echo
echo "    Then:  scripts/20-create-authz.sh   (create products/apps/keys)"
