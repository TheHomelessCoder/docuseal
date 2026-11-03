// Nightly smoke test of a Bennett DocuSeal image (started by run-smoke.sh).
//
// It plays three parts against the production-mode stack:
// - JUD: every DocuSeal call in bennett-legal-ops services/jud-dashboard
//   lib/signing (docuseal-client.ts), with the same headers and the same
//   checks JUD makes on the answers (worker.ts, practice.ts, policy.ts);
// - Cloudflare's visitors: what the gateway serves and refuses;
// - both signers, in a real browser, through the signing host.
// Everything is synthetic. Output: $SMOKE_DIR/out/results.json and screenshots.
import { createHash, randomUUID } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { request } from 'node:https';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { PDFDocument } from 'pdf-lib';
import { chromium } from 'playwright';

const HERE = dirname(fileURLToPath(import.meta.url));
const DIR = process.env.SMOKE_DIR;
const OUT = join(DIR, 'out');
mkdirSync(OUT, { recursive: true });
const run = JSON.parse(readFileSync(join(DIR, 'run.json'), 'utf8'));
const CA = readFileSync(join(DIR, 'tls', 'ca.pem'));
const GATEWAY = run.mode === 'gateway';
const SIGN = run.signHost;
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const results = [];

function check(name, ok, detail) {
  results.push({ name, ok: Boolean(ok), ...(detail === undefined ? {} : { detail }) });
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${detail === undefined || ok ? '' : ` — ${typeof detail === 'string' ? detail : JSON.stringify(detail)}`}`);
  return Boolean(ok);
}
function skip(name, reason) {
  results.push({ name, ok: true, skipped: reason });
  console.log(`skip ${name} — ${reason}`);
}
const openPages = [];
async function step(name, body) {
  try {
    return await body();
  } catch (error) {
    check(name, false, error.message.split('\n')[0]);
    for (const [label, page] of openPages) await screenshot(page, `failed-${label}`);
    return undefined;
  }
}
async function until(probe, timeout, what, interval = 1000) {
  const end = Date.now() + timeout;
  let last;
  while (Date.now() < end) {
    try {
      const value = await probe();
      if (value) return value;
    } catch (error) {
      last = error;
    }
    await sleep(interval);
  }
  throw new Error(`timed out waiting for ${what}${last ? ` (${last.message})` : ''}`);
}

// --- Transport: TLS to the edge on 127.0.0.1:443, by hostname ---------------
function https(method, host, path, { headers = {}, body, servername = host } = {}) {
  return new Promise((resolve, reject) => {
    const outgoing = request({
      hostname: '127.0.0.1', port: 443, method, path, ca: CA, servername,
      headers: { host, ...headers, ...(body === undefined ? {} : { 'content-length': Buffer.byteLength(body) }) }
    }, response => {
      const chunks = [];
      response.on('data', chunk => chunks.push(chunk));
      response.on('end', () => resolve({ status: response.statusCode, headers: response.headers, body: Buffer.concat(chunks) }));
    });
    outgoing.setTimeout(120_000, () => outgoing.destroy(new Error(`timeout ${method} ${host}`)));
    outgoing.on('error', reject);
    outgoing.end(body);
  });
}

// --- JUD's client (docuseal-client.ts DocuSealClient) -----------------------
const judHeaders = () => ({
  'X-Auth-Token': run.apiToken, 'Content-Type': 'application/json', Accept: 'application/json',
  'CF-Access-Client-Id': run.accessClientId, 'CF-Access-Client-Secret': run.accessClientSecret
});
async function api(method, path, body) {
  const response = await https(method, run.apiHost, `/api${path}`, { headers: judHeaders(), body: body === undefined ? undefined : JSON.stringify(body) });
  if (response.status < 200 || response.status > 299) throw new Error(`DOCUSEAL_HTTP_${response.status} ${method} /api${path.split('?')[0]}`);
  if (response.body.length > 2_000_000) throw new Error('PROVIDER_RESPONSE_TOO_LARGE');
  return JSON.parse(response.body.toString('utf8'));
}
const jud = {
  template: id => api('GET', `/templates/${id}`),
  templateHasSubmissions: async (id, archived) => {
    const value = await api('GET', `/submissions?template_id=${id}&archived=${archived}&limit=1`);
    if (!Array.isArray(value.data)) throw new Error('INVALID_TEMPLATE_SUBMISSION_SEARCH');
    return value.data.length > 0;
  },
  updateDraftTemplate: (id, update) => api('PUT', `/templates/${id}`, update),
  clone: (id, name, externalId, folder = 'JUD issuance snapshots') => api('POST', `/templates/${id}/clone`, { name, external_id: externalId, folder_name: folder }),
  stampPracticeClone: (clone, fields) => api('PUT', `/templates/${clone.id}`, { fields, shared_link: false }),
  create: async body => {
    const value = await api('POST', '/submissions', body);
    if (!Array.isArray(value) || value.length === 0) throw new Error('INVALID_CREATE_RESPONSE');
    return value;
  },
  submission: id => api('GET', `/submissions/${id}?include=fields,combined_document_url`),
  findSubmitters: async externalId => {
    const value = await api('GET', `/submitters?external_id=${encodeURIComponent(externalId)}&limit=100`);
    if (!Array.isArray(value.data)) throw new Error('INVALID_SUBMITTER_SEARCH');
    return value;
  },
  invite: id => api('PUT', `/submitters/${id}`, { send_email: true }),
  expire: (id, expiry) => api('PUT', `/submissions/${id}`, { expire_at: expiry })
};
function trustedDocumentUrl(value) {
  const url = new URL(value);
  if (url.origin !== `https://${SIGN}` || url.username || url.password || url.hash || url.search
    || !/^\/(?:file|blobs_proxy)\/[^/]+\/[^/]+/.test(url.pathname) || url.pathname.includes('..')) throw new Error('UNTRUSTED_DOCUMENT_URL');
  return url;
}
// JUD's pdf(): the signing origin, no credentials, no redirects.
async function pdf(value) {
  const url = trustedDocumentUrl(value);
  const response = await https('GET', url.hostname, url.pathname, { headers: { Accept: 'application/pdf' } });
  if (response.status !== 200 || String(response.headers['content-type'] ?? '').split(';')[0] !== 'application/pdf') {
    throw new Error(`INVALID_PDF_RESPONSE ${response.status} ${response.headers['content-type'] ?? ''}`);
  }
  if (response.body.subarray(0, 5).toString('latin1') !== '%PDF-') throw new Error('INVALID_PDF_BYTES');
  return response.body;
}
function providerBlobIdentity(value) {
  const url = trustedDocumentUrl(value);
  const token = decodeURIComponent(url.pathname.split('/')[2]);
  const [encoded, signature, extra] = token.split('--');
  if (!encoded || !/^[a-f0-9]{40,64}$/.test(signature ?? '') || extra) throw new Error('INVALID_PROVIDER_BLOB_CAPABILITY');
  const payload = JSON.parse(Buffer.from(encoded, 'base64url').toString('utf8'));
  if (!(Array.isArray(payload) && payload.length >= 2 && payload.length <= 3 && payload[1] === 'blob'
    && typeof payload[0] === 'string' && /^[a-f0-9-]{36}$/.test(payload[0]))) throw new Error('INVALID_PROVIDER_BLOB_CAPABILITY');
  return `${url.origin}:${payload[0]}`;
}

// --- JUD's policy helpers (policy.ts, practice.ts), synthetic manifest -------
const sha256 = value => createHash('sha256').update(value).digest('hex');
function canonical(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  return `{${Object.entries(value).filter(([, v]) => v !== undefined).sort(([a], [b]) => a.localeCompare(b))
    .map(([k, v]) => `${JSON.stringify(k)}:${canonical(v)}`).join(',')}}`;
}
function templateProjection(template, hashes) {
  const replacements = new Map();
  template.submitters.forEach((role, i) => replacements.set(role.uuid, `role:${i}`));
  template.fields.forEach((field, i) => replacements.set(field.uuid, `field:${i}`));
  template.schema.forEach((item, i) => { if (typeof item.attachment_uuid === 'string') replacements.set(item.attachment_uuid, `document:${i}`); });
  const normalize = value => {
    if (typeof value === 'string') return replacements.get(value) ?? value;
    if (Array.isArray(value)) return value.map(normalize);
    if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, normalize(v)]));
    return value;
  };
  return normalize({ name: template.name, fields: template.fields, submitters: template.submitters, schema: template.schema,
    preferences: template.preferences, variables_schema: template.variables_schema, documents: hashes });
}
const MANIFEST = {
  language: 'es',
  roles: [{ role: 'Client', source: 'client', email2fa: true }, { role: 'Attorney', source: 'firm', email2fa: true }],
  fields: [
    { role: 'Client', name: 'FullName', source: 'client_name' }, { role: 'Client', name: 'attorney_fee', source: 'attorney_fee' },
    { role: 'Client', name: 'Consent', source: 'consent' }, { role: 'Client', name: 'Signature', source: 'signer' },
    { role: 'Client', name: 'DateSigned', source: 'signing_date' },
    { role: 'Attorney', name: 'AttorneySignature', source: 'signer' }, { role: 'Attorney', name: 'AttorneyDate', source: 'signing_date' }
  ],
  consent: { version: 'ci-consent-1', language: 'es' }
};
function prefillFields(snapshot, template) {
  return template.fields.map(field => {
    const role = template.submitters.find(r => r.uuid === field.submitter_uuid)?.name;
    const binding = MANIFEST.fields.find(f => f.role === role && f.name === field.name);
    if (!binding) throw new Error('UNMAPPED_TEMPLATE_FIELD');
    if (binding.source === 'consent') {
      const { default_value: _unchecked, ...unchecked } = field;
      return { ...unchecked, readonly: false, required: true };
    }
    if (binding.source === 'signer') return { ...field, readonly: false, required: true };
    const value = binding.source === 'signing_date' ? '{{date}}' : binding.source === 'client_name' ? snapshot.clientName : '3,000';
    return { ...field, readonly: true, required: true, default_value: value };
  });
}
function workerSubmitters(snapshot, clone) {
  const bound = prefillFields(snapshot, clone);
  return snapshot.recipients.map(recipient => {
    const role = clone.submitters.find(r => r.name === recipient.role);
    return { role: recipient.role, uuid: role.uuid, name: recipient.name, email: recipient.email,
      external_id: recipient.externalId, require_email_2fa: recipient.email2fa, send_email: false, send_sms: false,
      metadata: { lang: MANIFEST.language, bennett_consent_version: MANIFEST.consent.version,
        bennett_consent_language: MANIFEST.consent.language, bennett_consent_sha256: snapshot.consentSha256 },
      fields: bound.filter(f => f.submitter_uuid === role.uuid).map(f => ({ uuid: f.uuid, readonly: f.readonly ?? false,
        required: f.required ?? false, ...(f.type === 'checkbox' ? { default_value: false }
          : f.default_value === undefined ? {} : { default_value: f.default_value }) })) };
  });
}
// worker.ts verifySubmission: the problems JUD would refuse, empty if none.
function submissionProblems(snapshot, clone, submission) {
  const problems = [];
  if (!(submission.template?.id === clone.id && submission.variables?.bennett_issuance_id === snapshot.issuanceId
    && Date.parse(submission.expire_at ?? '') === Date.parse(snapshot.expiresAt))) problems.push('SUBMISSION_IDENTITY_MISMATCH');
  if (!Array.isArray(submission.submitters) || submission.submitters.length !== snapshot.recipients.length) problems.push('SIGNER_INVENTORY_MISMATCH');
  for (const recipient of snapshot.recipients) {
    const matches = (submission.submitters ?? []).filter(s => s.role === recipient.role && s.external_id === recipient.externalId
      && s.name === recipient.name && s.email?.trim().toLowerCase() === recipient.email && s.submission_id === submission.id);
    if (matches.length !== 1) { problems.push(`SIGNER_IDENTITY_MISMATCH ${recipient.role}`); continue; }
    if (matches[0].uuid !== clone.submitters.find(role => role.name === recipient.role)?.uuid) problems.push('SIGNER_ROLE_UUID_MISMATCH');
    if (matches[0].preferences?.require_email_2fa !== recipient.email2fa) problems.push('SIGNER_AUTHENTICATION_CHANGED');
    const metadata = matches[0].metadata;
    if (!(metadata?.bennett_consent_version === MANIFEST.consent.version && metadata?.bennett_consent_language === MANIFEST.consent.language
      && metadata?.bennett_consent_sha256 === snapshot.consentSha256 && metadata?.lang === MANIFEST.language)) problems.push('SIGNER_CONSENT_CONTEXT_CHANGED');
  }
  if (canonical(submission.fields) !== canonical(prefillFields(snapshot, clone))) problems.push('ISSUED_FIELDS_DRIFT');
  return problems;
}
const PRACTICE_CLONE_PREFIX = 'PRACTICE — NOT A CONTRACT — ';
const STAMP_AREAS = [{ x: 0.5, y: 0.006, w: 0.46, h: 0.026 }, { x: 0.05, y: 0.962, w: 0.9, h: 0.03 }];
function practiceStampField(roleUuid, documents) {
  return { uuid: randomUUID(), submitter_uuid: roleUuid, name: 'PracticeStamp', type: 'text', required: false, readonly: true,
    default_value: 'PRACTICE — NOT A CONTRACT',
    preferences: { font_size: 12, font_type: 'bold', color: '#C00000', align: 'center', valign: 'center' },
    areas: documents.flatMap(d => Array.from({ length: d.pages }, (_, page) => STAMP_AREAS.map(area => ({ ...area, page, attachment_uuid: d.uuid }))).flat()) };
}
function stampProblems(clone, stamped, stamp) {
  const found = stamped.fields.filter(f => f.uuid === stamp.uuid || f.name === 'PracticeStamp');
  const rest = stamped.fields.filter(f => !found.includes(f));
  const problems = [];
  if (!(stamped.id === clone.id && stamped.name === clone.name)) problems.push('identity');
  if (found.length !== 1 || canonical(found[0]) !== canonical(stamp)) problems.push('stamp not stored exactly as sent');
  if (canonical(rest) !== canonical(clone.fields)) problems.push('other fields changed');
  if (canonical(stamped.submitters) !== canonical(clone.submitters)) problems.push('roles changed');
  if (canonical(stamped.schema) !== canonical(clone.schema)) problems.push('schema changed');
  if (canonical(stamped.documents.map(d => [d.uuid, d.filename])) !== canonical(clone.documents.map(d => [d.uuid, d.filename]))) problems.push('documents changed');
  return { problems, rest };
}
const missing = (object, keys) => keys.filter(key => !(object && Object.hasOwn(object, key)));

// --- Mail (Mailpit) and webhooks (jud stand-in) ------------------------------
async function mail(address, subject, after, timeout = 120_000) {
  return until(async () => {
    const list = await (await fetch('http://127.0.0.1:8025/api/v1/messages?limit=200')).json();
    const found = list.messages.find(m => m.To.some(to => to.Address.toLowerCase() === address)
      && Date.parse(m.Created) >= after - 2000 && subject.test(m.Subject));
    return found && (await fetch(`http://127.0.0.1:8025/api/v1/message/${found.ID}`)).json();
  }, timeout, `email ${subject} to ${address}`);
}
const signerLink = message => (message.HTML + message.Text).match(new RegExp(`https://${SIGN.replaceAll('.', '\\.')}/s/[A-Za-z0-9_-]{8,128}`))?.[0];
const events = async () => (await fetch('http://127.0.0.1:8090/events')).json();

// --- Browser -----------------------------------------------------------------
let shot = 0;
const screenshot = (page, label) => page.screenshot({ path: join(OUT, `${String(++shot).padStart(2, '0')}-${label}.png`), fullPage: false }).catch(() => undefined);
function watch(page) {
  const seen = { problems: [], refused: [], assets: {} };
  page.on('pageerror', error => seen.problems.push(`pageerror: ${error.message.slice(0, 200)}`));
  page.on('console', message => { if (/Content Security Policy|Refused to/i.test(message.text())) seen.problems.push(message.text().slice(0, 200)); });
  page.on('response', response => {
    const url = new URL(response.url());
    if (url.hostname !== SIGN) return;
    if (/\/packs\/bennett-|\/fonts\/bennett-/.test(url.pathname)) seen.assets[url.pathname] = response.status();
    if (response.status() >= 400) seen.refused.push(`${response.status()} ${response.request().method()} ${url.pathname.replace(/\/s\/[^/]+/, '/s/<slug>').slice(0, 80)}`);
  });
  return seen;
}
async function drawSignature(page, canvas) {
  const box = await canvas.boundingBox();
  const points = Array.from({ length: 30 }, (_, i) => [box.x + 30 + i * (box.width - 60) / 30, box.y + box.height * (0.45 + 0.15 * Math.sin(i / 3))]);
  await page.mouse.move(...points[0]);
  await page.mouse.down();
  for (const [x, y] of points.slice(1)) await page.mouse.move(x, y, { steps: 2 });
  await page.mouse.up();
}
async function passEmailCode(page, email, label) {
  const send = page.locator('button, input[type=submit]').filter({ hasText: /verification code|código|codigo/i }).first();
  await send.waitFor({ state: 'visible', timeout: 30_000 });
  await screenshot(page, `${label}-code`);
  const since = Date.now();
  await send.click();
  const message = await mail(email, /verification code|código de verificación/i, since);
  check(`${label}: verification email is Bennett-branded`, /Bennett Legal/.test(message.Subject), message.Subject);
  const code = message.Text.match(/\b\d{6}\b/)?.[0];
  const input = page.locator('input[name="one_time_code"], input[autocomplete="one-time-code"]').first();
  await input.fill(code ?? '');
  await Promise.all([page.waitForNavigation({ waitUntil: 'load', timeout: 60_000 }), input.press('Enter')]);
  if (await page.locator('input[name="one_time_code"]').count()) throw new Error(`${label}: verification code refused`);
}
async function completeForm(page, label) {
  await page.waitForSelector('submission-form', { state: 'attached', timeout: 60_000 });
  await sleep(1500);
  const expand = page.locator('#expand_form_button');
  if (await expand.isVisible().catch(() => false)) await expand.click();
  const form = page.locator('#form_container');
  for (let i = 0; i < 12 && !(await page.locator('#form_completed').count()); i++) {
    const canvas = form.locator('canvas').first();
    if (await canvas.isVisible().catch(() => false)) {
      await screenshot(page, `${label}-sign`);
      await drawSignature(page, canvas);
    }
    const box = form.locator('input[type=checkbox]').first();
    if (await box.isVisible().catch(() => false) && !(await box.isChecked())) await box.check();
    const next = page.locator('#submit_form_button');
    if (!(await next.isVisible().catch(() => false))) { await sleep(1000); continue; }
    await next.click();
    await sleep(2000);
  }
  await page.waitForSelector('#form_completed', { state: 'attached', timeout: 60_000 });
  await screenshot(page, `${label}-done`);
}

// =============================================================================
const started = Date.now();
const browser = await chromium.launch({ args: [`--host-resolver-rules=MAP ${SIGN} 127.0.0.1, MAP ${run.apiHost} 127.0.0.1, MAP ${run.staffHost} 127.0.0.1`] });
// One browser per signer, as in life: DocuSeal keeps a single verification cookie per browser.
const signerContext = () => browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1280, height: 900 }, locale: 'en-US' });
const clientContext = await signerContext();
const attorneyContext = await signerContext();
try {
  // 1. What the gateway serves and refuses (production path only).
  for (const asset of ['/packs/bennett-signing-v1.css', '/packs/bennett-signing-v1.js', '/packs/bennett-legal-logo-white.png',
    '/fonts/bennett-jost-latin.woff2', '/fonts/bennett-noto-serif-latin.woff2']) {
    const response = await https('GET', SIGN, asset);
    check(`signer asset ${asset} is served`, response.status === 200 && response.body.length > 100, response.status);
  }
  if (GATEWAY) {
    const refused = [
      ['signing host /setup', 'GET', SIGN, '/setup', {}, [404]],
      ['signing host /api', 'GET', SIGN, '/api/templates', { 'X-Auth-Token': run.apiToken }, [404]],
      ['signing host admin sign-in', 'GET', SIGN, '/sign_in', {}, [404]],
      ['asset write', 'POST', SIGN, '/packs/bennett-signing-v1.css', {}, [404]],
      ['staff host without Access', 'GET', run.staffHost, '/', {}, [403]],
      ['API host without the DocuSeal token', 'GET', run.apiHost, '/api/templates', { ...judHeaders(), 'X-Auth-Token': '' }, [404]],
      ['API host without an Access assertion', 'GET', run.apiHost, '/api/templates', { ...judHeaders(), 'x-ci-without-access': '1' }, [404]],
      ['unknown host', 'GET', 'unknown.ci.test', '/', {}, [404]]
    ];
    for (const [label, method, host, path, headers, want] of refused) {
      const { status } = await https(method, host, path, { headers, servername: host === 'unknown.ci.test' ? SIGN : host, body: method === 'POST' ? '' : undefined });
      check(`gateway refuses ${label}`, want.includes(status), status);
    }
  } else {
    skip('gateway refusals', 'no gateway image (direct mode)');
  }

  // 2. JUD reads the approved template and its PDF.
  const template = await jud.template(run.templateId);
  check('template read has the fields, roles and documents JUD uses',
    !missing(template, ['id', 'name', 'fields', 'submitters', 'schema', 'preferences', 'documents', 'external_id', 'shared_link']).length
    && template.documents.every(d => !missing(d, ['uuid', 'url', 'filename']).length), missing(template, ['id', 'name', 'fields', 'submitters', 'schema', 'preferences', 'documents']));
  check('template keeps recipient order preserved', template.preferences?.submitters_order === 'preserved', template.preferences);
  check('template roles are Client then Attorney', canonical(template.submitters.map(r => r.name)) === canonical(['Client', 'Attorney']));
  const projection = templateProjection(template, [{ filename: template.documents[0]?.filename, sha256: 'pinned-document' }]);
  writeFileSync(join(OUT, 'template-projection.json'), `${JSON.stringify(projection, null, 2)}\n`);
  const expectedFile = join(HERE, 'expected', 'template-projection.json');
  if (existsSync(expectedFile)) {
    // JUD pins sha256(canonical(templateProjection)) at enrollment; any change
    // in how DocuSeal returns a template makes every approved template drift.
    const expected = JSON.parse(readFileSync(expectedFile, 'utf8'));
    check('template representation matches the pinned one (JUD LIVE_TEMPLATE_DRIFT)', canonical(projection) === canonical(expected),
      'compare out/template-projection.json with bennett/ci/expected/template-projection.json');
  } else {
    skip('template representation pin', 'no bennett/ci/expected/template-projection.json yet');
  }
  const documentBytes = await pdf(template.documents[0].url);
  check('template PDF downloads through the signing host unchanged (JUD LIVE_DOCUMENT_DRIFT)', sha256(documentBytes) === run.documentSha256);
  await step('document link is a provider blob capability JUD accepts', async () => check('document link is a provider blob capability JUD accepts', providerBlobIdentity(template.documents[0].url)));
  check('approved template has no submissions', !(await jud.templateHasSubmissions(template.id, false)) && !(await jud.templateHasSubmissions(template.id, true)));

  // 3. Draft import (retainer-import.ts): one supported PUT, then a re-read.
  await step('draft import PUT', async () => {
    const draft = await jud.template(run.draftId);
    const [client, attorney] = draft.submitters;
    const area = (page, y) => ({ attachment_uuid: draft.schema[0].attachment_uuid, page, x: 0.1, y, w: 0.35, h: 0.06 });
    const update = {
      shared_link: false, submitters: draft.submitters,
      fields: [
        { uuid: randomUUID(), submitter_uuid: client.uuid, name: 'Signature', type: 'signature', required: true, areas: [area(1, 0.3)] },
        { uuid: randomUUID(), submitter_uuid: attorney.uuid, name: 'AttorneySignature', type: 'signature', required: true, areas: [area(1, 0.6)] }
      ]
    };
    if (await jud.templateHasSubmissions(draft.id, false) || await jud.templateHasSubmissions(draft.id, true)) throw new Error('ISSUED_TEMPLATE_CANNOT_BE_EDITED');
    await jud.updateDraftTemplate(draft.id, update);
    const result = await jud.template(draft.id);
    const hashes = [{ filename: draft.documents[0].filename, sha256: 'pinned-document' }];
    check('draft import PUT stores exactly the planned fields (JUD DRAFT_IMPORT_WRITE_REQUIRES_REVIEW)',
      canonical(templateProjection(result, hashes)) === canonical(templateProjection({ ...draft, ...update }, hashes))
      && result.id === draft.id && !result.archived_at && result.shared_link === false);
    check('draft PDF unchanged after the import PUT', sha256(await pdf(result.documents[0].url)) === run.documentSha256);
  });

  // 4. Issuance (worker.ts issue): clone, create without email, verify, invite.
  const issuanceId = randomUUID();
  const snapshot = {
    issuanceId, clientName: 'Cliente Sintético CI', consentSha256: sha256('ci-consent-1'), expiresAt: new Date(Date.now() + 7 * 86400_000).toISOString(),
    recipients: [
      { role: 'Client', name: 'Cliente Sintético CI', email: `client-${issuanceId.slice(0, 8)}@example.test`, email2fa: true, externalId: `${issuanceId}:0` },
      { role: 'Attorney', name: 'Abogado Sintético CI', email: `attorney-${issuanceId.slice(0, 8)}@example.test`, email2fa: true, externalId: `${issuanceId}:1` }
    ]
  };
  const clone = await jud.clone(template.id, template.name, issuanceId);
  check('clone keeps name, external ID and the exact template representation',
    clone.id !== template.id && clone.name === template.name && clone.external_id === issuanceId
    && canonical(templateProjection(clone, [])) === canonical(templateProjection(template, [])));
  check('clone PDF is the approved PDF', sha256(await pdf(clone.documents[0].url)) === run.documentSha256);
  const created = await jud.create({ template_id: clone.id, send_email: false, send_sms: false, submitters_order: 'preserved',
    expire_at: snapshot.expiresAt, variables: { bennett_issuance_id: issuanceId }, submitters: workerSubmitters(snapshot, clone) });
  const submissionId = created[0]?.submission_id;
  check('create returns both signers of one submission', created.length === 2 && created.every(s => s.submission_id === submissionId)
    && Number.isSafeInteger(submissionId) && created.every(s => s.slug && !missing(s, ['id', 'uuid', 'email', 'external_id']).length));
  const issued = await jud.submission(submissionId);
  check('submission read has what JUD reads', !missing(issued, ['id', 'template', 'status', 'completed_at', 'expire_at', 'submission_events', 'submitters', 'fields', 'variables', 'documents', 'audit_log_url']).length
    && issued.submitters.every(s => !missing(s, ['id', 'submission_id', 'uuid', 'role', 'name', 'email', 'external_id', 'status', 'completed_at', 'declined_at', 'sent_at', 'values', 'preferences', 'metadata']).length),
  missing(issued, ['id', 'template', 'status', 'submission_events', 'submitters', 'fields', 'variables', 'documents', 'audit_log_url']));
  const issueProblems = submissionProblems(snapshot, clone, issued);
  check('issued submission passes JUD verifySubmission', issueProblems.length === 0, issueProblems);
  const lookup = await jud.findSubmitters(snapshot.recipients[0].externalId);
  check('submitter lookup by external ID finds exactly the client', lookup.data.length === 1 && lookup.data[0].submission_id === submissionId
    && Object.hasOwn(lookup.pagination ?? {}, 'next'));
  const [clientCreated, attorneyCreated] = snapshot.recipients.map(r => created.find(s => s.external_id === r.externalId));

  // 5. Recipient order (Bennett patch): the attorney passes the email code,
  //    then may not change the submission before the client finishes.
  const attorneyPage = await attorneyContext.newPage();
  const attorneySeen = watch(attorneyPage);
  openPages.push(['attorney', attorneyPage]);
  await step('attorney cannot sign before the client', async () => {
    await attorneyPage.goto(`https://${SIGN}/s/${attorneyCreated.slug}`, { waitUntil: 'load' });
    await passEmailCode(attorneyPage, snapshot.recipients[1].email, 'attorney-early');
    await screenshot(attorneyPage, 'attorney-early-awaiting');
    check('attorney sees the awaiting page before the client signs', !(await attorneyPage.locator('submission-form').count()));
    // An empty write: upstream alone answers 200 here; only the Bennett
    // recipient-order check refuses it, with its 422 authorization error.
    const outcome = await attorneyPage.evaluate(async slug => {
      const token = document.querySelector('meta[name="csrf-token"]')?.content ?? '';
      const response = await fetch(`/s/${slug}`, { method: 'POST', body: new URLSearchParams({ _method: 'put', authenticity_token: token }),
        headers: { 'X-CSRF-Token': token, Accept: 'application/json' } });
      let json = null;
      try { json = await response.json(); } catch { json = null; }
      return { status: response.status, token: token.length > 0, error: typeof json?.error === 'string', field: Boolean(json?.field_uuid) };
    }, attorneyCreated.slug);
    const after = await jud.submission(submissionId);
    const attorney = after.submitters.find(s => s.id === attorneyCreated.id);
    check('attorney write before the client finishes is refused (Bennett recipient-order patch)',
      outcome.token && outcome.status === 422 && outcome.error && !outcome.field && !attorney.completed_at, outcome);
    attorneySeen.refused.length = 0; // that 422 was the point
  });

  // 6. Invite and sign as the client (Spanish from the signer's metadata).
  const clientPage = await clientContext.newPage();
  const clientSeen = watch(clientPage);
  openPages.push(['client', clientPage]);
  await step('client signs', async () => {
    const since = Date.now();
    await jud.invite(clientCreated.id);
    const invitation = await mail(snapshot.recipients[0].email, /listo para firmar|ready to sign/i, since);
    check('client invitation is Bennett-branded and in Spanish', invitation.Subject === 'Su contrato de Bennett Legal está listo para firmar', invitation.Subject);
    const link = signerLink(invitation);
    check('invitation links the signing host and this signer', link === `https://${SIGN}/s/${clientCreated.slug}`);
    const response = await clientPage.goto(link, { waitUntil: 'load' });
    const headers = response.headers();
    const page = await clientPage.evaluate(() => ({
      lang: document.documentElement.lang, title: document.title,
      noindex: document.querySelector('meta[name="robots"]')?.content ?? '',
      logo: document.querySelector('.bennett-masthead__logo')?.naturalWidth ?? 0,
      vendor: document.querySelector('.bennett-masthead__vendor')?.textContent.trim() ?? '',
      vendorHref: document.querySelector('.bennett-masthead__vendor')?.getAttribute('href') ?? ''
    }));
    check('signer page follows the signer\'s language (es)', page.lang.startsWith('es'), page.lang);
    check('signer page is Bennett-branded with DocuSeal attribution', page.title.includes('Bennett Legal') && page.logo > 0
      && page.vendor === 'DocuSeal' && /docuseal/i.test(page.vendorHref) && page.noindex.includes('noindex'), page);
    if (GATEWAY) {
      const csp = String(headers['content-security-policy'] ?? '');
      check('signer page security headers', headers['x-frame-options'] === 'DENY' && csp.includes("frame-ancestors 'none'")
        && /max-age=\d+/.test(headers['strict-transport-security'] ?? '') && /no-store/.test(headers['cache-control'] ?? ''),
      { xfo: headers['x-frame-options'], hsts: Boolean(headers['strict-transport-security']), cache: headers['cache-control'] });
    } else {
      skip('signer page security headers', 'no gateway image (direct mode)');
    }
    await passEmailCode(clientPage, snapshot.recipients[0].email, 'client');
    const cookies = await clientContext.cookies(`https://${SIGN}`);
    check('signer cookies are Secure', cookies.length > 0 && cookies.every(c => c.secure), cookies.map(c => [c.name.slice(0, 16), c.secure, c.httpOnly]));
    await completeForm(clientPage, 'client');
    const after = await until(async () => {
      const value = await jud.submission(submissionId);
      return value.submitters.find(s => s.id === clientCreated.id)?.completed_at && value;
    }, 60_000, 'client completion');
    const client = after.submitters.find(s => s.id === clientCreated.id);
    const values = Object.fromEntries((client.values ?? []).map(v => [v.field, v.value]));
    check('client completion recorded with consent, signature, locked name and date',
      client.status === 'completed' && values.Consent === true && Boolean(values.Signature) && values.FullName === snapshot.clientName
      && values.attorney_fee === '3,000' && values.DateSigned && values.DateSigned !== '{{date}}',
    { status: client.status, consent: values.Consent, signature: Boolean(values.Signature), date: values.DateSigned });
  });
  check('client browser saw the Bennett assets', ['/packs/bennett-signing-v1.css', '/packs/bennett-signing-v1.js'].every(p => clientSeen.assets[p] === 200), clientSeen.assets);

  // 7. The attorney is invited once the client finished, and signs.
  await step('attorney signs', async () => {
    const since = Date.now();
    await jud.invite(attorneyCreated.id);
    const invitation = await mail(snapshot.recipients[1].email, /listo para firmar|ready to sign/i, since);
    check('attorney invitation links the signing host and this signer', signerLink(invitation) === `https://${SIGN}/s/${attorneyCreated.slug}`);
    await attorneyPage.goto(signerLink(invitation), { waitUntil: 'load' });
    // The code the attorney entered earlier still holds in this browser.
    const asked = await attorneyPage.locator('button, input[type=submit]').filter({ hasText: /verification code|código|codigo/i }).first().isVisible().catch(() => false);
    check('attorney is not asked for a second code in the same browser', !asked);
    if (asked) await passEmailCode(attorneyPage, snapshot.recipients[1].email, 'attorney');
    await completeForm(attorneyPage, 'attorney');
  });
  check('signer pages had no CSP violations, script errors or refused requests',
    [clientSeen, attorneySeen].every(seen => !seen.problems.length && !seen.refused.length),
    { problems: [...clientSeen.problems, ...attorneySeen.problems], refused: [...clientSeen.refused, ...attorneySeen.refused] });

  // 8. Completion: signed PDF, audit log, events, copies (worker.ts reconcile).
  await step('completed submission', async () => {
    const done = await until(async () => {
      const value = await jud.submission(submissionId);
      return value.status === 'completed' && value.documents?.length && value.audit_log_url && value;
    }, 240_000, 'signed documents and audit log', 3000);
    check('submission completed with signed documents and an audit log', done.completed_at && done.submitters.every(s => s.status === 'completed'));
    const signed = await pdf(done.documents[0].url);
    const text = signed.toString('latin1');
    const pages = (await PDFDocument.load(signed, { updateMetadata: false })).getPageCount();
    check('signed PDF carries a digital signature and every page', text.includes('/ByteRange') && /\/Type\s*\/Sig\b/.test(text) && pages === run.pages, { pages });
    const audit = await pdf(done.audit_log_url);
    check('audit log is a PDF', audit.length > 1000);
    const problems = submissionProblems(snapshot, clone, done);
    check('completed submission still passes JUD verifySubmission', problems.length === 0, problems);
    const received = await until(async () => {
      const list = await events();
      const ours = list.filter(e => e.record_id === submissionId);
      return ours.filter(e => e.event_type === 'form.completed').length >= 2 && ours.some(e => e.event_type === 'submission.completed') && ours;
    }, 120_000, 'webhooks');
    check('JUD receives form.completed for each signer and submission.completed, all signed', received.every(e => e.signature_valid && e.envelope_valid),
      received.map(e => [e.event_type, e.signature_valid, e.envelope_valid]));
    check('webhooks carry the issuance binding JUD reads', received.some(e => e.variables?.bennett_issuance_id === issuanceId
      || e.external_ids.includes(snapshot.recipients[0].externalId)));
    const copy = await mail(snapshot.recipients[0].email, /firmado|signed/i, started, 120_000);
    check('client receives the Bennett signed copy in Spanish', copy.Subject === 'Su contrato firmado de Bennett Legal', copy.Subject);
  });

  // 9. Practice run (practice.ts): clone, stamp every page, re-read, send.
  await step('practice run', async () => {
    const runId = randomUUID();
    const title = `${PRACTICE_CLONE_PREFIX}${template.name}`;
    const practice = await jud.clone(template.id, title, `practice:${runId}`, 'JUD practice runs');
    check('practice clone has its practice identity', practice.name === title && practice.external_id === `practice:${runId}`);
    const documents = await Promise.all(practice.documents.map(async d => {
      const bytes = await pdf(d.url);
      if (sha256(bytes) !== run.documentSha256) throw new Error('LIVE_DOCUMENT_DRIFT');
      return { uuid: d.uuid, pages: (await PDFDocument.load(bytes, { updateMetadata: false })).getPageCount() };
    }));
    const stamp = practiceStampField(practice.submitters[0].uuid, documents);
    await jud.stampPracticeClone(practice, [...practice.fields, stamp]);
    const stamped = await jud.template(practice.id);
    const { problems, rest } = stampProblems(practice, stamped, stamp);
    check('practice-stamp PUT /api/templates/:id adds exactly the stamp (JUD PRACTICE_STAMP_NOT_APPLIED)', problems.length === 0 && documents.every(d => d.pages === run.pages), problems);
    const since = Date.now();
    const email = `practice-${runId.slice(0, 8)}@example.test`;
    const submitters = stamped.submitters.map((role, index) => ({
      role: role.name, uuid: role.uuid, name: index ? 'PRACTICE – Attorney' : 'PRACTICE – Sample Client',
      email: index ? `practice-attorney-${runId.slice(0, 8)}@example.test` : email, external_id: `practice:${runId}:${index}`,
      require_email_2fa: true, send_sms: false, metadata: { lang: 'en', bennett_practice: true },
      fields: [...prefillFields({ clientName: 'PRACTICE – Sample Client' }, { ...stamped, fields: rest }).filter(f => f.submitter_uuid === role.uuid)
        .map(f => ({ uuid: f.uuid, readonly: f.readonly ?? false, required: f.required ?? false,
          ...(f.type === 'checkbox' ? { default_value: false } : f.default_value === undefined ? {} : { default_value: f.default_value }) })),
      ...(role.uuid === stamp.submitter_uuid ? [{ uuid: stamp.uuid, readonly: true, required: false, default_value: stamp.default_value }] : [])]
    }));
    const sent = await jud.create({ template_id: practice.id, send_email: true, send_sms: false, submitters_order: 'preserved',
      expire_at: new Date(Date.now() + 7 * 86400_000).toISOString(), variables: { bennett_practice_run_id: runId }, submitters });
    check('practice submission created for both roles', sent.length === 2 && new Set(sent.map(s => s.submission_id)).size === 1);
    const read = await jud.submission(sent[0].submission_id);
    const stampField = read.fields.find(f => f.uuid === stamp.uuid);
    check('practice stamp is part of the issued fields', stampField?.readonly === true && stampField.default_value === 'PRACTICE — NOT A CONTRACT' && read.status !== 'completed');
    const invitation = await mail(email, /ready to sign/i, since);
    await sleep(5000);
    const list = await (await fetch('http://127.0.0.1:8025/api/v1/messages?limit=200')).json();
    const early = list.messages.filter(m => m.To.some(to => to.Address.toLowerCase() === submitters[1].email));
    check('practice invitation goes to the client role first, in English', invitation.Subject === 'Your Bennett Legal retainer is ready to sign'
      && early.length === 0, { subject: invitation.Subject, attorneyEmails: early.length });
  });

  // 10. Cancellation (worker.ts cancel): an explicit expiry update.
  await step('cancellation', async () => {
    const cancelId = randomUUID();
    const cancelClone = await jud.clone(template.id, template.name, cancelId);
    const cancelSnapshot = { ...snapshot, issuanceId: cancelId, recipients: snapshot.recipients.map((r, i) => ({ ...r, email: `cancel-${i}-${cancelId.slice(0, 8)}@example.test`, externalId: `${cancelId}:${i}` })) };
    const pending = await jud.create({ template_id: cancelClone.id, send_email: false, send_sms: false, submitters_order: 'preserved',
      expire_at: cancelSnapshot.expiresAt, variables: { bennett_issuance_id: cancelId }, submitters: workerSubmitters(cancelSnapshot, cancelClone) });
    const id = pending[0].submission_id;
    await jud.expire(id, new Date(Date.now() - 1000).toISOString());
    const after = await jud.submission(id);
    check('expiry update cancels the submission (JUD CANCELLATION_NOT_CONFIRMED)', after.status === 'expired' && !after.completed_at
      && Date.parse(after.expire_at ?? '') <= Date.now(), { status: after.status });
    check('approved template still has no submissions of its own', !(await jud.templateHasSubmissions(template.id, false)));
    check('the clone reports its submissions', await jud.templateHasSubmissions(cancelClone.id, false));
  });
} catch (error) {
  check('smoke test ran to the end', false, error.message);
} finally {
  await browser.close();
  const failed = results.filter(r => !r.ok);
  writeFileSync(join(OUT, 'results.json'), `${JSON.stringify({ mode: run.mode, seconds: Math.round((Date.now() - started) / 1000), passed: results.length - failed.length, failed: failed.length, results }, null, 2)}\n`);
  console.log(`\n${results.length - failed.length}/${results.length} checks passed in ${Math.round((Date.now() - started) / 1000)} s (${run.mode} mode)`);
  process.exitCode = failed.length ? 1 : 0;
}
