#!/usr/bin/env bash
# Tear down the PSC / internal-NEG-LB layer in dependency order. Best-effort + re-runnable.
# NOTE: after this, redeploy the proxy's direct-routing revision (or revert the target files),
# since the targets reference the now-deleted TargetServer sb-psc-target.
set -uo pipefail
cd "$(dirname "$0")"
set -a; source ./psc.env; set +a
P="--project=${PSC_PROJECT}"; R="--region=${PSC_REGION}"
TOKEN="$(gcloud auth print-access-token)"
BASE="https://apigee.googleapis.com/v1/organizations/${APIGEE_ORG}"
del(){ echo "  - $*"; "$@" --quiet >/dev/null 2>&1 || echo "    (skip/not found)"; }

echo "== Apigee: TargetServer + Endpoint Attachment =="
curl -s -X DELETE -H "Authorization: Bearer ${TOKEN}" \
  "${BASE}/environments/${APIGEE_ENV}/targetservers/${TARGETSERVER}" >/dev/null 2>&1 || true
curl -s -X DELETE -H "Authorization: Bearer ${TOKEN}" \
  "${BASE}/endpointAttachments/${EA_NAME}" >/dev/null 2>&1 || true
echo "  waiting for endpoint attachment to release the PSC connection..."
for i in $(seq 1 20); do
  ex="$(curl -s -H "Authorization: Bearer ${TOKEN}" "${BASE}/endpointAttachments/${EA_NAME}" | jq -r '.name // empty')"
  [ -z "$ex" ] && { echo "  EA gone"; break; }
  sleep 12
done

echo "== GCP: service attachment -> frontend -> backends -> NEGs =="
del gcloud compute service-attachments delete "${SA_NAME}" $R $P
del gcloud compute forwarding-rules delete "${FR_NAME}" $R $P
del gcloud compute target-http-proxies delete "${THP}" $R $P
del gcloud compute url-maps delete "${URLMAP}" $R $P
for spec in ${BACKENDS}; do key="${spec%%|*}"; del gcloud compute backend-services delete "bs-${key}" $R $P; done
for spec in ${BACKENDS}; do key="${spec%%|*}"; del gcloud beta compute network-endpoint-groups delete "neg-${key}" $R $P; done

echo "== GCP: NAT + router + firewall + subnets + network =="
del gcloud compute routers nats delete "${NAT}" --router="${ROUTER}" $R $P
del gcloud compute routers delete "${ROUTER}" $R $P
del gcloud compute firewall-rules delete sni-psc-allow-ingress $P
del gcloud compute networks subnets delete "${PSC_NAT_SUBNET}" $R $P
del gcloud compute networks subnets delete "${PROXY_SUBNET}" $R $P
del gcloud compute networks subnets delete "${LB_SUBNET}" $R $P
del gcloud compute networks delete "${PSC_NETWORK}" $P

rm -f .psc-host.env
echo "== PSC layer torn down. Redeploy direct routing if desired: git checkout the pre-PSC target files, or re-point targets. =="
