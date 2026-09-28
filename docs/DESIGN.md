# SNI-Router — Apigee X proxy design

**Status:** approved for build · **Date:** 2026-09-28 · **Org:** `apigee-neg-psc` / env `eval`

## Goal
One Apigee X API proxy that fronts **three backends on three different domains**, demonstrating
every meaningful sense of "SNI-based routing", wrapped in an **extensive, out-of-the-box**
authentication + authorization + traffic-management policy stack, fully testable via Postman + curl.

## The three routing behaviours ("all 3")
| # | Behaviour | Mechanism | Real SNI? |
|---|-----------|-----------|-----------|
| 1 | Inbound **host / virtual-host** routing | `RouteRule` `<Condition>` on `request.header.host` (`api-a.*`→A …) | Real SNI lives at the GCLB (3 certs) in prod; on this trial we drive it via the `Host` header — identical RouteRule mechanism |
| 2 | **Path** routing | `RouteRule` on `proxy.pathsuffix` (`/a`→A, `/b`→B, `/c`→C) | n/a — makes the demo work on one hostname/one cert |
| 3 | **Outbound** SNI | each `TargetEndpoint` dials its backend over TLS with `server_name` = backend domain | **Genuinely real** — 3 distinct outbound SNIs |

> **Not possible on Apigee:** true L4 TLS-*passthrough* SNI routing (route the still-encrypted
> ClientHello without terminating TLS). Apigee terminates TLS and is L7. Documented in README with
> the Envoy `tls_inspector` alternative for completeness — deployed nowhere.

**Precedence:** an explicit `X-Route: a|b|c` header wins (test convenience) → else host-header match → else path match → else a default RouteRule that returns a helpful 404.

## Backends (three real, distinct domains)
- **A** → `https://httpbin.org` (echoes headers → proves which auth headers are/aren't forwarded)
- **B** → `https://postman-echo.com`
- **C** → `https://mocktarget.apigee.net` (Apigee's own mock)

## Auth + authz + traffic stack (out-of-the-box policies)
Request pipeline (PreFlow → route):
1. **CORS** (preflight short-circuit)
2. **SpikeArrest** — burst protection
3. **JSONThreatProtection** — on write verbs
4. **Authentication** (one of, by flow):
   - `VerifyAPIKey` — key in `X-API-Key` header
   - `OAuthV2 / VerifyAccessToken` — bearer token minted by this proxy at `POST /oauth/token` (client_credentials)
   - `VerifyJWT` — HS256 token minted at `POST /jwt/mint` (self-contained, no external IdP)
5. **Authorization** — Apigee **API Product** membership decides *which path/backend* an app may call
   (app-A → only `/a`; calling `/b` → **403**), plus **OAuth scopes** per route.
6. **Quota** — per-app request cap → **429** when exceeded.
7. **RouteRules** → Target (A/B/C).
FaultRules convert any policy failure into a clean JSON `401 / 403 / 429` via `AssignMessage`/`RaiseFault`.

## Authorization matrix (what each app may reach)
| App | Product | `/a` | `/b` | `/c` | `/oauth/token` |
|-----|---------|:---:|:---:|:---:|:---:|
| `sni-app-a`   | `sni-product-a`   | ✅ | ⛔403 | ⛔403 | ✅ |
| `sni-app-b`   | `sni-product-b`   | ⛔403 | ✅ | ⛔403 | ✅ |
| `sni-app-all` | `sni-product-all` | ✅ | ✅ | ✅ | ✅ |

## Deploy & test flow
1. `scripts/10-deploy.sh` — zip `apiproxy/`, import via mgmt API, deploy revision to `eval`.
2. `scripts/20-create-authz.sh` — create Developer, 4 Products (path-scoped), 3 Apps; write keys to `.secrets.env`.
3. `scripts/30-smoke.sh` — curl the full matrix (401/200/403/429, token mint, jwt mint) against `BASE_URL`.
4. `postman/` — collection + environment mirroring the smoke test for interactive runs (`npx newman run`).

## Non-goals (YAGNI)
- No custom 3-cert edge SNI (trial cert-validation risk) — optional upgrade noted in README.
- No external IdP — JWT is self-signed HS256 for a self-contained demo.
- No CI/CD, no multi-env promotion — single `eval` deploy.

---

## Build notes — verified Apigee X gotchas & the review-driven fixes (2026-09-28)

A pre-deploy adversarial review + a live smoke run surfaced these. All are fixed and green (18/18).

### Security / correctness
1. **Authorization must bind to the routed target, not the request path.** Routing on
   `X-Route`/`Host` headers while authorizing on `proxy.pathsuffix` let an app pivot backends
   (app-b + `X-Route: a` → backend A). Fix: a single JS policy computes `flow.backend`
   (X-Route > Host > path); **both** the RouteRules and the authz policies (`RF-BackendDenied`
   for keys, `OA-VerifyScope-*` for tokens) read `flow.backend`, so they cannot diverge.
2. **Wrong-product on an API key is `oauth.v2.InvalidApiKeyForGivenResource` (401)**, remapped
   to a clean 403 by the `authz-fault` FaultRule.
3. **Never forward credentials to third-party backends.** `AM-StripCreds` removes BOTH
   `X-API-Key` and `Authorization` — but ONLY for backend-bound requests
   (`flow.backend` a/b/c), never for `/oauth/token` (Basic client creds) or `/jwt/verify`
   (the bearer JWT to validate). Stripping too broadly broke token minting and JWT verify.

### Apigee X mechanics that bit us
4. **`<Property name="copy.pathsuffix">false</Property>` is IGNORED on Apigee X.** The proxy
   path suffix was appended (`httpbin.org/anything` + `/a` → `/anything/a`). The reliable
   control is the runtime **variable** `target.copy.pathsuffix=false`, set by `AM-NoPathSuffix`
   in each TargetEndpoint PreFlow.
5. **An `AssignMessage` in the REQUEST flow can't set a non-200 status on a targetless route**
   (the 404 body appeared but status stayed 200). Fault-flow AssignMessages set status
   reliably, so NotFound is raised via `RF-NotFound` → `notfound-raise` FaultRule → `AM-NotFound`.
6. **VerifyJWT `IgnoreUnresolvedVariables=false`** throws `FailedToResolveVariable` (→500) when
   no bearer token is present; the `jwt-fault` rule must match `FailedToDecode`, `InvalidClaim`,
   `InvalidJsonFormat`, `TokenNotYetValid`, `InvalidSignature` (not just `*Jwt*`) to return 401.
7. **`action=validate` returns no `revision`** (only `action=import` does) — don't treat the
   missing field as failure.
8. **Env-group hostname PATCH replaces the whole list** — always read-modify-write to preserve
   other teams' hostnames on a shared org.

### API-key authorization mechanism
API keys carry no OAuth scopes, so per-backend authz for keys uses a Product **custom attribute**
`backends` (e.g. `a` or `a,b,c`), exposed as `verifyapikey.VerifyAPIKey.apiproduct.backends` and
checked against `flow.backend` by `RF-BackendDenied` (fails closed if the attribute is missing).

---

## PSC / internal-NEG-LB egress tier (2026-09-28) — Apigee → PSC → internal LB → Internet NEG → origin

Second architecture (in `psc/`): Apigee reaches the 3 backends over **southbound Private Service
Connect** instead of directly. LIVE GREEN 19/19 via this path.

```
Apigee TargetServer(sb-psc-target -> PUPI IP 7.26.176.2:80)
  -> Apigee Endpoint Attachment (1:1) -> PSC Service Attachment (sni-southbound-sa)
  -> REGIONAL internal App LB (INTERNAL_MANAGED, asia-south1, proxy-only subnet + Cloud NAT)
  -> path-based URL map (/anything->neg-httpbin, /get->neg-postman, /json->neg-mocktgt)
  -> Internet NEG (INTERNET_FQDN_PORT) -> httpbin.org / httpbingo.org / mocktarget.apigee.net
```
Scripts: `psc/10-provision-lb.sh` (VPC/subnets/NAT/NEGs/LB/service-attachment), `psc/20-apigee-attach.sh`
(endpoint attachment + TargetServer), `psc/30-fix-routing.sh` (path-based url-map), `psc/99-teardown-psc.sh`.
Apigee proxy targets set `target.url` + Host via `AM-PSC-httpbin/postman/mocktgt`.

### Hard-won gotchas (each cost a debugging round)
1. **CROSS-REGION internal App LB does NOT accept Internet NEGs — only the REGIONAL internal App LB does.**
2. **Cloud NAT is mandatory** (`--endpoint-types=ENDPOINT_TYPE_MANAGED_PROXY_LB`) — the proxy-only subnet
   is RFC1918-only, so the LB's Envoys can't reach public backends without it (fails silently).
3. **Apigee overrides the outbound `Host` to the target host** (the PSC IP) and an AssignMessage `Host`
   header does NOT survive — verified: httpbin echoed `Host: 7.26.176.2`. So `Host`-strict backends
   behind Cloudflare (postman-echo.com → 403) can't be reached via the PSC/IP path. **Swapped
   postman-echo.com → httpbingo.org** (a Host-agnostic live echo on a distinct domain).
4. **GCP LBs cannot rewrite the `Host` header** (`custom-request-header` rejects `Host`), and the Internet
   NEG does NOT auto-set Host to its FQDN — so you cannot fix #3 at the LB either.
5. **Route the internal LB by PATH, not Host** — Apigee controls the path deterministically via the
   `target.url` flow variable (verbatim, no path-suffix append); `<Set><Path>` and `<LoadBalancer>` did not.
6. **`gcloud compute url-maps import` did not apply** to the existing regional url-map — created a fresh
   path-based url-map and repointed the target-http-proxy instead.
7. Internet NEG lifecycle is **gcloud beta** only; **cross-region internal ALB + internet NEG** is the one
   combination the platform rejects; Apigee southbound uses an **Endpoint Attachment** (Mgmt API / Terraform,
   no gcloud), 1:1 with the service attachment, yielding a PUPI IP for the TargetServer.

---

## TRUE L4 SNI router — regional internal proxy Network LB + TLS routes (2026-09-28, VERIFIED)

The original "SNI-based routing" ask, realized at L4 (what Apigee/L7 structurally can't do). `psc/50-tcp-proxy-nlb.sh` (single-backend baseline) + `psc/55-tcp-sni-fanout.sh` (SNI fan-out); test VM + teardown in `psc/59-teardown-tcp.sh`.

```
VPC client ─► internal proxy Network LB VIP 10.50.0.3:443 (INTERNAL_MANAGED, TCP)
            ─► target-tcp-proxy (NO backend service)  ── TLS route (targetProxies binding)
                 ├─ sniHost httpbin.org           ─► bs-tcp-httpbin  ─► neg-httpbin  ─► httpbin.org:443
                 ├─ sniHost httpbingo.org         ─► bs-tcp-httpbingo─► neg-httpbingo─► httpbingo.org:443
                 └─ sniHost mocktarget.apigee.net ─► bs-tcp-mocktgt  ─► neg-mocktgt  ─► mocktarget.apigee.net:443
```
Verified from a VPC VM: each SNI → its origin, HTTP 200, and the **origin's real cert reaches the client** (CN=httpbin.org / httpbingo.org / mocktarget.apigee.net) — proving TLS is NOT terminated (pure L4 relay). Unmatched SNI → connection closed (SNI gating).

### Why this is different from every LB above it
- **TLS-passthrough:** target-tcp-proxy has no cert and `--protocol` is TCP-only, so it *cannot* decrypt — it peeks the ClientHello SNI to pick a backend, then relays the encrypted stream. The App LB (L7) terminates HTTP and forces Host=its IP; this doesn't.
- **This is the true "SNI router"** — routing decision = the client's SNI, at L4, no HTTP.

### Gotchas (each cost a round)
1. **Internet NEG behind a PSC-published proxy NLB is FORBIDDEN** (App-LB-only) — so this SNI router is **standalone** (VPC-internal, tested from a VM), NOT reachable via Apigee/PSC. The App-LB PSC tier remains the Apigee-reachable path.
2. **This gcloud can't create the pieces:** `target-tcp-proxies create` has no `--load-balancing-scheme`, and `tls-routes import` YAML has no `targetProxies` (only gateways/meshes). Created both via **REST** (compute beta `targetTcpProxies` with `loadBalancingScheme`; networkservices v1 `tlsRoutes` with `targetProxies`).
3. **`networkservices.googleapis.com` must be enabled** for TLS routes.
4. SNI routing on proxy NLBs is **Preview** (GCP, since 2026-03-31). TLS routes bind to the target-tcp-proxy via `targetProxies[]` (NOT a Gateway/Mesh, which are the Cloud Service Mesh model).
5. A target-tcp-proxy references **either** a backend service **or** TLS routes, never both — so the SNI proxy is created backend-service-less.
