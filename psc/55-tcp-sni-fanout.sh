#!/usr/bin/env bash
# TRUE L4 SNI ROUTER: one regional internal proxy Network LB + TLS routes fan out by SNI
# to 3 backends, TLS-PASSTHROUGH (no termination — origins' real certs reach the client).
#   SNI httpbin.org -> neg-httpbin ; httpbingo.org -> neg-httpbingo ; mocktarget.apigee.net -> neg-mocktgt
# SNI routing on proxy NLBs is Preview (GCP, since 2026-03-31). Reuses VPC + proxy-only
# subnet + Cloud NAT + the existing forwarding rule/VIP from 50-tcp-proxy-nlb.sh.
#
# NOTE: this gcloud lacks `target-tcp-proxies --load-balancing-scheme` and `tls-routes`
# YAML lacks `targetProxies`, so the backend-service-less proxy and the TLS route are
# created via the REST API (compute beta + networkservices v1).
set -uo pipefail
cd "$(dirname "$0")"
set -a; source ./psc.env; set +a
P="--project=${PSC_PROJECT}"; R="--region=${PSC_REGION}"
TOKEN="$(gcloud auth print-access-token)"
PNUM="$(gcloud projects describe "${PSC_PROJECT}" --format='value(projectNumber)')"
mk(){ echo "  + ${1}"; shift; out="$("$@" 2>&1)"; echo "$out" | grep -qiE 'already exists' && { echo "    (exists)"; return 0; }; echo "$out" | grep -qiE '^ERROR|error:' && { echo "    !! $out"; return 1; }; return 0; }

echo "== 0. Network Services API (needed for TLS routes) =="
gcloud services enable networkservices.googleapis.com $P 2>&1 | tail -1 | sed 's/^/  /'

echo "== 1. NEGs + TCP backend services (httpbin from 50-*.sh; add httpbingo + mocktgt) =="
for pair in "httpbingo|httpbingo.org" "mocktgt|mocktarget.apigee.net"; do
  k="${pair%%|*}"; fqdn="${pair##*|}"
  mk "neg-$k" gcloud beta compute network-endpoint-groups create "tcp-neg-$k" \
     --network-endpoint-type=INTERNET_FQDN_PORT --default-port=443 --network="${PSC_NETWORK}" $R $P
  mk "ep-$k"  gcloud beta compute network-endpoint-groups update "tcp-neg-$k" \
     --add-endpoint="fqdn=${fqdn},port=443" $R $P
  mk "bs-$k"  gcloud compute backend-services create "bs-tcp-$k" \
     --load-balancing-scheme=INTERNAL_MANAGED --protocol=TCP $R $P
  mk "bsb-$k" gcloud compute backend-services add-backend "bs-tcp-$k" \
     --network-endpoint-group="tcp-neg-$k" --network-endpoint-group-region="${PSC_REGION}" $R $P
done

echo "== 2. Backend-service-less target-tcp-proxy (REST beta; needed for TLS routes) =="
curl -s -X POST -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
  "https://compute.googleapis.com/compute/beta/projects/${PSC_PROJECT}/regions/${PSC_REGION}/targetTcpProxies" \
  -d '{"name":"tcp-proxy-sni","proxyHeader":"NONE","loadBalancingScheme":"INTERNAL_MANAGED"}' \
  | jq -r '.status // .error.message // "(exists)"' | head -1 | sed 's/^/  /'
sleep 8

echo "== 3. TlsRoute (REST v1; targetProxies binding) — SNI -> backend service =="
BS="projects/${PNUM}/locations/${PSC_REGION}/backendServices"
curl -s -X POST -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
  "https://networkservices.googleapis.com/v1/projects/${PSC_PROJECT}/locations/${PSC_REGION}/tlsRoutes?tlsRouteId=sni-tls-route" \
  -d "{\"targetProxies\":[\"projects/${PNUM}/locations/${PSC_REGION}/targetTcpProxies/tcp-proxy-sni\"],\"rules\":[
    {\"matches\":[{\"sniHost\":[\"httpbin.org\"]}],\"action\":{\"destinations\":[{\"serviceName\":\"${BS}/bs-tcp-httpbin\"}]}},
    {\"matches\":[{\"sniHost\":[\"httpbingo.org\"]}],\"action\":{\"destinations\":[{\"serviceName\":\"${BS}/bs-tcp-httpbingo\"}]}},
    {\"matches\":[{\"sniHost\":[\"mocktarget.apigee.net\"]}],\"action\":{\"destinations\":[{\"serviceName\":\"${BS}/bs-tcp-mocktgt\"}]}}
  ]}" | jq -r '.name // .error.message' | head -1 | sed 's/^/  /'
sleep 15

echo "== 4. Repoint the existing forwarding rule (VIP) to the SNI proxy =="
mk fr gcloud compute forwarding-rules set-target tcp-fr \
   --target-tcp-proxy=tcp-proxy-sni --target-tcp-proxy-region="${PSC_REGION}" $R $P
echo "== done. Test from a VPC client: curl --resolve <sni>:443:<VIP> https://<sni>/... =="