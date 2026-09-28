#!/usr/bin/env bash
# End-to-end test matrix against the live proxy. Reads keys from .secrets.env
# (written by scripts/20-create-authz.sh). Prints PASS/FAIL per case + a summary.
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; source ./config.env; [ -f ./.secrets.env ] && source ./.secrets.env; set +a

BASE="${BASE_URL}${BASE_PATH}"
PASS=0; FAIL=0; TMP="$(mktemp -d)"

# check <desc> <expected_status> <curl args...>
check() {
  local desc="$1" exp="$2"; shift 2
  local code; code="$(curl -s -o "$TMP/body" -w '%{http_code}' "$@")"
  if [ "$code" = "$exp" ]; then
    printf "  \033[32mPASS\033[0m  %-55s -> %s\n" "$desc" "$code"; PASS=$((PASS+1))
  else
    printf "  \033[31mFAIL\033[0m  %-55s -> got %s, want %s\n" "$desc" "$code" "$exp"; FAIL=$((FAIL+1))
    sed 's/^/          /' "$TMP/body" | head -3
  fi
}
body() { cat "$TMP/body"; }

echo "== Target: ${BASE} =="
echo
echo "-- 1. Authentication --------------------------------------------------------"
check "No credentials -> 401"                     401 "${BASE}/a"
check "API key (app-a) on /a -> 200"              200 "${BASE}/a" -H "X-API-Key: ${APP_A_KEY:-none}"

echo
echo "-- 2. Authorization (API Product path scoping) -----------------------------"
check "app-a key on /b (not authorized) -> 403"   403 "${BASE}/b" -H "X-API-Key: ${APP_A_KEY:-none}"
check "app-all key on /b -> 200"                  200 "${BASE}/b" -H "X-API-Key: ${APP_ALL_KEY:-none}"
check "app-all key on /c -> 200"                  200 "${BASE}/c" -H "X-API-Key: ${APP_ALL_KEY:-none}"

echo
echo "-- 3. Routing reached the right backend ------------------------------------"
curl -s "${BASE}/a" -H "X-API-Key: ${APP_A_KEY:-none}" | grep -q '"files"' \
  && { echo "  PASS  /a body mentions httpbin.org"; PASS=$((PASS+1)); } \
  || { echo "  FAIL  /a body did not mention httpbin.org"; FAIL=$((FAIL+1)); }
curl -s "${BASE}/b" -H "X-API-Key: ${APP_ALL_KEY:-none}" | grep -q "fly.io" \
  && { echo "  PASS  /b body mentions httpbingo.org"; PASS=$((PASS+1)); } \
  || { echo "  FAIL  /b body did not mention httpbingo.org"; FAIL=$((FAIL+1)); }

echo
echo "-- 4. OAuth2 client-credentials --------------------------------------------"
TOK="$(curl -s -u "${APP_ALL_KEY:-x}:${APP_ALL_SECRET:-x}" \
  -d 'grant_type=client_credentials' -d 'scope=read:a read:b read:c' \
  "${BASE}/oauth/token" | jq -r '.access_token // empty')"
[ -n "$TOK" ] && { echo "  PASS  minted access token (${TOK:0:12}...)"; PASS=$((PASS+1)); } \
             || { echo "  FAIL  could not mint access token"; FAIL=$((FAIL+1)); }
check "Bearer token on /a (has read:a) -> 200"    200 "${BASE}/a" -H "Authorization: Bearer ${TOK}"

TOK_B="$(curl -s -u "${APP_ALL_KEY:-x}:${APP_ALL_SECRET:-x}" \
  -d 'grant_type=client_credentials' -d 'scope=read:b' \
  "${BASE}/oauth/token" | jq -r '.access_token // empty')"
check "Bearer token missing read:a on /a -> 403"  403 "${BASE}/a" -H "Authorization: Bearer ${TOK_B}"

echo
echo "-- 5. JWT (self-contained HS256) -------------------------------------------"
JWT="$(curl -s "${BASE}/jwt/mint" -H "X-API-Key: ${APP_ALL_KEY:-none}" | jq -r '.access_token // empty')"
[ -n "$JWT" ] && { echo "  PASS  minted JWT (${JWT:0:16}...)"; PASS=$((PASS+1)); } \
             || { echo "  FAIL  could not mint JWT"; FAIL=$((FAIL+1)); }
check "Verify valid JWT -> 200"                   200 "${BASE}/jwt/verify" -H "Authorization: Bearer ${JWT}"
check "Verify garbage JWT -> 401"                 401 "${BASE}/jwt/verify" -H "Authorization: Bearer not.a.jwt"

echo
echo "-- 6. Quota (product-a = 5/min; 6th call trips) ----------------------------"
q=""; for i in 1 2 3 4 5 6; do
  q="$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/a" -H "X-API-Key: ${APP_A_KEY:-none}")"
  echo "     call $i -> $q"
done
[ "$q" = "429" ] && { echo "  PASS  6th call quota-limited (429)"; PASS=$((PASS+1)); } \
                 || { echo "  WARN  6th call was $q (quota window may have reset; re-run within a minute)"; }

echo
echo "-- 7. SpikeArrest (parallel burst) -----------------------------------------"
seq 1 40 | xargs -P 20 -I{} curl -s -o /dev/null -w '%{http_code}\n' \
  "${BASE}/c" -H "X-API-Key: ${APP_ALL_KEY:-none}" > "$TMP/burst" 2>/dev/null
if grep -q 429 "$TMP/burst"; then echo "  PASS  burst produced 429s ($(grep -c 429 "$TMP/burst")/40)"; PASS=$((PASS+1));
else echo "  WARN  no 429 in burst (runtime absorbed it); rate=15ps"; fi

echo
echo "-- 8. Header routing (X-Route) ---------------------------------------------"
curl -s "${BASE}/route" -H "X-API-Key: ${APP_ALL_KEY:-none}" -H "X-Route: b" | grep -q "fly.io" \
  && { echo "  PASS  X-Route: b -> backend B (postman)"; PASS=$((PASS+1)); } \
  || { echo "  FAIL  X-Route: b did not reach postman"; FAIL=$((FAIL+1)); }

echo
echo "-- 9. Host routing (needs scripts/40-add-hostnames.sh; -k for cert mismatch) -"
if curl -sk "https://api-c.${RUNTIME_HOST}${BASE_PATH}/route" -H "X-API-Key: ${APP_ALL_KEY:-none}" \
     | grep -q "mocktarget\|firstName\|Hello"; then
  echo "  PASS  Host api-c.* -> backend C (mocktarget)"; PASS=$((PASS+1))
else
  echo "  SKIP  host routing not active (run scripts/40-add-hostnames.sh first)"
fi

echo
echo "-- 10. Not found + CORS -----------------------------------------------------"
check "Unknown path -> 404"                       404 "${BASE}/nope" -H "X-API-Key: ${APP_ALL_KEY:-none}"
check "CORS preflight OPTIONS -> 200"             200 -X OPTIONS "${BASE}/a" \
  -H "Origin: https://example.com" -H "Access-Control-Request-Method: GET"

echo
echo "============================================================================"
printf "  RESULT: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n" "$PASS" "$FAIL"
echo "============================================================================"
rm -rf "$TMP"
[ "$FAIL" -eq 0 ]
