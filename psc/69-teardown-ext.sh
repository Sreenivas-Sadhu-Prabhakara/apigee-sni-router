#!/usr/bin/env bash
# Tear down the PUBLIC (external proxy NLB) SNI-router tier. Dependency order.
# Leaves the shared VPC / proxy-only subnet / Cloud NAT.
set -uo pipefail
cd "$(dirname "$0")"
set -a; source ./psc.env; set +a
P="--project=${PSC_PROJECT}"; R="--region=${PSC_REGION}"
TOKEN="$(gcloud auth print-access-token)"
del(){ echo "  - $*"; "$@" --quiet >/dev/null 2>&1 || echo "    (skip)"; }

echo "== external TLS route (REST delete, before the target proxy) =="
curl -s -X DELETE -H "Authorization: Bearer ${TOKEN}" \
  "https://networkservices.googleapis.com/v1/projects/${PSC_PROJECT}/locations/${PSC_REGION}/tlsRoutes/ext-sni-tls-route" >/dev/null 2>&1 || true
sleep 10

echo "== frontend: forwarding rule -> target proxy -> public IP =="
del gcloud compute forwarding-rules delete ext-sni-fr $R $P
del gcloud compute target-tcp-proxies delete ext-tcp-proxy-sni $R $P
del gcloud compute addresses delete ext-sni-ip $R $P

echo "== backend services (internet-NEG + hybrid-NEG) =="
for k in httpbin httpbingo mocktgt; do del gcloud compute backend-services delete "ext-bs-$k" $R $P; done
for k in httpbin httpbingo mocktgt; do del gcloud compute backend-services delete "ext-bs-hyb-$k" $R $P; done

echo "== NEGs (internet regional + hybrid zonal) + health check =="
for k in httpbin httpbingo mocktgt; do del gcloud beta compute network-endpoint-groups delete "ext-neg-$k" $R $P; done
for k in httpbin httpbingo mocktgt; do del gcloud compute network-endpoint-groups delete "hyb-neg-$k" --zone="${PSC_REGION}-a" $P; done
del gcloud compute health-checks delete hyb-hc --region="${PSC_REGION}" $P

echo "== external SNI-router tier removed (shared VPC/proxy-subnet/NAT preserved). =="