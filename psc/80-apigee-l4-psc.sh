#!/usr/bin/env bash
# Make the INTERNAL L4 SNI router PSC-eligible + publish it for Apigee southbound.
# Swaps its backends internet-NEG -> HYBRID-NEG (internet NEG is banned behind PSC), then
# fronts the internal forwarding rule (tcp-fr, VIP 10.50.0.3) with a PSC service attachment.
# Reuses: internal proxy NLB (tcp-proxy-sni + sni-tls-route + tcp-fr), hyb-hc, PSC NAT subnet.
set -uo pipefail
cd "$(dirname "$0")"
set -a; source ./psc.env; set +a
P="--project=${PSC_PROJECT}"; R="--region=${PSC_REGION}"; Z="--zone=${PSC_REGION}-a"
TOKEN="$(gcloud auth print-access-token)"; PNUM="$(gcloud projects describe "${PSC_PROJECT}" --format='value(projectNumber)')"
mk(){ echo "  + ${1}"; shift; out="$("$@" 2>&1)"; echo "$out" | grep -qiE 'already exists' && { echo "    (exists)"; return 0; }; echo "$out" | grep -qiE '^ERROR|error:' && { echo "    !! $out"; return 1; }; return 0; }

echo "== 1. internal hybrid NEGs (pinned IPs) + INTERNAL_MANAGED/TCP backend services =="
for pair in "httpbin|httpbin.org" "httpbingo|httpbingo.org" "mocktgt|mocktarget.apigee.net"; do
  k="${pair%%|*}"; fqdn="${pair##*|}"
  ip="$(/usr/bin/dig +short "$fqdn" A 2>/dev/null | /usr/bin/grep -E '^[0-9]' | /usr/bin/head -1)"
  echo "  -- ${k}: ${fqdn} -> ${ip}"
  mk "neg-$k" gcloud compute network-endpoint-groups create "int-hyb-neg-$k" \
     --network-endpoint-type=NON_GCP_PRIVATE_IP_PORT --default-port=443 --network="${PSC_NETWORK}" $Z $P
  mk "ep-$k"  gcloud compute network-endpoint-groups update "int-hyb-neg-$k" \
     --add-endpoint="ip=${ip},port=443" $Z $P
  mk "bs-$k"  gcloud compute backend-services create "int-bs-hyb-$k" \
     --load-balancing-scheme=INTERNAL_MANAGED --protocol=TCP \
     --health-checks=hyb-hc --health-checks-region="${PSC_REGION}" --region="${PSC_REGION}" $P
  mk "bsb-$k" gcloud compute backend-services add-backend "int-bs-hyb-$k" \
     --network-endpoint-group="int-hyb-neg-$k" --network-endpoint-group-zone="${PSC_REGION}-a" \
     --balancing-mode=CONNECTION --max-connections=1000 --region="${PSC_REGION}" $P
done

echo "== 2. repoint internal sni-tls-route -> hybrid backend services (REST PATCH) =="
BS="projects/${PNUM}/locations/${PSC_REGION}/backendServices"
curl -s -X PATCH -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
  "https://networkservices.googleapis.com/v1/projects/${PSC_PROJECT}/locations/${PSC_REGION}/tlsRoutes/sni-tls-route?updateMask=rules" \
  -d "{\"rules\":[
    {\"matches\":[{\"sniHost\":[\"httpbin.org\"]}],\"action\":{\"destinations\":[{\"serviceName\":\"${BS}/int-bs-hyb-httpbin\"}]}},
    {\"matches\":[{\"sniHost\":[\"httpbingo.org\"]}],\"action\":{\"destinations\":[{\"serviceName\":\"${BS}/int-bs-hyb-httpbingo\"}]}},
    {\"matches\":[{\"sniHost\":[\"mocktarget.apigee.net\"]}],\"action\":{\"destinations\":[{\"serviceName\":\"${BS}/int-bs-hyb-mocktgt\"}]}}
  ]}" | jq -r '.name // .error.message' | head -1 | sed 's/^/  /'

echo "== 3. PSC service attachment fronting the internal forwarding rule tcp-fr =="
mk sa gcloud compute service-attachments create sni-l4-sa \
   --producer-forwarding-rule=tcp-fr --connection-preference=ACCEPT_AUTOMATIC \
   --nat-subnets="${PSC_NAT_SUBNET}" $R $P
echo "  SA: $(gcloud compute service-attachments describe sni-l4-sa $R $P --format='value(selfLink)' 2>/dev/null)"
echo "== internal L4 SNI router is now hybrid-NEG-backed + PSC-published. Next: Apigee endpoint attachment + target. =="