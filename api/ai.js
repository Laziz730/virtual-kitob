// Sun'iy intellekt yordamchisi — Groq API orqali (Vercel serverless + lokal CLI)
// Kalit saqlanishi: process.env.GROQ_API_KEY (Vercel env) yoki .env.local (lokal)
const https = require('https');
const fs = require('fs');
const path = require('path');

function json(res, code, obj) {
  res.statusCode = code;
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.end(JSON.stringify(obj));
}

function parseBody(data) {
  const body = Buffer.isBuffer(data) ? data.toString('utf8') : data;
  try { return typeof body === 'string' ? JSON.parse(body || '{}') : (body || {}); } catch (e) { return null; }
}

function loadKey() {
  if (process.env.GROQ_API_KEY) return process.env.GROQ_API_KEY;
  const candidates = [path.join(process.cwd(), '.env.local'), path.join(__dirname, '.env.local'), path.join(__dirname, '..', '.env.local')];
  for (const f of candidates) {
    try {
      const txt = fs.readFileSync(f, 'utf8');
      for (const line of txt.split(/\r?\n/)) {
        const m = line.match(/^GROQ_API_KEY\s*=\s*(.+)$/);
        if (m) return m[1].trim().replace(/^"(.*)"$/, '$1').replace(/^'(.*)'$/, '$1');
      }
    } catch (e) {}
  }
  return '';
}

function systemPrompt(lang) {
  if (lang === 'ru') {
    return 'Вы — ИИ-ассистент онлайн-библиотеки "VirtualKitob". Ваша задача отвечать на вопросы о книгах, рекомендовать книги и помогать с сервисами библиотеки.\nПравила:\n- Отвечайте всегда на РУССКОМ языке, кратко и понятно (максимум 5-7 предложений).\n- Если пользователь спрашивает о конкретной книге и её данные переданы — отвечайте на основе этих данных. Не выдумывайте детали, которых нет (страницы, биография автора и т.п.); честно скажите, что этих данных нет.\n- Если вы уверенно знаете известное произведение (например классику мировой или узбекской литературы), можете кратко описать его содержание и значение — это допустимо.\n- Будьте дружелюбны и полезны.\n- Если передан текст книги — отвечайте, опираясь прежде всего на этот текст, при необходимости цитируйте его.';
  }
  if (lang === 'en') {
    return 'You are the AI assistant of the online library "VirtualKitob". Your job is to answer questions about books, recommend books, and help with library services.\nRules:\n- Always reply in ENGLISH, concise and clear (maximum 5-7 sentences).\n- If the user asks about a specific book and its data is provided, answer based on that data. Do not invent details that are not given (page count, author biography, etc.); honestly say that data is not available.\n- If you confidently recognize a well-known work (e.g. classic world or Uzbek literature), you may briefly describe its content and significance — that is allowed.\n- Be friendly and helpful.\n- If the book text is provided, base your answer primarily on that text, quoting fragments if needed.';
  }
  return 'Siz "VirtualKitob" onlayn kutubxonasining sun\'iy intellekt yordamchisisiz. Vazifangiz foydalanuvchilarga kitoblar haqidagi savollariga javob berish, kitob tavsiya qilish va kutubxona xizmatlari bo\'yicha yordamlashish.\nQoidalar:\n- Har doim O\'ZBEK TILIDA javob bering, qisqa va tushunarli (maksimal 5-7 gap).\n- Foydalanuvchi ma\'lum bir kitob haqida so\'rasa va kitob ma\'lumotlari berilgan bo\'lsa — shu ma\'lumotlarga tayanib javob bering. Berilmagan tafsilotlarni (sahifalar soni, muallif biografiyasi va h.k.) o\'ylab to\'qima yaratmang; bunday hollarda halol ayting.\n- Agar kitob jahon yoki o\'zbek adabiyotida mashhur asar bo\'lsa va uni ishonchli bilsangiz, uning mazmuni va ahamiyati haqida qisqacha javob berishingiz mumkin.\n- Do\'stona va foydali bo\'ling.\n- Agar javob tayyorlash uchun kitob matni berilgan bo\'lsa, javobingizni asosan o\'sha matnga tayanib yozing va kerakli joylarda matndan iqtibos keltiring.';
}

function askGroq(apiKey, lang, question, book, bookText) {
  return new Promise((resolve, reject) => {
    let user = String(question || '').trim().slice(0, 500);
    const preamble = [];
    if (book && (book.title)) {
      const meta = [
        'Kitob: ' + book.title,
        book.author ? 'Muallif: ' + book.author : '',
        book.genre ? 'Janr: ' + book.genre : '',
        book.year ? 'Yil: ' + book.year : '',
        book.volume ? 'Jild: ' + book.volume : '',
        book.desc ? 'Tavsif: ' + String(book.desc).slice(0, 300) : ''
      ].filter(Boolean).join(' | ');
      preamble.push('Tegishli kitob ma\'lumotlari:\n' + meta);
    }
    if (bookText) preamble.push('Quyidagi kitob matnidan foydalanib javob bering:\n\n' + String(bookText).slice(0, 50000));
    if (preamble.length) user = preamble.join('\n\n') + '\n\nFoydalanuvchi savoli:\n' + user;
    const payload = JSON.stringify({
      model: 'openai/gpt-oss-120b',
      messages: [
        { role: 'system', content: systemPrompt(lang) },
        { role: 'user', content: user }
      ],
      temperature: 0.6,
      max_tokens: 900
    });
    const blob = Buffer.from(payload);
    const req = https.request('https://api.groq.com/openai/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ' + apiKey,
        'Content-Length': blob.length
      }
    }, r => {
      let d = '';
      r.on('data', c => (d += c));
      r.on('end', () => {
        try {
          const j = JSON.parse(d);
          if (j.choices && j.choices[0] && j.choices[0].message && j.choices[0].message.content) {
            resolve(j.choices[0].message.content.trim());
          } else {
            reject(new Error((j.error && j.error.message) || 'Bo\'sh javob'));
          }
        } catch (e) { reject(e); }
      });
    });
    req.on('error', reject);
    req.end(blob);
  });
}

async function handler(req, res) {
  if (req.method === 'OPTIONS') {
    res.statusCode = 204;
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
    res.end();
    return;
  }
  if (req.method === 'GET') return json(res, 200, { status: 'ok', service: 'VirtualKitob AI yordamchisi' });
  if (req.method !== 'POST') return json(res, 405, { error: 'Faqat GET/POST ruxsat etiladi' });

  const key = process.env.GROQ_API_KEY || loadKey();
  if (!key) return json(res, 500, { error: 'AI sozlamalari mavjud emas' });

  const b = parseBody(req.body);
  const q = String((b && b.q) || '').trim().slice(0, 500);
  const lang = b && ['uz', 'ru', 'en'].includes(b.lang) ? b.lang : 'uz';
  const book = (b && b.book && typeof b.book === 'object') ? b.book : null;
  const bookText = String((b && b.text) || '').slice(0, 200000);
  if (!q) return json(res, 400, { error: 'Savol kiritilishi shart' });

  try {
    const answer = await askGroq(key, lang, q, book, bookText);
    return json(res, 200, { answer: answer });
  } catch (e) {
    return json(res, 502, { error: 'AI javob bera olmadi: ' + String(e.message || e).slice(0, 200) });
  }
}

module.exports = handler;

if (process.argv[2] === '--stdin') {
  (async () => {
    const key = loadKey();
    if (!key) { console.error('GROQ_API_KEY topilmadi (.env.local da ko\'rsating)'); process.exit(1); }
    const chunks = [];
    process.stdin.on('data', c => chunks.push(c));
    process.stdin.on('end', async () => {
      let b = {};
      try { b = JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}'); } catch (e) { console.error('stdin JSON xato'); process.exit(1); }
      const q = String(b.q || '').trim().slice(0, 500);
      const lang = ['uz', 'ru', 'en'].includes(b.lang) ? b.lang : 'uz';
      const book = (b.book && typeof b.book === 'object') ? b.book : null;
      const bookText = String(b.text || '').slice(0, 200000);
      try {
        const answer = await askGroq(key, lang, q, book, bookText);
        process.stdout.write(JSON.stringify({ answer: answer }));
      } catch (e) {
        console.error(String(e.message || e));
        process.exit(1);
      }
    });
  })();
}

if (process.argv[2] === '--ask') {
  (async () => {
    const key = loadKey();
    if (!key) { console.error('GROQ_API_KEY topilmadi (.env.local da ko\'rsating)'); process.exit(1); }
    const q = process.argv[3] || '';
    const lang = ['uz', 'ru', 'en'].includes(process.argv[4]) ? process.argv[4] : 'uz';
    let book = null;
    try { book = JSON.parse(process.argv[5] || 'null'); } catch (e) {}
    const bookText = process.argv[6] || '';
    try {
      const answer = await askGroq(key, lang, q, book, bookText);
      process.stdout.write(JSON.stringify({ answer: answer }));
    } catch (e) {
      process.stderr.write(String(e.message || e));
      process.exit(1);
    }
  })();
}