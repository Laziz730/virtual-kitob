# virtual-kitob

Online kitob kutubxonasi — PDF va audio kitoblar, o'quvchi, sun'iy intellekt yordamchisi (Groq), admin panel.

## Ishga tushirish (lokal)
```powershell
powershell -ExecutionPolicy Bypass -File server.ps1
```
Sayt: http://localhost:8080

## Deploy
Vercel'ga (serverless API — `api/`) va Bunny CDN'ga yuklash.

## Muhim
- `config.json` va `.env.local` maxfiy (CDN/Groq kalitlari) — repoda yo'q.