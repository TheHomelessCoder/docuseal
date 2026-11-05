import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { emailWithInlineAssets } from '../ci/mail-assets.mjs';

const names = ['footer-logo', 'linkedin-gold', 'instagram-gold', 'facebook-gold', 'youtube-gold'];
function fixture() {
  return { ID: 'synthetic-message',
    HTML: ['footer-logo', ...names].map(name => `<img src="cid:${name}%40mail.test">`).join(''),
    Inline: names.map(name => ({ FileName: `bennett-mail-${name}.png`, ContentType: 'image/png',
      ContentID: `<${name}@mail.test>`, PartID: name })) };
}
const fetchPart = async url => new Response(readFileSync(new URL(
  `../../public/packs/bennett-mail-${url.split('/').at(-1)}.png`, import.meta.url)));

test('delivered artwork resolves without any remote-image fetch', async () => {
  const html = await emailWithInlineAssets(fixture(), fetchPart);
  assert.equal((html.match(/src="data:image\/png;base64,/g) ?? []).length, 6);
  assert.ok(!html.includes('cid:'));
});
for (const [label, change] of [
  ['remote logo', m => { m.HTML = m.HTML.replace('cid:footer-logo%40mail.test', 'https://example.invalid/logo.png'); }],
  ['missing part', m => { m.Inline.pop(); }],
  ['duplicate part', m => { m.Inline.push(m.Inline[0]); }],
  ['wrong type', m => { m.Inline[0].ContentType = 'text/html'; }],
  ['wrong Content-ID', m => { m.Inline[0].ContentID = '<other@mail.test>'; }],
]) test(`rejects ${label}`, async () => {
  const message = fixture(); change(message);
  await assert.rejects(emailWithInlineAssets(message, fetchPart));
});
test('rejects a failed or corrupt image download', async () => {
  await assert.rejects(emailWithInlineAssets(fixture(), async () => new Response('', { status: 404 })));
  await assert.rejects(emailWithInlineAssets(fixture(), async () => new Response('wrong bytes')));
});
