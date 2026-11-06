// Resolve the actual Mailpit MIME parts for a browser which has no mail CID
// handler. Verify their bytes against the checked-in nurture artwork first.
import { readFileSync } from 'node:fs';

const names = ['footer-logo', 'linkedin-gold', 'instagram-gold', 'facebook-gold', 'youtube-gold'];

export async function emailWithInlineAssets(message, fetchPart = fetch) {
  let html = message.HTML ?? '';
  const images = [...html.matchAll(/<img\b[^>]*\bsrc=["']([^"']+)["']/gi)];
  if (images.length !== 6 || images.some(([, src]) => !src.startsWith('cid:'))) {
    throw new Error('Letterhead images must all travel inside the email');
  }
  const sources = new Map();
  for (const name of names) {
    const filename = `bennett-mail-${name}.png`;
    const parts = (message.Inline ?? []).filter(part => part.FileName === filename);
    if (parts.length !== 1 || parts[0].ContentType !== 'image/png') throw new Error(`Missing inline PNG: ${filename}`);
    const part = parts[0];
    const cid = part.ContentID.replace(/^<|>$/g, '');
    if (!cid || sources.has(cid)) throw new Error('Ambiguous image Content-ID');
    const response = await fetchPart(`http://127.0.0.1:8025/api/v1/message/${encodeURIComponent(message.ID)}/part/${encodeURIComponent(part.PartID)}`);
    if (!response.ok) throw new Error(`Unreadable inline PNG: ${filename}`);
    const bytes = Buffer.from(await response.arrayBuffer());
    const expected = readFileSync(new URL(`../../public/packs/${filename}`, import.meta.url));
    if (!bytes.equals(expected)) throw new Error(`Inline PNG bytes changed: ${filename}`);
    sources.set(cid, `data:image/png;base64,${bytes.toString('base64')}`);
  }
  for (const [tag, src] of images) {
    const data = sources.get(decodeURIComponent(src.slice(4)));
    if (!data) throw new Error('Image references a missing MIME part');
    html = html.replace(tag, tag.replace(src, data));
  }
  return html;
}
