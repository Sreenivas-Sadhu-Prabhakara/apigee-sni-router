# SNI Router — Apigee X multi-backend routing proxy

One Apigee X API proxy that fronts **three backends on three different domains** and demonstrates
every meaningful sense of "SNI-based routing", wrapped in an **extensive** authentication +
authorization + traffic-management policy stack. Deployed live to org `apigee-neg-psc` / env `eval`.

```
                                  ┌──────────────► https://httpbin.org          (backend A)
  client ──TLS──► GCLB (SNI) ──► sni-router-v1 ──┼──────────────► https://postman-echo.com     (backend B)
  8-232-203-178.nip.io            (1 proxy)      └──────────────► https://mocktarget.apigee.net (backend C)
                                   routes by: X-Route header > Host header > URL path
```

## The three routing behaviours ("all 3")
| # | Behaviour | How | Real SNI? |
|---|-----------|-----|-----------|
| 1 | **Host / virtual-host** | RouteRule on `request.header.host` (`api-a.*`→A …). Real SNI lives at the GCLB. | ✅ (run `scripts/40-add-hostnames.sh`) |
| 2 | **Path** | RouteRule on `proxy.pathsuffix` (`/a`→A, `/b`→B, `/c`→C). Works on one hostname. | — |
| 3 | **Outbound SNI** | each TargetEndpoint dials its backend over TLS with `server_name` = that domain. | ✅ 3 distinct outbound SNIs |
| + | **Header** | `X-Route: a\|b\|c` — highest precedence, for easy testing. | — |

> **Not possible on Apigee:** true L4 TLS-*passthrough* SNI (routing the encrypted ClientHello without
> terminating TLS). Apigee is L7. For that you'd put an Envoy `listener` with a `tls_inspector`
> listener-filter + `sni_cluster`/`filter_chain_match{server_names}` in front — no TLS termination,
> raw TCP forwarded per SNI. Out of scope here by design.

## Auth, authz & protection (out-of-the-box policies)
- **Authentication:** `VerifyAPIKey` (X-API-Key) · `OAuthV2` client-credentials (mint at `/oauth/token`, verify bearer) · `VerifyJWT`/`GenerateJWT` (HS256, self-contained at `/jwt/mint` + `/jwt/verify`)
- **Authorization:** API **Products** gate which path/backend each app may reach (app-a → 403 on /b); OAuth **scopes** gate each route (`read:a`/`read:b`/`read:c`)
- **Traffic:** `Quota` (per-app, product-driven) · `SpikeArrest` (burst) · `JSONThreatProtection`
- **Cross-cutting:** `CORS` · `AssignMessage`/`RaiseFault` FaultRules → clean JSON `400/401/403/404/429/500/502`

## Endpoints
| Method | Path | Auth | Purpose |
|--------|------|------|---------|
| GET | `/sni-router/a` `…/b` `…/c` | key **or** bearer | routed to backend A/B/C |
| GET | `/sni-router/route` + `X-Route`/`Host` | key **or** bearer | header/host routing |
| POST | `/sni-router/oauth/token` | Basic (key:secret) | mint OAuth2 token |
| GET | `/sni-router/jwt/mint` | key **or** bearer | mint HS256 JWT |
| GET | `/sni-router/jwt/verify` | bearer JWT | validate JWT, echo claims |

## Quick start
```bash
cd ~/Code/Code/apigee-sni-router
set -a; source ./config.env; set +a

scripts/00-preflight.sh        # confirm org/env reachable
scripts/10-deploy.sh           # zip + import + deploy the proxy
scripts/20-create-authz.sh     # developer + products + apps; writes .secrets.env
scripts/30-smoke.sh            # full PASS/FAIL matrix (curl)
scripts/40-add-hostnames.sh    # OPTIONAL: enable real Host/edge-SNI routing
scripts/99-teardown.sh         # remove everything
```
Postman: import `postman/sni-router.postman_collection.json` + the environment, paste the keys from
`.secrets.env`, run **OAuth2 > Get access token** and **JWT > Mint** first, then Run Collection.
CLI: `newman run postman/sni-router.postman_collection.json -e postman/sni-router.postman_environment.json`
(or `npx newman ...` — newman isn't installed globally).

## Authorization matrix
| App | Product | /a | /b | /c |
|-----|---------|:--:|:--:|:--:|
| `sni-app-a`   | `sni-product-a`   | ✅ | 403 | 403 |
| `sni-app-b`   | `sni-product-b`   | 403 | ✅ | 403 |
| `sni-app-all` | `sni-product-all` | ✅ | ✅ | ✅ |

## Layout
```
apiproxy/                 the deployable bundle (zipped by 10-deploy.sh)
  sni-router-v1.xml       root manifest
  proxies/default.xml     ProxyEndpoint: PreFlow auth, flows, RouteRules, FaultRules
  targets/*.xml           3 TargetEndpoints (one per backend domain)
  policies/*.xml          25 policies
scripts/                  preflight, deploy, authz, smoke, hostnames, teardown
postman/                  collection + environment
docs/DESIGN.md            design record
config.env                all names/URLs/scopes in one place
```
See `docs/DESIGN.md` for the full rationale and the verified-syntax gotchas that shaped the build.
