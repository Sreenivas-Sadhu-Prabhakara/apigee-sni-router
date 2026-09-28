#!/usr/bin/env bash
# EXPERIMENT (throwaway): swap the external L4 SNI router's backends from internet NEGs to
# HYBRID NEGs (NON_GCP_PRIVATE_IP_PORT) pinned to each origin's CURRENT public IP. Hybrid NEG
# is the backend type that IS allowed behind a PSC-published proxy NLB (internet NEG isn't) —
# so this is the shape that could make the L4 SNI router Apigee-reachable. Tests whether a
# hybrid NEG can even reach a public CDN IP. Reuses ext target-tcp-proxy + forwarding rule + TLS route.
set -uo pipefail
cd "$(dirname "$0")"
set -a; source ./psc.env; set +a
P="--project=${PSC_PROJECT}"; R="--region=${PSC_REGION}"; Z="--zone=${PSC_REGION}-a"
TOKEN="$(gcloud auth print-access-token)"; PNUM="$(gcloud projects describe "${PSC_PROJECT}" --format='value(projectNumber)')"
mk(){ echo "  + ${1}"; shift; out="$("$@" 2>&1)"; echo "$out" | grep -qiE 'already exists' && { echo "    (exists)"; return 0; }; echo "$out" | grep -qiE '^ERROR|error:' && { echo "    !! $out"; return 1; }; return 0; }

echo "== TCP health check (hybrid NEG backends REQUIRE one) =="
mk hc gcloud compute health-checks create tcp hyb-hc --region="${PSC_REGION}" --port=443 $P

echo "== per host: pin IP -> hybrid NEG (zonal) -> TCP backend service (+HC) =="
for pair in "httpbin|httpbin.org" "httpbingo|httpbingo.org" "mocktgt|mocktarget.apigee.net"; do
  k="${pair%%|*}"; fqdn="${pair##*|}"
  ip="$(/usr/bin/dig +short "$fqdn" A 2>/dev/null | /usr/bin/grep -E '^[0-9]' | /usr/bin/head -1)"
  echo "  -- ${k}: ${fqdn} -> ${ip}"
  mk "neg-$k" gcloud compute network-endpoint-groups create "hyb-neg-$k" \
     --network-endpoint-type=NON_GCP_PRIVATE_IP_PORT --default-port=443 --network="${PSC_NETWORK}" $Z $P
  mk "ep-$k"  gcloud compute network-endpoint-groups update "hyb-neg-$k" \
     --add-endpoint="ip=${ip},port=443" $Z $P
  mk "bs-$k"  gcloud compute backend-services create "ext-bs-hyb-$k" \
     --load-balancing-scheme=EXTERNAL_MANAGED --protocol=TCP \
     --health-checks=hyb-hc --health-checks-region="${PSC_REGION}" --region="${PSC_REGION}" $P
  mk "bsb-$k" gcloud compute backend-services add-backend "ext-bs-hyb-$k" \
     --network-endpoint-group="hyb-neg-$k" --network-endpoint-group-zone="${PSC_REGION}-a" --region="${PSC_REGION}" $P
done

echo "== repoint external TLS route rules -> hybrid backend services (REST PATCH) =="
BS="projects/${PNUM}/locations/${PSC_REGION}/backendServices"
curl -s -X PATCH -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
  "https://networkservices.googleapis.com/v1/projects/${PSC_PROJECT}/locations/${PSC_REGION}/tlsRoutes/ext-sni-tls-route?updateMask=rules" \
  -d "{\"rules\":[
    {\"matches\":[{\"sniHost\":[\"httpbin.org\"]}],\"action\":{\"destinations\":[{\"serviceName\":\"${BS}/ext-bs-hyb-httpbin\"}]}},
    {\"matches\":[{\"sniHost\":[\"httpbingo.org\"]}],\"action\":{\"destinations\":[{\"serviceName\":\"${BS}/ext-bs-hyb-httpbingo\"}]}},
    {\"matches\":[{\"sniHost\":[\"mocktarget.apigee.net\"]}],\"action\":{\"destinations\":[{\"serviceName\":\"${BS}/ext-bs-hyb-mocktgt\"}]}}
  ]}" | jq -r '.name // .error.message' | head -1 | sed 's/^/  /'
echo "== done. Allow ~1-2 min for health checks + route, then test from the Mac. =="