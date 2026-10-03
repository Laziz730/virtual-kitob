const https = require('https');
const http = require('http');

function json(res, code, obj) {
  res.statusCode = code;
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.end(JSON.stringify(obj));
}

function request(url, method, body, headers) {
  return new Promise((resolve, reject) => {
    const mod = url.startsWith('https') ? https : http;
    const req = mod.request(url, { method, headers }, r => {
      let d = '';
      r.on('data', c => (d += c));
      r.on('end', () => resolve({ code: r.statusCode, body: d }));
    });
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

function parseBody(data) {
  const body = Buffer.isBuffer(data) ? data.toString('utf8') : data;
  try { return typeof body === 'string' ? JSON.parse(body || '{}') : (body || {}); } catch (e) { return null; }
}

module.exports = async function handler(req, res) {
  if (req.method === 'OPTIONS') {
    res.statusCode = 204;
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
    res.end();
    return;
  }

  const key = process.env.BUNNY_API_KEY;
  const zone = process.env.BUNNY_ZONE;
  const storage = process.env.BUNNY_STORAGE_URL || 'https://storage.bunnycdn.com';
  if (!key || !zone) return json(res, 500, { error: 'Server sozlamalari mavjud emas' });

  const blobUrl = storage + '/' + zone + '/site-engage.json';
  let data = { views: {}, ratings: {}, comments: {} };
  const read = await request(blobUrl, 'GET', null, { AccessKey: key });
  if (read.code === 200) {
    try {
      const j = JSON.parse(read.body);
      data = { views: j.views || {}, ratings: j.ratings || {}, comments: j.comments || {} };
    } catch (e) {}
  }

  if (req.method === 'GET') return json(res, 200, data);
  if (req.method !== 'POST') return json(res, 405, { error: 'Faqat GET/POST ruxsat etiladi' });

  const b = parseBody(req.body);
  if (!b) return json(res, 400, { error: 'JSON noto\'g\'ri formatda' });
  const k = String(b.key || '').slice(0, 120);
  if (!k) return json(res, 400, { error: 'key kiritilishi shart' });
  const action = String(b.action || '');

  if (action === 'view') {
    data.views[k] = (data.views[k] || 0) + 1;
  } else if (action === 'rate') {
    const stars = Math.min(5, Math.max(1, Math.round(Number(b.stars) || 0)));
    const r = data.ratings[k] || { sum: 0, n: 0 };
    r.sum += stars;
    r.n += 1;
    data.ratings[k] = r;
  } else if (action === 'comment') {
    const name = String(b.name || '').trim().slice(0, 40);
    const text = String(b.text || '').trim().slice(0, 400);
    if (!name || !text) return json(res, 400, { error: 'Ism va matn kiritilishi shart' });
    const c = data.comments[k] || [];
    c.push({ n: name, t: text, d: Date.now() });
    data.comments[k] = c.slice(-20);
  } else {
    return json(res, 400, { error: 'Noto\'g\'ri action' });
  }

  const wrote = await request(blobUrl, 'PUT', JSON.stringify(data), {
    AccessKey: key,
    'Content-Type': 'application/json'
  });
  if (wrote.code >= 300) {
    return json(res, 502, { error: 'Bunny yozish xatosi (' + wrote.code + '): ' + String(wrote.body).slice(0, 120) });
  }
  return json(res, 200, data);
};