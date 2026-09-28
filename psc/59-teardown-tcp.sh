#!/usr/bin/env bash
# Tear down the internal TCP-proxy NLB + SNI-router tier + test VM (dependency order).
# Leaves the shared VPC / proxy-only subnet / Cloud NAT (owned by the App-LB PSC tier).
set -uo pipefail
cd "$(dirname "$0")"
set -a; source ./psc.env; set +a
P="--project=${PSC_PROJECT}"; R="--region=${PSC_REGION}"; Z="--zone=${PSC_REGION}-a"
TOKEN="$(gcloud auth print-access-token)"
del(){ echo "  - $*"; "$@" --quiet >/dev/null 2>&1 || echo "    (skip)"; }

echo "== test VM + test firewalls =="
del gcloud compute instances delete sni-test-vm $Z $P
del gcloud compute firewall-rules delete sni-test-ssh $P
del gcloud compute firewall-rules delete sni-test-lb443 $P

echo "== TLS route (REST delete; must go before the target proxy) =="
curl -s -X DELETE -H "Authorization: Bearer ${TOKEN}" \
  "https://networkservices.googleapis.com/v1/projects/${PSC_PROJECT}/locations/${PSC_REGION}/tlsRoutes/sni-tls-route" >/dev/null 2>&1 || true
sleep 10

echo "== frontend: forwarding rule -> both target proxies -> address =="
del gcloud compute forwarding-rules delete tcp-fr $R $P
del gcloud compute target-tcp-proxies delete tcp-proxy-sni $R $P
del gcloud compute target-tcp-proxies delete tcp-proxy $R $P
del gcloud compute addresses delete tcp-lb-ip $R $P

echo "== backend services + internet NEGs =="
for k in httpbin httpbingo mocktgt; do del gcloud compute backend-services delete "bs-tcp-$k" $R $P; done
for k in httpbin httpbingo mocktgt; do del gcloud beta compute network-endpoint-groups delete "tcp-neg-$k" $R $P; done

echo "== TCP-proxy SNI-router tier removed (shared VPC/proxy-subnet/NAT preserved). =="