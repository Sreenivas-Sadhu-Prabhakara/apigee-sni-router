// Compute the single routing decision `flow.backend` (a|b|c|none) with strict
// precedence: X-Route header > Host header (virtual-host/edge SNI) > URL path.
// BOTH the RouteRules and the authorization policies read this same variable, so
// the routed backend and the authorized backend can never diverge (closes the
// header/host authorization-bypass).
var xr   = context.getVariable('request.header.x-route');
var host = context.getVariable('request.header.host') || '';
var ps   = context.getVariable('proxy.pathsuffix') || '';
var backend = 'none';

// Local (non-backend) endpoints never resolve to a routed backend.
var isLocal = (ps === '/oauth/token') || (ps === '/jwt') || (ps.indexOf('/jwt/') === 0);

if (!isLocal) {
  if (xr === 'a' || xr === 'b' || xr === 'c') {
    backend = xr;                                   // 1. explicit header wins
  } else if (host.indexOf('api-a.') === 0) {
    backend = 'a';                                  // 2. virtual host
  } else if (host.indexOf('api-b.') === 0) {
    backend = 'b';
  } else if (host.indexOf('api-c.') === 0) {
    backend = 'c';
  } else if (ps === '/a' || ps.indexOf('/a/') === 0) {
    backend = 'a';                                  // 3. path
  } else if (ps === '/b' || ps.indexOf('/b/') === 0) {
    backend = 'b';
  } else if (ps === '/c' || ps.indexOf('/c/') === 0) {
    backend = 'c';
  }
}
context.setVariable('flow.backend', backend);
