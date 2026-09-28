# All the commands — SNI routing on Apigee X + GCP (every tier we built)

One reference for the whole build. `gcloud` where it can; the **REST API** where `gcloud` in the
current SDK can't (Apigee proxy/products/apps/endpoint-attachments, `tlsRoutes` with `targetProxies`,
`target-tcp-proxies --load-balancing-scheme`). Runnable end-to-end forms live in `../scripts/` and
`../psc/`; this file is the flat list, organized by tier.

```bash
# ---- Common vars ----
export PROJECT=apigee-neg-psc          # Apigee org == GCP project id (1:1)
export PNUM="$(gcloud projects describe $PROJECT --format='value(projectNumber)')"
export REGION=asia-south1              # same region as the Apigee runtime
export ORG=apigee-neg-psc
export ENV=eval
export TOKEN="$(gcloud auth print-access-token)"
export NET=sni-psc-net                 # dedicated VPC for the LB/PSC tiers
gcloud config set project $PROJECT

# ---- APIs to enable ----
gcloud services enable compute.googleapis.com apigee.googleapis.com \
  networkservices.googleapis.com dns.googleapis.com --project=$PROJECT
```

---

## Tier 0 — Apigee L7 SNI-routing proxy (`sni-router-v1`)

`gcloud` has no Apigee proxy commands; use the management API (or `apigeecli`). Full flow in
`../scripts/10-deploy.sh` / `20-create-authz.sh`.

```bash
# Import a proxy bundle (zip whose top dir is apiproxy/), then deploy the returned revision
zip -qr bundle.zip apiproxy
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: multipart/form-data" \
  --form "file=@bundle.zip" \
  "https://apigee.googleapis.com/v1/organizations/$ORG/apis?name=sni-router-v1&action=import"
# -> read "revision": N, then:
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  "https://apigee.googleapis.com/v1/organizations/$ORG/environments/$ENV/apis/sni-router-v1/revisions/N/deployments?override=true"

# API Product (path-scoped authz), Developer, App (returns consumerKey/Secret in credentials[])
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "https://apigee.googleapis.com/v1/organizations/$ORG/apiproducts" -d '{
    "name":"sni-product-a","approvalType":"auto","environments":["'"$ENV"'"],
    "proxies":["sni-router-v1"],"apiResources":["/a","/a/**"],"scopes":["read:a"],
    "quota":"5","quotaInterval":"1","quotaTimeUnit":"minute",
    "attributes":[{"name":"backends","value":"a"}]}'
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "https://apigee.googleapis.com/v1/organizations/$ORG/developers" \
  -d '{"email":"sni-dev@example.com","firstName":"Sni","lastName":"Dev","userName":"sni-dev@example.com"}'
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "https://apigee.googleapis.com/v1/organizations/$ORG/developers/sni-dev@example.com/apps" \
  -d '{"name":"sni-app-a","apiProducts":["sni-product-a"]}'
```

---

## Tier 1 — App-LB PSC egress (Apigee → PSC → **regional internal Application LB** → Internet NEG → origin)

The documented, working "Apigee over PSC to internet origins" path. Full flow in
`../psc/10-provision-lb.sh` + `20-apigee-attach.sh`.

```bash
# Network + subnets: regular (LB VIP), proxy-only (Envoys), PSC-NAT
gcloud compute networks create $NET --subnet-mode=custom
gcloud compute networks subnets create sni-lb-subnet   --network=$NET --range=10.50.0.0/24 --region=$REGION
gcloud compute networks subnets create sni-proxy-only   --network=$NET --range=10.50.1.0/24 --region=$REGION \
  --purpose=REGIONAL_MANAGED_PROXY --role=ACTIVE
gcloud compute networks subnets create sni-psc-nat      --network=$NET --range=10.50.2.0/28 --region=$REGION \
  --purpose=PRIVATE_SERVICE_CONNECT

# Cloud NAT for the proxy-only subnet (MANDATORY to reach public origins)
gcloud compute routers create sni-psc-router --network=$NET --region=$REGION
gcloud beta compute routers nats create sni-psc-nat-gw --router=sni-psc-router --region=$REGION \
  --endpoint-types=ENDPOINT_TYPE_MANAGED_PROXY_LB --nat-custom-subnet-ip-ranges=sni-proxy-only \
  --auto-allocate-nat-external-ips
gcloud compute firewall-rules create sni-psc-allow-ingress --network=$NET --direction=INGRESS \
  --action=ALLOW --rules=tcp:80 --source-ranges=10.50.2.0/28,10.50.1.0/24

# One Internet NEG + INTERNAL_MANAGED/HTTPS backend service per origin (repeat for postman, mocktgt)
gcloud beta compute network-endpoint-groups create neg-httpbin \
  --network-endpoint-type=INTERNET_FQDN_PORT --default-port=443 --network=$NET --region=$REGION
gcloud beta compute network-endpoint-groups update neg-httpbin \
  --add-endpoint="fqdn=httpbin.org,port=443" --region=$REGION
gcloud compute backend-services create bs-httpbin \
  --load-balancing-scheme=INTERNAL_MANAGED --protocol=HTTPS --region=$REGION
gcloud compute backend-services add-backend bs-httpbin \
  --network-endpoint-group=neg-httpbin --network-endpoint-group-region=$REGION --region=$REGION

# PATH-based URL map (host-rewrite is NOT allowed on the LB; route by path set by Apigee target.url)
gcloud compute url-maps create sni-psc-urlmap2 --default-service=bs-httpbin --region=$REGION
gcloud compute url-maps add-path-matcher sni-psc-urlmap2 --path-matcher-name=pm-all \
  --default-service=bs-httpbin --new-hosts='*' \
  --path-rules='/anything=bs-httpbin,/anything/*=bs-httpbin,/get=bs-postman,/get/*=bs-postman,/json=bs-mocktgt,/json/*=bs-mocktgt' \
  --region=$REGION
gcloud compute target-http-proxies create sni-psc-http-proxy --url-map=sni-psc-urlmap2 --region=$REGION
gcloud compute forwarding-rules create sni-psc-fr --load-balancing-scheme=INTERNAL_MANAGED \
  --network=$NET --subnet=sni-lb-subnet --target-http-proxy=sni-psc-http-proxy \
  --target-http-proxy-region=$REGION --ports=80 --allow-global-access --region=$REGION

# Publish via PSC + attach Apigee (endpoint attachment is API-only)
gcloud compute service-attachments create sni-southbound-sa --region=$REGION \
  --producer-forwarding-rule=sni-psc-fr --connection-preference=ACCEPT_AUTOMATIC --nat-subnets=sni-psc-nat
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "https://apigee.googleapis.com/v1/organizations/$ORG/endpointAttachments?endpointAttachmentId=sni-southbound-ea" \
  -d "{\"location\":\"$REGION\",\"serviceAttachment\":\"projects/$PROJECT/regions/$REGION/serviceAttachments/sni-southbound-sa\"}"
# poll GET .../endpointAttachments/sni-southbound-ea until state=ACTIVE, note .host (PUPI IP), then:
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "https://apigee.googleapis.com/v1/organizations/$ORG/environments/$ENV/targetservers" \
  -d '{"name":"sb-psc-target","host":"<PUPI_IP>","protocol":"HTTP","port":80,"isEnabled":true}'
```

---

## Tier 2 — True L4 SNI router (regional **internal proxy Network LB** + TLS routes, TLS-passthrough)

`gcloud` here lacks `target-tcp-proxies --load-balancing-scheme` and `tls-routes import` has no
`targetProxies` — so the backend-service-less proxy and the TLS route go through REST. Full flow in
`../psc/50-tcp-proxy-nlb.sh` + `55-tcp-sni-fanout.sh`.

```bash
# TCP backend service per origin on an Internet NEG (reuse neg-* or make tcp-neg-*)
gcloud compute backend-services create bs-tcp-httpbin \
  --load-balancing-scheme=INTERNAL_MANAGED --protocol=TCP --region=$REGION
gcloud compute backend-services add-backend bs-tcp-httpbin \
  --network-endpoint-group=tcp-neg-httpbin --network-endpoint-group-region=$REGION --region=$REGION

# Backend-service-less target-tcp-proxy — REST (this SDK's gcloud rejects --load-balancing-scheme)
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "https://compute.googleapis.com/compute/beta/projects/$PROJECT/regions/$REGION/targetTcpProxies" \
  -d '{"name":"tcp-proxy-sni","proxyHeader":"NONE","loadBalancingScheme":"INTERNAL_MANAGED"}'

# TLS route (SNI -> backend service), bound to the target proxy — REST (gcloud YAML lacks targetProxies)
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "https://networkservices.googleapis.com/v1/projects/$PROJECT/locations/$REGION/tlsRoutes?tlsRouteId=sni-tls-route" \
  -d "{\"targetProxies\":[\"projects/$PNUM/locations/$REGION/targetTcpProxies/tcp-proxy-sni\"],\"rules\":[
    {\"matches\":[{\"sniHost\":[\"httpbin.org\"]}],\"action\":{\"destinations\":[{\"serviceName\":\"projects/$PNUM/locations/$REGION/backendServices/bs-tcp-httpbin\"}]}},
    {\"matches\":[{\"sniHost\":[\"httpbingo.org\"]}],\"action\":{\"destinations\":[{\"serviceName\":\"projects/$PNUM/locations/$REGION/backendServices/bs-tcp-httpbingo\"}]}},
    {\"matches\":[{\"sniHost\":[\"mocktarget.apigee.net\"]}],\"action\":{\"destinations\":[{\"serviceName\":\"projects/$PNUM/locations/$REGION/backendServices/bs-tcp-mocktgt\"}]}}]}"

gcloud compute forwarding-rules create tcp-fr --load-balancing-scheme=INTERNAL_MANAGED \
  --network=$NET --subnet=sni-lb-subnet --address=tcp-lb-ip --target-tcp-proxy=tcp-proxy-sni \
  --target-tcp-proxy-region=$REGION --ports=443 --region=$REGION
# Test from a VPC client: curl --resolve httpbin.org:443:<VIP> https://httpbin.org/anything
```

**Public variant** (`../psc/60-external-sni-lb.sh`): identical but `--load-balancing-scheme=EXTERNAL_MANAGED`
on the backend services + target proxy, a public `--address`, and a `forwarding-rules create ... --ports=443`
without a subnet → testable from anywhere with `curl --resolve <sni>:443:<public-VIP>`.

---

## Tier 3 — Hybrid NEG per host (PSC-eligible; internet NEG is NOT allowed behind a PSC-published proxy NLB)

Pin each origin's current public IP (they rotate — demo-grade). Full flow in `../psc/70-hybrid-sni-lb.sh`
and `80-apigee-l4-psc.sh`.

```bash
gcloud compute health-checks create tcp hyb-hc --region=$REGION --port=443     # hybrid NEG needs a health check
IP=$(dig +short httpbin.org A | head -1)
gcloud compute network-endpoint-groups create hyb-neg-httpbin \
  --network-endpoint-type=NON_GCP_PRIVATE_IP_PORT --default-port=443 --network=$NET --zone=$REGION-a
gcloud compute network-endpoint-groups update hyb-neg-httpbin --add-endpoint="ip=$IP,port=443" --zone=$REGION-a
gcloud compute backend-services create bs-hyb-httpbin --load-balancing-scheme=EXTERNAL_MANAGED \
  --protocol=TCP --health-checks=hyb-hc --health-checks-region=$REGION --region=$REGION
gcloud compute backend-services add-backend bs-hyb-httpbin --network-endpoint-group=hyb-neg-httpbin \
  --network-endpoint-group-zone=$REGION-a --balancing-mode=CONNECTION --max-connections=1000 --region=$REGION
```

---

## Tier 4 — Private DNS so Apigee sends SNI=FQDN into the L4 (the last, unresolved link on the trial)

```bash
gcloud dns managed-zones create sni-z-httpbin --dns-name=httpbin.org. --visibility=private --networks=default
gcloud dns record-sets create httpbin.org. --zone=sni-z-httpbin --type=A --ttl=60 --rrdatas=<L4_PUPI_IP>
# Apigee target: AssignMessage sets target.url=https://httpbin.org/anything (Apigee sends SNI=httpbin.org).
# CAVEAT: a private zone bound to the authorized network is NOT resolved by Apigee's managed tenant
# without explicit DNS peering (Cloud DNS peering zone + roles/dns.peer for Apigee's service agent).
# Verified on this trial org: Apigee resolved the FQDN publicly and bypassed the L4.
```

---

## Teardown (reverse dependency order)

Scripts: `../scripts/99-teardown.sh` (Apigee), `../psc/99-teardown-psc.sh` (App-LB tier),
`../psc/59-teardown-tcp.sh` (internal L4), `../psc/69-teardown-ext.sh` (external + hybrid),
`../psc/89-teardown-l4-apigee.sh` (DNS + L4 PSC).

```bash
# TLS routes / endpoint attachments delete via REST DELETE (same base URLs as create).
# GCP order: forwarding-rule -> target-*-proxy -> url-map -> backend-services -> NEGs
#            -> health-checks -> service-attachment (after its endpoint attachment) -> addresses
#            -> Cloud NAT -> router -> firewall -> subnets -> network -> DNS record-sets -> DNS zones
```
