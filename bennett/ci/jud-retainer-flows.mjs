// Fresh private-link JUD flows against the disposable production-mode stack.
// No live credentials, recipients or documents; all mail stays in Mailpit.
import { randomUUID } from 'node:crypto';
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { PDFDocument } from 'pdf-lib';

export async function runJudRetainerFlows(h) {
  const { run, OUT, SIGN, browser, check, step, jud, pdf, mail, signerLink,
    completeForm, events, watch, screenshot, letterhead, until, sha256 } = h;
  if (SIGN !== 'sign.ci.test' || run.apiHost !== 'sign-api.ci.test') throw new Error('Synthetic CI hosts required');
  const evidence = [];
  const demand = (name, ok, detail) => {
    if (!check(name, ok, detail)) throw new Error(name);
  };
  const mailbox = async address => {
    const response = await fetch('http://127.0.0.1:8025/api/v1/messages?limit=1000');
    if (!response.ok) throw new Error('Mailpit read failed');
    const list = await response.json();
    return list.messages.filter(m => m.To.some(to => to.Address.toLowerCase() === address));
  };
  const noCode = async page => (await page.locator('input[name="one_time_code"], input[autocomplete="one-time-code"]').count()) === 0
    && !(await page.locator('button, input[type=submit]').filter({ hasText: /verification code|código de verificación/i }).first().isVisible().catch(() => false));

  for (const language of ['en', 'es']) for (const mobile of [false, true]) {
    const label = `private-link-${language}-${mobile ? 'mobile' : 'desktop'}`;
    const contexts = [];
    const context = async () => {
      const value = await browser.newContext({ ignoreHTTPSErrors: true,
        viewport: mobile ? { width: 390, height: 844 } : { width: 1280, height: 900 },
        isMobile: mobile, hasTouch: mobile, locale: language === 'es' ? 'es-MX' : 'en-US' });
      contexts.push(value);
      return value;
    };
    await step(label, async () => {
      try {
        const since = Date.now(), issuanceId = randomUUID();
        const clientName = language === 'es' ? 'María Cliente Sintética' : 'Synthetic English Client';
        const reference = language === 'es' ? 'LEAD-2099-00001' : 'SOLAR-2099-00001';
        const recordUrl = language === 'es' ? `https://jud.bennettlegal.com/intake/leads#${reference}`
          : 'https://jud.bennettlegal.com/solar/cases/1';
        const recipients = ['Client', 'Attorney'].map((role, i) => ({ role,
          name: i ? 'Synthetic Attorney' : clientName, email: `${label}-${issuanceId.slice(0, 8)}-${i}@example.test`,
          externalId: `${issuanceId}:${i}` }));
        const source = await jud.template(run.templateId);
        const clone = await jud.clone(source.id, `${language.toUpperCase()} synthetic JUD agreement`, issuanceId);
        demand(`${label}: approved source bytes survive the clone`, sha256(await pdf(clone.documents[0].url)) === run.documentSha256);
        const bound = clone.fields.map(field => {
          const value = field.name === 'FullName' ? clientName : field.name === 'attorney_fee' ? '3,000'
            : field.type === 'date' ? '{{date}}' : field.type === 'checkbox' ? false : undefined;
          return { ...field, required: true, readonly: !['signature', 'checkbox'].includes(field.type),
            ...(value === undefined ? {} : { default_value: value }) };
        });
        const created = await jud.create({ template_id: clone.id, send_email: false, send_sms: false,
          submitters_order: 'preserved', expire_at: new Date(since + 7 * 86400_000).toISOString(),
          variables: { bennett_issuance_id: issuanceId }, submitters: recipients.map((recipient, index) => {
            const role = clone.submitters.find(r => r.name === recipient.role);
            return { role: recipient.role, uuid: role.uuid, name: recipient.name, email: recipient.email,
              external_id: recipient.externalId, require_email_2fa: false, send_email: false, send_sms: false,
              metadata: { lang: language, ...(index ? { bennett_jud_context: { version: 'jud-retainer-email/1',
                issuance_id: issuanceId, record_type: language === 'es' ? 'lead' : 'case', reference,
                url: recordUrl, client_name: clientName } } : {}) },
              fields: bound.filter(f => f.submitter_uuid === role.uuid).map(f => ({ uuid: f.uuid,
                readonly: f.readonly, required: f.required, ...(f.default_value === undefined ? {} : { default_value: f.default_value }) })) };
          }) });
        const submissionId = created[0].submission_id;
        const [client, attorney] = recipients.map(r => created.find(s => s.external_id === r.externalId));
        let issued = await jud.submission(submissionId);
        demand(`${label}: private-link authentication and locked fields are stored`, issued.submitters.every(s => s.preferences.require_email_2fa === false)
          && issued.fields.filter(f => ['FullName', 'attorney_fee'].includes(f.name)).every(f => f.readonly === true)
          && !issued.fields.some(f => /practice/i.test(f.name)) && !/practice/i.test(clone.name));

        const early = await (await context()).newPage();
        await early.goto(`https://${SIGN}/s/${attorney.slug}`, { waitUntil: 'load' });
        demand(`${label}: fresh attorney link waits without an email code`, await noCode(early) && !(await early.locator('submission-form').count()));
        for (const method of ['POST', 'PUT', 'PATCH']) {
          const outcome = await early.evaluate(async ({ slug, method }) => {
            const token = document.querySelector('meta[name="csrf-token"]')?.content ?? '';
            const body = new URLSearchParams({ authenticity_token: token, ...(method === 'POST' ? { _method: 'put' } : {}) });
            const response = await fetch(`/s/${slug}`, { method, body, headers: { 'X-CSRF-Token': token, Accept: 'application/json' } });
            return { status: response.status, csrf: Boolean(token) };
          }, { slug: attorney.slug, method });
          demand(`${label}: early attorney ${method} is refused`, outcome.csrf && outcome.status === 422, outcome);
        }
        const earlyDownload = await early.evaluate(async slug => (await fetch(`/s/${slug}/download`)).status, attorney.slug);
        demand(`${label}: early attorney download is refused`, earlyDownload === 422);
        issued = await jud.submission(submissionId);
        demand(`${label}: blocked writes leave both signers pending`, issued.submitters.every(s => !s.completed_at));

        await jud.invite(client.id);
        const invitation = await mail(recipients[0].email, /ready to sign|listo para firmar/i, since);
        demand(`${label}: client email has no internal case link`, !`${invitation.HTML}${invitation.Text}${invitation.Subject}`.includes(reference));
        demand(`${label}: attorney receives no invitation before client completion`, (await mailbox(recipients[1].email)).length === 0);
        const clientPage = await (await context()).newPage(), clientSeen = watch(clientPage);
        await clientPage.goto(signerLink(invitation), { waitUntil: 'load' });
        await clientPage.waitForSelector('submission-form', { state: 'attached', timeout: 60_000 });
        demand(`${label}: fresh client opens directly in the selected language`, await noCode(clientPage)
          && (await clientPage.locator('html').getAttribute('lang')).startsWith(language));
        demand(`${label}: signer page fits the viewport`, await clientPage.evaluate(() => document.documentElement.scrollWidth - innerWidth <= 1));
        const download = async () => {
          const response = await clientPage.evaluate(async slug => {
            const value = await fetch(`/s/${slug}/download`);
            return { status: value.status, body: await value.text() };
          }, client.slug);
          demand(`${label}: unsigned client download is available`, response.status === 200, response.status);
          const links = JSON.parse(response.body);
          return pdf(new URL(links[0], `https://${SIGN}`).href);
        };
        const unsigned = await download(), repeated = await download();
        demand(`${label}: repeated unsigned downloads reuse identical bytes`, sha256(unsigned) === sha256(repeated));
        writeFileSync(join(OUT, `${label}-unsigned.pdf`), unsigned);
        await completeForm(clientPage, `${label}-client`, true);
        const afterClient = await until(async () => {
          const value = await jud.submission(submissionId);
          return value.submitters.find(s => s.id === client.id)?.completed_at && value;
        }, 60_000, `${label} client completion`);
        const completedClient = afterClient.submitters.find(s => s.id === client.id);
        const values = Object.fromEntries(completedClient.values.map(v => [v.field, v.value]));
        demand(`${label}: consent, signature, name, fee and date survive client completion`, values.Consent === true
          && Boolean(values.Signature) && values.FullName === clientName && values.attorney_fee === '3,000'
          && Boolean(values.DateSigned) && values.DateSigned !== '{{date}}');
        await clientPage.reload({ waitUntil: 'load' });
        demand(`${label}: completed client reload does not reopen signing`, !(await clientPage.locator('submission-form').count()));

        await jud.invite(attorney.id);
        const attorneyInvitation = await mail(recipients[1].email, /ready to sign|listo para firmar/i, since);
        demand(`${label}: lawyer invitation links the correct JUD record`, attorneyInvitation.Subject.includes(reference)
          && attorneyInvitation.Text.includes(recordUrl) && attorneyInvitation.HTML.includes(recordUrl));
        await letterhead(`${label} attorney invitation`, attorneyInvitation);
        const attorneyPage = await (await context()).newPage(), attorneySeen = watch(attorneyPage);
        await attorneyPage.goto(signerLink(attorneyInvitation), { waitUntil: 'load' });
        await attorneyPage.waitForSelector('submission-form', { state: 'attached', timeout: 60_000 });
        demand(`${label}: a different fresh attorney browser signs without an email code`, await noCode(attorneyPage));
        await completeForm(attorneyPage, `${label}-attorney`);
        const done = await until(async () => {
          const value = await jud.submission(submissionId);
          return value.status === 'completed' && value.documents?.length && value.audit_log_url && value;
        }, 180_000, `${label} completed documents`, 2000);
        demand(`${label}: both signers and the agreement are completed`, done.completed_at && done.submitters.every(s => s.completed_at && s.status === 'completed'));
        const signed = await pdf(done.documents[0].url), audit = await pdf(done.audit_log_url);
        demand(`${label}: result has a digital signature and all pages`, signed.toString('latin1').includes('/ByteRange')
          && /\/Type\s*\/Sig\b/.test(signed.toString('latin1')) && (await PDFDocument.load(signed, { updateMetadata: false })).getPageCount() === run.pages);
        writeFileSync(join(OUT, `${label}-signed.pdf`), signed);
        writeFileSync(join(OUT, `${label}-audit.pdf`), audit);
        const received = await until(async () => {
          const ours = (await events()).filter(e => e.record_id === submissionId);
          return ours.filter(e => e.event_type === 'form.completed').length >= 2 && ours.some(e => e.event_type === 'submission.completed') && ours;
        }, 90_000, `${label} signed webhooks`);
        demand(`${label}: completion webhooks are authenticated and bound to this issuance`, received.every(e => e.signature_valid && e.envelope_valid)
          && received.some(e => e.variables?.bennett_issuance_id === issuanceId));
        const clientCopy = await mail(recipients[0].email, /signed|firmado/i, since);
        const attorneyCopy = await mail(recipients[1].email, /signed|firmado/i, since);
        demand(`${label}: signed client copy keeps internal JUD context private`, !`${clientCopy.HTML}${clientCopy.Text}${clientCopy.Subject}`.includes(reference));
        demand(`${label}: signed lawyer copy retains the correct JUD link`, attorneyCopy.Subject.includes(reference)
          && attorneyCopy.Text.includes(recordUrl) && attorneyCopy.HTML.includes(recordUrl));
        demand(`${label}: neither private-link signer received a verification code`, (await Promise.all(recipients.map(r => mailbox(r.email))))
          .flat().every(m => !/verification code|código de verificación/i.test(m.Subject)));
        demand(`${label}: signer pages have no JavaScript, CSP or request failures`, [clientSeen, attorneySeen]
          .every(seen => !seen.problems.length && !seen.refused.length), { client: clientSeen.problems, attorney: attorneySeen.problems });
        await screenshot(attorneyPage, `${label}-completed`);
        evidence.push({ label, submission_id: submissionId, issuance_id: issuanceId, language,
          client_name: clientName, unsigned_sha256: sha256(unsigned), signed_sha256: sha256(signed), audit_sha256: sha256(audit) });
      } finally { await Promise.all(contexts.map(c => c.close())); }
    });
  }
  writeFileSync(join(OUT, 'jud-retainer-flows.json'), `${JSON.stringify(evidence, null, 2)}\n`);
  check('four independent EN/ES desktop/mobile private-link flows completed', evidence.length === 4);
}
