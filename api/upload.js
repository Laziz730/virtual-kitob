const http = require('http');
const https = require('https');
const crypto = require('crypto');

const ALLOWED = new Set(['.png', '.jpg', '.jpeg', '.webp', '.gif', '.pdf', '.mp3', '.m4a', '.mp4', '.webm', '.ogv', '.m4v']);
const CT = {
  '.pdf': 'application/pdf',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.gif': 'image/gif',
  '.mp3': 'audio/mpeg',
  '.m4a': 'audio/mp4',
  '.mp4': 'video/mp4',
  '.m4v': 'video/x-m4v',
  '.webm': 'video/webm',
  '.ogv': 'video/ogg'
};
const MAX_PART = 4 * 1024 * 1024;
const MAX_PARTS = 600;

// ---- Fayl imzosi (magic bytes) bo'yicha tekshirish: soxta/niqoblangan fayllarni qabul qilmaydi ----
function signatureOk(buf, ext) {
  if (!buf || buf.length < 5) return false;
  const ascii = (off, s) => {
    for (let i = 0; i < s.length; i++) if (buf[off + i] !== s.charCodeAt(i)) return false;
    return true;
  };
  const b = (off, v) => off < buf.length && buf[off] === v;
  switch (ext) {
    case '.pdf': return ascii(0, '%PDF-');
    case '.png': return b(0, 0x89) && b(1, 0x50) && b(2, 0x4e) && b(3, 0x47) && b(4, 0x0d) && b(5, 0x0a) && b(6, 0x1a) && b(7, 0x0a);
    case '.jpg':
    case '.jpeg': return b(0, 0xff) && b(1, 0xd8) && b(2, 0xff);
    case '.gif': return ascii(0, 'GIF8');
    case '.webp': return ascii(0, 'RIFF') && buf.length >= 12 && ascii(8, 'WEBP');
    case '.mp3': return ascii(0, 'ID3') || (buf[0] === 0xff && (buf[1] & 0xe0) === 0xe0);
    case '.m4a':
    case '.mp4':
    case '.m4v': return buf.length >= 8 && ascii(4, 'ftyp');
    case '.webm': return b(0, 0x1a) && b(1, 0x45) && b(2, 0xdf) && b(3, 0xa3);
    case '.ogv': return ascii(0, 'OggS');
    default: return true;
  }
}

function json(res, code, obj) {
  res.statusCode = code;
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.end(JSON.stringify(obj));
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', c => chunks.push(c));
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

function reqBytes(url, method, headers, body) {
  return new Promise((resolve, reject) => {
    const mod = url.startsWith('https') ? https : http;
    const r = mod.request(url, { method, headers }, res => {
      const chunks = [];
      res.on('data', c => chunks.push(c));
      res.on('end', () => resolve({ code: res.statusCode, body: Buffer.concat(chunks) }));
    });
    r.on('error', reject);
    r.setTimeout(180000, () => { r.destroy(new Error('timeout')); });
    if (body) r.write(body);
    r.end();
  });
}

async function env() {
  const key = process.env.BUNNY_API_KEY;
  const zone = process.env.BUNNY_ZONE;
  const storage = process.env.BUNNY_STORAGE_URL || 'https://storage.bunnycdn.com';
  const cdn = process.env.BUNNY_CDN_URL;
  if (!key || !zone || !cdn) return null;
  return { key, zone, storage, cdn, max: (parseInt(process.env.MAX_UPLOAD_MB || '100', 10) || 100) * 1024 * 1024 };
}

function extOf(name) {
  const dot = name.lastIndexOf('.');
  return dot >= 0 ? name.slice(dot).toLowerCase() : '';
}

const ID_RE = /^[a-f0-9]{8,64}$/i;

// ---- To'liq yuklash: berilgan part-larni bitta fayl qilib birlashtiradi ----
async function mergeParts(cfg, uploadId, safe, totalParts, totalBytes, ct) {
  const finalUrl = cfg.storage + '/' + cfg.zone + '/' + safe;
  return new Promise((resolve, reject) => {
    const put = https.request(finalUrl, {
      method: 'PUT',
      headers: { AccessKey: cfg.key, 'Content-Type': ct, 'Content-Length': totalBytes }
    }, res => {
      const chunks = [];
      res.on('data', c => chunks.push(c));
      res.on('end', () => resolve(Buffer.concat(chunks)));
    });
    put.on('error', reject);
    put.setTimeout(240000, () => { put.destroy(new Error('merge timeout')); });
    (async () => {
      for (let i = 0; i < totalParts; i++) {
        const partUrl = cfg.storage + '/' + cfg.zone + '/' + uploadId + '/' + i;
        const mod = partUrl.startsWith('https') ? https : http;
        await new Promise((res2, rej2) => {
          const g = mod.get(partUrl, { headers: { AccessKey: cfg.key } }, gr => {
            if (gr.statusCode >= 300) {
              gr.resume();
              rej2(new Error('part fail ' + gr.statusCode));
              return;
            }
            const gc = [];
            gr.on('data', c => gc.push(c));
            gr.on('end', () => {
              put.write(Buffer.concat(gc));
              res2();
            });
          });
          g.on('error', rej2);
        });
      }
      put.end();
    })().catch(e => { put.destroy(e); reject(e); });
  });
}

function getPartBytes(cfg, uploadId, index) {
  const url = cfg.storage + '/' + cfg.zone + '/' + uploadId + '/' + index;
  return reqBytes(url, 'GET', { AccessKey: cfg.key }, null);
}

function cleanupParts(cfg, uploadId) {
  try {
    const url = cfg.storage + '/' + cfg.zone + '/' + uploadId;
    reqBytes(url, 'DELETE', { AccessKey: cfg.key }, null).catch(() => {});
  } catch (e) {}
}

module.exports = async function handler(req, res) {
  if (req.method !== 'POST') return json(res, 405, { error: 'Faqat POST ruxsat etiladi' });

  const cfg = await env();
  if (!cfg) return json(res, 500, { error: 'Server sozlamalari mavjud emas' });

  const path = (req.url || '/').split('?')[0];

  let data;
  try {
    const buf = await readBody(req);
    const body = buf.toString('utf8');
    data = JSON.parse(body || '{}');
  } catch (e) {
    return json(res, 400, { error: "JSON noto'g'ri formatda" });
  }

  // ---- Kichik fayl: yaxlit yuklash ----
  if (path === '/upload') {
    const rawName = String(data.name || '');
    const b64 = String(data.base64 || '');
    if (!rawName || !b64) return json(res, 400, { error: 'name va base64 kiritilishi shart' });
    const ext = extOf(rawName);
    if (!ALLOWED.has(ext)) return json(res, 400, { error: 'Ruhsat etilmagan fayl turi: ' + ext });
    let bytes;
    try { bytes = Buffer.from(b64, 'base64'); } catch (e2) { return json(res, 400, { error: 'base64 kodlashda xato' }); }
    if (bytes.length === 0) return json(res, 400, { error: "Bo'sh fayl yuklab bo'lmaydi" });
    if (!signatureOk(bytes, ext)) return json(res, 400, { error: "Fayl formati tekshiruvdan o'tmayapti. O'xshash soxta/zararli fayl bo'lishi mumkin — haqiqiy fayl tanlang." });
    if (bytes.length > cfg.max) return json(res, 413, { error: 'Fayl juda katta!' });

    const safe = crypto.randomBytes(16).toString('hex') + ext;
    const up = await reqBytes(cfg.storage + '/' + cfg.zone + '/' + safe, 'PUT', {
      AccessKey: cfg.key,
      'Content-Type': CT[ext] || 'application/octet-stream',
      'Content-Length': bytes.length
    }, bytes);
    if (up.code >= 300) return json(res, 502, { error: 'Bunny CDN xatosi (' + up.code + '): ' + String(up.body).slice(0, 200) });
    return json(res, 200, { url: cfg.cdn + '/' + safe });
  }

  // ---- Qism yuklash: har bir qism vaqtinchalik part-fayl sifatida saqlanadi ----
  if (path === '/upload/part') {
    const uploadId = String(data.uploadId || '');
    const b64 = String(data.base64 || '');
    const index = parseInt(String(data.index), 10);
    if (!ID_RE.test(uploadId) || isNaN(index) || index < 0 || index >= MAX_PARTS || !b64) {
      return json(res, 400, { error: 'uploadId/index/base64 noto\u0027g\u0027ri' });
    }
    let bytes;
    try { bytes = Buffer.from(b64, 'base64'); } catch (e2) { return json(res, 400, { error: 'base64 kodlashda xato' }); }
    if (bytes.length === 0 || bytes.length > MAX_PART) return json(res, 400, { error: "Qism hajmi noto'g'ri" });

    const up = await reqBytes(cfg.storage + '/' + cfg.zone + '/' + uploadId + '/' + index, 'PUT', {
      AccessKey: cfg.key,
      'Content-Type': 'application/octet-stream',
      'Content-Length': bytes.length
    }, bytes);
    if (up.code >= 300) return json(res, 502, { error: 'Bunny CDN xatosi (' + up.code + '): ' + String(up.body).slice(0, 200) });
    return json(res, 200, { ok: true });
  }

  // ---- Qismlarni birlashtirish ----
  if (path === '/upload/finish') {
    const uploadId = String(data.uploadId || '');
    const ext = String(data.ext || '').toLowerCase();
    const totalParts = parseInt(String(data.totalParts), 10);
    const totalBytes = parseInt(String(data.totalBytes), 10);
    if (!ID_RE.test(uploadId)) return json(res, 400, { error: "uploadId noto'g'ri" });
    if (!ALLOWED.has(ext)) return json(res, 400, { error: 'Ruhsat etilmagan fayl turi: ' + ext });
    if (isNaN(totalParts) || totalParts < 1 || totalParts > MAX_PARTS) return json(res, 400, { error: "Qismlar soni noto'g'ri" });
    if (isNaN(totalBytes) || totalBytes < 1 || totalBytes > cfg.max) return json(res, 413, { error: 'Fayl juda katta!' });

    const safe = crypto.randomBytes(16).toString('hex') + ext;
    try {
      const head = await getPartBytes(cfg, uploadId, 0);
      if (!signatureOk(head.body, ext)) {
        cleanupParts(cfg, uploadId);
        return json(res, 400, { error: "Fayl formati tekshiruvdan o'tmayapti. O'xshash soxta/zararli fayl bo'lishi mumkin — haqiqiy fayl tanlang." });
      }
      const up = await mergeParts(cfg, uploadId, safe, totalParts, totalBytes, CT[ext] || 'application/octet-stream');
      if (up.code >= 300) return json(res, 502, { error: 'Bunny CDN xatosi (' + up.code + '): ' + String(up.body).slice(0, 200) });
      cleanupParts(cfg, uploadId);
      return json(res, 200, { url: cfg.cdn + '/' + safe });
    } catch (e2) {
      cleanupParts(cfg, uploadId);
      return json(res, 500, { error: 'Faylni birlashtirishda xato: ' + e2.message });
    }
  }

  // ---- Bekor qilish / tozalash ----
  if (path === '/upload/abort') {
    const uploadId = String(data.uploadId || '');
    if (!ID_RE.test(uploadId)) return json(res, 400, { error: "uploadId noto'g'ri" });
    cleanupParts(cfg, uploadId);
    return json(res, 200, { ok: true });
  }

  return json(res, 404, { error: 'Not found' });
};