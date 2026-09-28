#!/usr/bin/env bash
# Provision the REGIONAL internal Application LB with 3 Internet NEGs, published via a
# PSC service attachment. Re-runnable: creates tolerate "already exists".
set -uo pipefail
cd "$(dirname "$0")"
set -a; source ./psc.env; set +a
P="--project=${PSC_PROJECT}"; R="--region=${PSC_REGION}"
mk(){ echo "  + $*"; out="$("$@" 2>&1)"; ec=$?; echo "$out" | grep -qiE 'already exists|conflict' && { echo "    (exists)"; return 0; }; [ $ec -ne 0 ] && { echo "    !! $out"; return $ec; }; return 0; }

echo "== 1. VPC + subnets =="
mk gcloud compute networks create "${PSC_NETWORK}" --subnet-mode=custom $P
mk gcloud compute networks subnets create "${LB_SUBNET}"    --network="${PSC_NETWORK}" --range="${LB_SUBNET_RANGE}" $R $P
mk gcloud compute networks subnets create "${PROXY_SUBNET}" --network="${PSC_NETWORK}" --range="${PROXY_SUBNET_RANGE}" --purpose=REGIONAL_MANAGED_PROXY --role=ACTIVE $R $P
mk gcloud compute networks subnets create "${PSC_NAT_SUBNET}" --network="${PSC_NETWORK}" --range="${PSC_NAT_RANGE}" --purpose=PRIVATE_SERVICE_CONNECT $R $P

echo "== 2. Cloud NAT (so the LB Envoys can reach the public backends) =="
mk gcloud compute routers create "${ROUTER}" --network="${PSC_NETWORK}" $R $P
mk gcloud compute routers nats create "${NAT}" --router="${ROUTER}" \
   --endpoint-types=ENDPOINT_TYPE_MANAGED_PROXY_LB \
   --nat-custom-subnet-ip-ranges="${PROXY_SUBNET}" \
   --auto-allocate-nat-external-ips $R $P

echo "== 3. Firewall: allow PSC-NAT + proxy-only ranges to the LB =="
mk gcloud compute firewall-rules create sni-psc-allow-ingress --network="${PSC_NETWORK}" \
   --direction=INGRESS --action=ALLOW --rules=tcp:80 \
   --source-ranges="${PSC_NAT_RANGE},${PROXY_SUBNET_RANGE}" $P

echo "== 4. Internet NEGs + backend services + URL map =="
FIRST_BS=""
for spec in ${BACKENDS}; do
  key="${spec%%|*}"; rest="${spec#*|}"; fqdn="${rest%%|*}"
  neg="neg-${key}"; bs="bs-${key}"
  echo "  -- ${key} -> ${fqdn}"
  mk gcloud beta compute network-endpoint-groups create "${neg}" \
     --network-endpoint-type=INTERNET_FQDN_PORT --default-port=443 --network="${PSC_NETWORK}" $R $P
  mk gcloud beta compute network-endpoint-groups update "${neg}" \
     --add-endpoint="fqdn=${fqdn},port=443" $R $P
  mk gcloud compute backend-services create "${bs}" \
     --load-balancing-scheme=INTERNAL_MANAGED --protocol=HTTPS $R $P
  mk gcloud compute backend-services add-backend "${bs}" \
     --network-endpoint-group="${neg}" --network-endpoint-group-region="${PSC_REGION}" $R $P
  [ -z "${FIRST_BS}" ] && FIRST_BS="${bs}"
done

mk gcloud compute url-maps create "${URLMAP}" --default-service="${FIRST_BS}" $R $P
for spec in ${BACKENDS}; do
  key="${spec%%|*}"; rest="${spec#*|}"; fqdn="${rest%%|*}"
  mk gcloud compute url-maps add-path-matcher "${URLMAP}" --path-matcher-name="pm-${key}" \
     --default-service="bs-${key}" --new-hosts="${fqdn}" $R $P
done

echo "== 5. Target proxy + INTERNAL forwarding rule =="
mk gcloud compute target-http-proxies create "${THP}" --url-map="${URLMAP}" $R $P
mk gcloud compute forwarding-rules create "${FR_NAME}" \
   --load-balancing-scheme=INTERNAL_MANAGED --network="${PSC_NETWORK}" --subnet="${LB_SUBNET}" \
   --target-http-proxy="${THP}" --target-http-proxy-region="${PSC_REGION}" --ports=80 --allow-global-access $R $P

echo "== 6. Publish via PSC service attachment =="
mk gcloud compute service-attachments create "${SA_NAME}" \
   --producer-forwarding-rule="${FR_NAME}" --connection-preference=ACCEPT_AUTOMATIC \
   --nat-subnets="${PSC_NAT_SUBNET}" $R $P

echo
echo "== DONE. Service attachment self-link (use in 20-apigee-attach.sh): =="
gcloud compute service-attachments describe "${SA_NAME}" $R $P --format='value(selfLink)'
