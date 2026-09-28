#!/usr/bin/env bash
# Make the internal LB route by PATH (which Apigee controls deterministically via target.url)
# and rewrite the Host header per backend so each external origin receives its own hostname
# (postman-echo.com is behind Cloudflare and 404s on a wrong Host).
set -euo pipefail
cd "$(dirname "$0")"
set -a; source ./psc.env; set +a
P="--project=${PSC_PROJECT}"; R="--region=${PSC_REGION}"
PFX="projects/${PSC_PROJECT}/regions/${PSC_REGION}/backendServices"

# NOTE: GCP forbids custom-request-header from modifying Host ("Custom headers cannot modify
# host headers") — the Internet NEG sets the backend Host/SNI to its own FQDN automatically.
# So we only need to route to the right NEG, which we do by PATH.

echo "== Path-based URL map (import) =="
cat > /tmp/sni-urlmap.yaml <<EOF
name: ${URLMAP}
region: ${PSC_REGION}
defaultService: ${PFX}/bs-httpbin
hostRules:
- hosts: ['*']
  pathMatcher: pm-all
pathMatchers:
- name: pm-all
  defaultService: ${PFX}/bs-httpbin
  pathRules:
  - paths: ['/anything', '/anything/*']
    service: ${PFX}/bs-httpbin
  - paths: ['/get', '/get/*']
    service: ${PFX}/bs-postman
  - paths: ['/json', '/json/*']
    service: ${PFX}/bs-mocktgt
EOF
gcloud compute url-maps import "${URLMAP}" --source=/tmp/sni-urlmap.yaml $R $P --quiet
echo "== done. LB now routes by path + rewrites Host. =="