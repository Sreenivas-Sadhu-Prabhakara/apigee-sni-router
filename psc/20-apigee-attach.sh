#!/usr/bin/env bash
# Apigee southbound PSC: create an Endpoint Attachment (1:1 with the service attachment),
# wait for it to go ACTIVE/ACCEPTED, then create a TargetServer pointing at its PUPI IP.
set -uo pipefail
cd "$(dirname "$0")"
set -a; source ./psc.env; set +a
TOKEN="$(gcloud auth print-access-token)"
SA="projects/${PSC_PROJECT}/regions/${PSC_REGION}/serviceAttachments/${SA_NAME}"
BASE="https://apigee.googleapis.com/v1/organizations/${APIGEE_ORG}"

echo "== Create endpoint attachment ${EA_NAME} -> ${SA} =="
curl -s -X POST -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
  "${BASE}/endpointAttachments?endpointAttachmentId=${EA_NAME}" \
  -d "{\"location\":\"${PSC_REGION}\",\"serviceAttachment\":\"${SA}\"}" \
  | jq -r '.name // .error.message // .'

echo "== Poll until ACTIVE + host assigned (can take several minutes) =="
HOST=""
for i in $(seq 1 40); do
  R="$(curl -s -H "Authorization: Bearer ${TOKEN}" "${BASE}/endpointAttachments/${EA_NAME}")"
  ST="$(echo "$R" | jq -r '.state // empty')"
  CS="$(echo "$R" | jq -r '.connectionState // empty')"
  HOST="$(echo "$R" | jq -r '.host // empty')"
  echo "  try $i: state=$ST connectionState=$CS host=$HOST"
  { [ "$ST" = "ACTIVE" ] && [ -n "$HOST" ]; } && break
  sleep 15
done
[ -z "$HOST" ] && { echo "!! endpoint attachment never returned a host"; exit 1; }
echo "== EA host (PUPI IP): ${HOST} =="

echo "== Create/refresh TargetServer ${TARGETSERVER} -> ${HOST}:80 =="
BODY="{\"name\":\"${TARGETSERVER}\",\"host\":\"${HOST}\",\"protocol\":\"HTTP\",\"port\":80,\"isEnabled\":true}"
OUT="$(curl -s -X POST -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
  "${BASE}/environments/${APIGEE_ENV}/targetservers" -d "${BODY}")"
if echo "$OUT" | grep -qi 'already exists'; then
  OUT="$(curl -s -X PUT -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
    "${BASE}/environments/${APIGEE_ENV}/targetservers/${TARGETSERVER}" -d "${BODY}")"
fi
echo "$OUT" | jq -r '.name // .error.message // .'

echo "export PSC_EA_HOST=\"${HOST}\"" > .psc-host.env
echo "== Done. Host saved to psc/.psc-host.env =="
