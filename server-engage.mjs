// Lokal server.ps1 uchun yordamchi: /engage (ko'rishlar, reyting, izohlar)
// Foydalanish: node server-engage.mjs get
//              node server-engage.mjs post view <key>
//              node server-engage.mjs post rate <key> <stars>
//              node server-engage.mjs post comment <key> <name> <text>
import fs from 'node:fs';
import path from 'node:path';

const cfg = JSON.parse(fs.readFileSync(path.join(process.cwd(), 'config.json'), 'utf8'));
const storage = cfg.storageUrl;
const zone = cfg.zone;
const key = cfg.apiKey;
const blobUrl = storage + '/' + zone + '/site-engage.json';
const DEF = { views: {}, ratings: {}, comments: {} };

async function readBlob() {
  try {
    const r = await fetch(blobUrl, { headers: { AccessKey: key } });
    if (!r.ok) return DEF;
    const j = await r.json();
    return { views: j.views || {}, ratings: j.ratings || {}, comments: j.comments || {} };
  } catch (e) { return DEF; }
}

async function writeBlob(data) {
  try {
    await fetch(blobUrl, {
      method: 'PUT',
      headers: { AccessKey: key, 'Content-Type': 'application/json' },
      body: JSON.stringify(data)
    });
  } catch (e) {}
}

const [mode, action, k] = process.argv.slice(2);
let data = await readBlob();

if (mode === 'get') {
  process.stdout.write(JSON.stringify(data));
  process.exit(0);
}

if (action === 'view') {
  data.views[k] = (data.views[k] || 0) + 1;
} else if (action === 'rate') {
  const stars = Math.min(5, Math.max(1, Math.round(Number(process.argv[5]) || 0)));
  const r = data.ratings[k] || { sum: 0, n: 0 };
  r.sum += stars;
  r.n += 1;
  data.ratings[k] = r;
} else if (action === 'comment') {
  const name = String(process.argv[5] || '').slice(0, 40);
  const text = String(process.argv[6] || '').slice(0, 400);
  const c = data.comments[k] || [];
  c.push({ n: name, t: text, d: Date.now() });
  data.comments[k] = c.slice(-20);
}

await writeBlob(data);
process.stdout.write(JSON.stringify(data));