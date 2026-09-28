#!/usr/bin/env bash
# PUBLIC L4 SNI router: regional EXTERNAL proxy Network LB + TLS routes, TLS-passthrough,
# fanning out by SNI to 3 internet-NEG backends. Public VIP -> testable from anywhere
# (e.g. this Mac) with no VM. Reuses VPC + proxy-only subnet + Cloud NAT.
#   SNI httpbin.org -> httpbin.org ; httpbingo.org -> httpbingo.org ; mocktarget.apigee.net -> mocktarget.apigee.net
set -uo pipefail
cd "$(dirname "$0")"
set -a; source ./psc.env; set +a
P="--project=${PSC_PROJECT}"; R="--region=${PSC_REGION}"
TOKEN="$(gcloud auth print-access-token)"
PNUM="$(gcloud projects describe "${PSC_PROJECT}" --format='value(projectNumber)')"
mk(){ echo "  + ${1}"; shift; out="$("$@" 2>&1)"; echo "$out" | grep -qiE 'already exists' && { echo "    (exists)"; return 0; }; echo "$out" | grep -qiE '^ERROR|error:' && { echo "    !! $out"; return 1; }; return 0; }

echo "== 1. External internet NEGs + EXTERNAL_MANAGED/TCP backend services =="
for pair in "httpbin|httpbin.org" "httpbingo|httpbingo.org" "mocktgt|mocktarget.apigee.net"; do
  k="${pair%%|*}"; fqdn="${pair##*|}"
  mk "neg-$k" gcloud beta compute network-endpoint-groups create "ext-neg-$k" \
     --network-endpoint-type=INTERNET_FQDN_PORT --default-port=443 --network="${PSC_NETWORK}" $R $P
  mk "ep-$k"  gcloud beta compute network-endpoint-groups update "ext-neg-$k" \
     --add-endpoint="fqdn=${fqdn},port=443" $R $P
  mk "bs-$k"  gcloud compute backend-services create "ext-bs-$k" \
     --load-balancing-scheme=EXTERNAL_MANAGED --protocol=TCP $R $P
  mk "bsb-$k" gcloud compute backend-services add-backend "ext-bs-$k" \
     --network-endpoint-group="ext-neg-$k" --network-endpoint-group-region="${PSC_REGION}" $R $P
done

echo "== 2. External backend-service-less target-tcp-proxy (REST) =="
curl -s -X POST -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
  "https://compute.googleapis.com/compute/beta/projects/${PSC_PROJECT}/regions/${PSC_REGION}/targetTcpProxies" \
  -d '{"name":"ext-tcp-proxy-sni","proxyHeader":"NONE","loadBalancingScheme":"EXTERNAL_MANAGED"}' \
  | jq -r '.status // .error.message // "(exists)"' | head -1 | sed 's/^/  /'
sleep 8

echo "== 3. External TlsRoute (REST) — SNI -> backend service =="
BS="projects/${PNUM}/locations/${PSC_REGION}/backendServices"
curl -s -X POST -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
  "https://networkservices.googleapis.com/v1/projects/${PSC_PROJECT}/locations/${PSC_REGION}/tlsRoutes?tlsRouteId=ext-sni-tls-route" \
  -d "{\"targetProxies\":[\"projects/${PNUM}/locations/${PSC_REGION}/targetTcpProxies/ext-tcp-proxy-sni\"],\"rules\":[
    {\"matches\":[{\"sniHost\":[\"httpbin.org\"]}],\"action\":{\"destinations\":[{\"serviceName\":\"${BS}/ext-bs-httpbin\"}]}},
    {\"matches\":[{\"sniHost\":[\"httpbingo.org\"]}],\"action\":{\"destinations\":[{\"serviceName\":\"${BS}/ext-bs-httpbingo\"}]}},
    {\"matches\":[{\"sniHost\":[\"mocktarget.apigee.net\"]}],\"action\":{\"destinations\":[{\"serviceName\":\"${BS}/ext-bs-mocktgt\"}]}}
  ]}" | jq -r '.name // .error.message' | head -1 | sed 's/^/  /'
sleep 15

echo "== 4. Public IP + external forwarding rule (EXTERNAL_MANAGED :443) =="
mk ip gcloud compute addresses create ext-sni-ip --region="${PSC_REGION}" --network-tier=PREMIUM $P
mk fr gcloud compute forwarding-rules create ext-sni-fr \
   --load-balancing-scheme=EXTERNAL_MANAGED --network-tier=PREMIUM --network="${PSC_NETWORK}" \
   --address=ext-sni-ip --target-tcp-proxy=ext-tcp-proxy-sni --target-tcp-proxy-region="${PSC_REGION}" \
   --ports=443 $R $P

VIP="$(gcloud compute addresses describe ext-sni-ip --region="${PSC_REGION}" $P --format='value(address)' 2>/dev/null)"
echo
echo "== DONE. Public SNI-router VIP = ${VIP} =="
echo "export EXT_SNI_VIP=\"${VIP}\"" > .ext-sni.env