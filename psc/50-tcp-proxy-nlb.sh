#!/usr/bin/env bash
# Regional INTERNAL PROXY Network LB (TCP, INTERNAL_MANAGED) with an Internet NEG backend
# — the doc's pattern (load-balancing/docs/tcp/set-up-int-tcp-proxy-internet). Pure L4 TCP
# relay: TLS is NOT terminated, so the client's SNI/Host reach the origin end-to-end.
# Standalone (NOT PSC-published — GCP forbids Internet NEG behind a PSC'd proxy NLB).
# Reuses the existing VPC + proxy-only subnet + Cloud NAT from the App-LB build.
set -uo pipefail
cd "$(dirname "$0")"
set -a; source ./psc.env; set +a
P="--project=${PSC_PROJECT}"; R="--region=${PSC_REGION}"
mk(){ echo "  + ${1} ${2}"; shift; out="$("$@" 2>&1)"; echo "$out" | grep -qiE 'already exists' && { echo "    (exists)"; return 0; }; echo "$out" | grep -qiE 'error|ERROR' && { echo "    !! $out"; return 1; }; return 0; }

# Single-backend GA baseline: httpbin.org via a TCP-proxy NLB.
echo "== 1. Internet NEG (TCP backend) -> httpbin.org =="
mk neg gcloud beta compute network-endpoint-groups create tcp-neg-httpbin \
   --network-endpoint-type=INTERNET_FQDN_PORT --default-port=443 --network="${PSC_NETWORK}" $R $P
mk ep  gcloud beta compute network-endpoint-groups update tcp-neg-httpbin \
   --add-endpoint="fqdn=httpbin.org,port=443" $R $P

echo "== 2. TCP backend service =="
mk bs  gcloud compute backend-services create bs-tcp-httpbin \
   --load-balancing-scheme=INTERNAL_MANAGED --protocol=TCP $R $P
mk bsb gcloud compute backend-services add-backend bs-tcp-httpbin \
   --network-endpoint-group=tcp-neg-httpbin --network-endpoint-group-region="${PSC_REGION}" $R $P

echo "== 3. Reserve LB VIP (non-shared) + target TCP proxy + forwarding rule =="
mk ip  gcloud compute addresses create tcp-lb-ip --region="${PSC_REGION}" --subnet="${LB_SUBNET}" $P
mk tp  gcloud compute target-tcp-proxies create tcp-proxy --backend-service=bs-tcp-httpbin $R $P
mk fr  gcloud compute forwarding-rules create tcp-fr \
   --load-balancing-scheme=INTERNAL_MANAGED --network-tier=PREMIUM --network="${PSC_NETWORK}" \
   --subnet="${LB_SUBNET}" --address=tcp-lb-ip --target-tcp-proxy=tcp-proxy \
   --target-tcp-proxy-region="${PSC_REGION}" --ports=443 $R $P

VIP="$(gcloud compute addresses describe tcp-lb-ip --region="${PSC_REGION}" $P --format='value(address)' 2>/dev/null)"
echo
echo "== DONE. Internal proxy NLB VIP = ${VIP} (reachable only inside VPC ${PSC_NETWORK}) =="
echo "export TCP_LB_VIP=\"${VIP}\"" > .tcp-lb.env