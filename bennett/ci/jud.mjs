// CI stand-in for JUD's DocuSeal webhook inbox (services/jud-dashboard
// lib/signing/inbox.ts and policy.ts verifyWebhook in bennett-legal-ops): the
// same content-type, size, signature and envelope checks. GET /events lists what
// arrived, for the smoke test. Node standard library only.
import { createHash, createHmac, timingSafeEqual } from 'node:crypto';
import { createServer } from 'node:http';

const SECRET = process.env.WEBHOOK_SECRET ?? '';
const events = [];

function verify(raw, header, now = Date.now()) {
  if (!header || !/^\d+\.[a-f0-9]{64}$/.test(header)) return false;
  const [stamp, signature] = header.split('.');
  const timestamp = Number(stamp);
  if (!Number.isSafeInteger(timestamp) || Math.abs(Math.floor(now / 1000) - timestamp) > 300) return false;
  if (!SECRET.startsWith('whsec_') || SECRET.length < 32) return false;
  const message = Buffer.concat([Buffer.from(`${timestamp}.`), raw]);
  return timingSafeEqual(createHmac('sha256', SECRET).update(message).digest(), Buffer.from(signature, 'hex'));
}

function envelope(payload) {
  const type = payload?.event_type;
  const record = typeof type === 'string' && type.startsWith('submission.') ? payload?.data?.id
    : payload?.data?.submission_id ?? payload?.data?.submission?.id;
  const valid = typeof type === 'string' && /^(?:submission|form)\.[a-z_]+$/.test(type) && Number.isSafeInteger(record)
    && record > 0 && typeof payload.timestamp === 'string' && Number.isFinite(Date.parse(payload.timestamp));
  return { type: typeof type === 'string' ? type : null, record: Number.isSafeInteger(record) ? record : null, valid };
}

createServer((request, response) => {
  const reply = (status, body) => {
    response.writeHead(status, { 'content-type': 'application/json' });
    response.end(JSON.stringify(body));
  };
  if (request.method === 'GET' && request.url === '/events') return reply(200, events);
  if (request.method !== 'POST' || request.url !== '/webhooks/docuseal') return reply(404, { error: 'NOT_FOUND' });
  if (!String(request.headers['content-type'] ?? '').toLowerCase().startsWith('application/json')) return reply(415, { error: 'EXPECTED_JSON' });
  const chunks = [];
  let size = 0;
  request.on('data', chunk => {
    size += chunk.length;
    if (size > 1_000_000) request.destroy();
    else chunks.push(chunk);
  });
  request.on('end', () => {
    const raw = Buffer.concat(chunks);
    const signed = verify(raw, request.headers['x-docuseal-signature']);
    let payload = null;
    try { payload = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(raw)); } catch { payload = null; }
    const { type, record, valid } = envelope(payload);
    const data = payload?.data ?? {};
    events.push({
      event_type: type, record_id: record, signature_valid: signed, envelope_valid: valid,
      sha256: createHash('sha256').update(raw).digest('hex'),
      // What JUD uses to bind practice and issuance events.
      variables: data.variables ?? data.submission?.variables ?? null,
      external_ids: [data.external_id, ...(Array.isArray(data.submitters) ? data.submitters.map(s => s?.external_id) : [])].filter(Boolean)
    });
    if (!signed) return reply(401, { error: 'INVALID_SIGNATURE' });
    if (!valid) return reply(400, { error: 'INVALID_EVENT_ENVELOPE' });
    return reply(200, { ok: true });
  });
}).listen(8090, '0.0.0.0', () => console.log(JSON.stringify({ jud: 'listening' })));
