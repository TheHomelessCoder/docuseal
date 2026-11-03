// CI stand-in for Cloudflare in front of the signing gateway: TLS for the
// signing hostnames, Access in front of the API host (the JUD service token is
// checked here and replaced by a signed Cf-Access-Jwt-Assertion), the Access
// key set the gateway fetches, and the visitor IP header. In production the
// tunnel shares the gateway's loopback; so does this. Node standard library only.
import { generateKeyPairSync, randomUUID, sign, timingSafeEqual } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { request } from 'node:http';
import { createServer } from 'node:https';

const env = name => {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required`);
  return value;
};
const API = env('API_HOST');
const TEAM = `${env('CF_ACCESS_TEAM')}.cloudflareaccess.com`;
const API_AUD = env('CF_API_ACCESS_AUD');
const CLIENT_ID = env('CI_ACCESS_CLIENT_ID');
const CLIENT_SECRET = env('CI_ACCESS_CLIENT_SECRET');
const [UPSTREAM_HOST, UPSTREAM_PORT] = env('UPSTREAM').split(':');
const VISITOR = '203.0.113.10';
// Request headers a visitor may not pass through Cloudflare.
const HOP = new Set(['connection', 'keep-alive', 'proxy-connection', 'te', 'trailer', 'transfer-encoding', 'upgrade']);

const kid = randomUUID();
const { publicKey, privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
const keySet = JSON.stringify({ keys: [{ ...publicKey.export({ format: 'jwk' }), kid, alg: 'RS256', use: 'sig' }] });
const part = value => Buffer.from(JSON.stringify(value)).toString('base64url');

// The shape Cloudflare Access issues for a service token.
function accessToken(audience, commonName) {
  const now = Math.floor(Date.now() / 1000);
  const body = `${part({ alg: 'RS256', kid, typ: 'JWT' })}.${part({
    aud: [audience], iss: `https://${TEAM}`, sub: '', type: 'app', common_name: commonName,
    iat: now - 5, nbf: now - 5, exp: now + 600
  })}`;
  return `${body}.${sign('sha256', Buffer.from(body), privateKey).toString('base64url')}`;
}

function same(given, expected) {
  const a = Buffer.from(String(given ?? ''));
  const b = Buffer.from(expected);
  return a.length === b.length && timingSafeEqual(a, b);
}

const tls = { key: readFileSync('/run/ci/tls.key'), cert: readFileSync('/run/ci/tls.crt') };
createServer(tls, (incoming, outgoing) => {
  const host = String(incoming.headers.host ?? '').split(':')[0].toLowerCase();
  if (host === TEAM) {
    const found = incoming.method === 'GET' && incoming.url === '/cdn-cgi/access/certs';
    outgoing.writeHead(found ? 200 : 404, { 'content-type': 'application/json' });
    return outgoing.end(found ? keySet : '{}');
  }
  const headers = {};
  for (const [name, value] of Object.entries(incoming.headers)) {
    if (!HOP.has(name) && !name.startsWith('cf-') && !name.startsWith('x-ci-')) headers[name] = value;
  }
  headers['cf-connecting-ip'] = VISITOR;
  headers['x-forwarded-for'] = VISITOR;
  headers['x-forwarded-proto'] = 'https';
  if (host === API) {
    // Access refuses the API host without JUD's service token.
    if (!same(incoming.headers['cf-access-client-id'], CLIENT_ID) || !same(incoming.headers['cf-access-client-secret'], CLIENT_SECRET)) {
      outgoing.writeHead(403);
      return outgoing.end();
    }
    // Test hook: reach the gateway without an Access assertion.
    if (incoming.headers['x-ci-without-access'] !== '1') headers['cf-access-jwt-assertion'] = accessToken(API_AUD, CLIENT_ID);
  }
  const upstream = request({ host: UPSTREAM_HOST, port: Number(UPSTREAM_PORT), method: incoming.method, path: incoming.url, headers }, response => {
    const forwarded = { ...response.headers };
    for (const name of HOP) delete forwarded[name];
    outgoing.writeHead(response.statusCode, forwarded);
    response.pipe(outgoing);
  });
  upstream.setTimeout(150_000, () => upstream.destroy());
  upstream.on('error', () => {
    if (!outgoing.headersSent) outgoing.writeHead(502);
    outgoing.end();
  });
  incoming.pipe(upstream);
}).listen(443, '0.0.0.0', () => console.log(JSON.stringify({ edge: 'listening', upstream: env('UPSTREAM') })));
