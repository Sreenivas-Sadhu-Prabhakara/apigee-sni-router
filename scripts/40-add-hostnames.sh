#!/usr/bin/env bash
# OPTIONAL — enables REAL edge/virtual-host (SNI) routing.
# Adds api-a / api-b / api-c subdomains of the nip.io runtime host to the env group so
# a request whose Host is api-a.<host> routes to backend A. nip.io wildcard DNS resolves
# them all to the LB IP, so no DNS setup is needed. The trial's managed cert covers only
# the base host, so test with `curl -k` (name mismatch expected). Reverse: 99-teardown.sh.
#
# SAFE: read-modify-write. It MERGES the three subdomains into the group's existing
# hostname list (preserving any hostnames other proxies/teams use) rather than replacing.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source ./config.env; set +a

TOKEN="$(gcloud auth print-access-token)"
API="https://apigee.googleapis.com/v1/organizations/${ORG}"

echo "==> Verifying env group '${ENV_GROUP}' exists"
GRP="$(curl -s -H "Authorization: Bearer ${TOKEN}" "${API}/envgroups/${ENV_GROUP}")"
if ! echo "${GRP}" | jq -e '.name' >/dev/null 2>&1; then
  echo "!! env group '${ENV_GROUP}' not found:"; echo "${GRP}" | jq . 2>/dev/null || echo "${GRP}"; exit 1
fi
echo "    current hostnames: $(echo "${GRP}" | jq -c '.hostnames')"

# Merge (union) the three api-x subdomains into the existing list — never replace.
NEW="$(echo "${GRP}" | jq -c --arg h "${RUNTIME_HOST}" \
  '(.hostnames + ["api-a."+$h, "api-b."+$h, "api-c."+$h]) | unique')"
echo "    new hostnames:     ${NEW}"

RESP="$(curl -s -X PATCH -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
  "${API}/envgroups/${ENV_GROUP}?updateMask=hostnames" \
  -d "$(jq -n --argjson hn "${NEW}" '{hostnames:$hn}')")"
if echo "${RESP}" | jq -e '.error' >/dev/null 2>&1; then
  echo "!! PATCH failed:"; echo "${RESP}" | jq .; exit 1
fi
echo "==> Updated. hostnames now: $(echo "${RESP}" | jq -c '.hostnames // .')"
echo
echo "Allow ~1-2 min to propagate, then e.g.:"
echo "  curl -k https://api-c.${RUNTIME_HOST}${BASE_PATH}/route -H \"X-API-Key: <app-all-key>\""
