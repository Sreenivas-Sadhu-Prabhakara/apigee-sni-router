#!/usr/bin/env bash
# Tear down the "internet -> Apigee -> PSC -> L4 -> NEG -> backend" wiring:
# DNS zones, Apigee endpoint attachment, L4 service attachment, its NAT subnet, and the
# internal hybrid-NEG backends. Leaves the base internal L4 router (tcp-*) to 59-teardown-tcp.sh
# and the App-LB PSC tier to 99-teardown-psc.sh.
# NOTE: after this, redeploy the Apigee proxy off the L4 target.url (revert AM-PSC-* or deploy an
# earlier revision) since the FQDN private DNS + PSC endpoint will be gone.
set -uo pipefail
cd "$(dirname "$0")"
set -a; source ./psc.env; set +a
P="--project=${PSC_PROJECT}"; R="--region=${PSC_REGION}"
TOKEN="$(gcloud auth print-access-token)"
del(){ echo "  - $*"; "$@" --quiet >/dev/null 2>&1 || echo "    (skip)"; }

echo "== private DNS zones (records first, then zone) =="
for zp in "sni-z-httpbin|httpbin.org." "sni-z-httpbingo|httpbingo.org." "sni-z-mocktgt|mocktarget.apigee.net."; do
  z="${zp%%|*}"; dns="${zp##*|}"
  del gcloud dns record-sets delete "$dns" --zone="$z" --type=A $P
  del gcloud dns managed-zones delete "$z" $P
done

echo "== Apigee endpoint attachment (releases the PSC connection) =="
curl -s -X DELETE -H "Authorization: Bearer ${TOKEN}" \
  "https://apigee.googleapis.com/v1/organizations/${APIGEE_ORG}/endpointAttachments/sni-l4-ea" >/dev/null 2>&1 || true
sleep 15

echo "== L4 service attachment + its NAT subnet =="
del gcloud compute service-attachments delete sni-l4-sa $R $P
del gcloud compute networks subnets delete sni-psc-nat2 $R $P

echo "== internal hybrid-NEG backends (used by sni-tls-route; 59-teardown-tcp.sh removes the route/proxy) =="
for k in httpbin httpbingo mocktgt; do del gcloud compute backend-services delete "int-bs-hyb-$k" $R $P; done
for k in httpbin httpbingo mocktgt; do del gcloud compute network-endpoint-groups delete "int-hyb-neg-$k" --zone="${PSC_REGION}-a" $P; done

echo "== L4-via-Apigee wiring removed. Redeploy the Apigee proxy off the L4 target.url next. =="