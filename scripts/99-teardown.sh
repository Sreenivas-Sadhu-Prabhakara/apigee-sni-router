#!/usr/bin/env bash
# Remove everything this project created: undeploy the proxy, delete apps, products,
# developer, and reset the env group hostnames to just the base runtime host.
# Safe to re-run; ignores "not found" errors.
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; source ./config.env; set +a

TOKEN="$(gcloud auth print-access-token)"
API="https://apigee.googleapis.com/v1/organizations/${ORG}"
del() { curl -s -X DELETE -H "Authorization: Bearer ${TOKEN}" "$1" >/dev/null 2>&1 || true; }

echo "==> Undeploying ${PROXY_NAME} from ${ENVIRONMENT}"
REV="$(curl -s -H "Authorization: Bearer ${TOKEN}" \
  "${API}/environments/${ENVIRONMENT}/apis/${PROXY_NAME}/deployments" \
  | jq -r '.deployments[0].revision // empty')"
[ -n "${REV}" ] && del "${API}/environments/${ENVIRONMENT}/apis/${PROXY_NAME}/revisions/${REV}/deployments"

echo "==> Deleting apps"
for APP in "${APP_A}" "${APP_B}" "${APP_ALL}"; do
  del "${API}/developers/${DEVELOPER_EMAIL}/apps/${APP}"
done

echo "==> Deleting products"
for P in "${PRODUCT_A}" "${PRODUCT_B}" "${PRODUCT_C}" "${PRODUCT_ALL}"; do
  del "${API}/apiproducts/${P}"
done

echo "==> Deleting developer"
del "${API}/developers/${DEVELOPER_EMAIL}"

echo "==> Removing ONLY api-a/b/c hostnames from env group '${ENV_GROUP}' (preserving all others)"
GRP="$(curl -s -H "Authorization: Bearer ${TOKEN}" "${API}/envgroups/${ENV_GROUP}")"
if echo "${GRP}" | jq -e '.name' >/dev/null 2>&1; then
  NEW="$(echo "${GRP}" | jq -c --arg h "${RUNTIME_HOST}" \
    '.hostnames | map(select(. != ("api-a."+$h) and . != ("api-b."+$h) and . != ("api-c."+$h)))')"
  curl -s -X PATCH -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
    "${API}/envgroups/${ENV_GROUP}?updateMask=hostnames" \
    -d "$(jq -n --argjson hn "${NEW}" '{hostnames:$hn}')" | jq -c '.hostnames // .' 2>/dev/null || true
else
  echo "   (env group '${ENV_GROUP}' not found; skipping hostname reset)"
fi

echo "==> (Proxy definition kept. To delete it entirely:"
echo "    curl -X DELETE -H \"Authorization: Bearer \$(gcloud auth print-access-token)\" ${API}/apis/${PROXY_NAME} )"
echo "Teardown complete."
