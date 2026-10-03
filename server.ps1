$root = $PSScriptRoot
$logFile = Join-Path $root "server.log"

# ---- Port tanlash (8080 band bo'lsa - navbatdagisiga o'tadi) ----
$port = 8080

# ---- Sozlamalar (config.json) ----
$configPath = Join-Path $root "config.json"
if (-not (Test-Path -LiteralPath $configPath)) {
    Write-Host "Xato: config.json topilmadi! Unda CDN API kaliti va sozlamalar bo'lishi kerak." -ForegroundColor Red
    exit 1
}
try {
    $cfg = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
} catch {
    Write-Host "Xato: config.json o'qib bo'lmadi: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
$bunnyApiKey = [string]$cfg.apiKey
$bunnyZone    = [string]$cfg.zone
$bunnyCdnUrl  = [string]$cfg.cdnUrl
$bunnyStorage = [string]$cfg.storageUrl

$maxUploadMb = 0
try { $maxUploadMb = [int]$cfg.maxUploadMb } catch { $maxUploadMb = 100 }
if ($maxUploadMb -le 0) { $maxUploadMb = 100 }
$maxUploadBytes = $maxUploadMb * 1024 * 1024
$maxPartBytes = 4 * 1024 * 1024
$maxPartCount = 600

$listener = New-Object System.Net.HttpListener
$ports = @(8080, 8081, 8082, 8083, 8084, 8085)
$port = 0
foreach ($p in $ports) {
    $l = New-Object System.Net.HttpListener
    $l.Prefixes.Add("http://localhost:$p/")
    $l.Prefixes.Add("http://127.0.0.1:$p/")
    try {
        $l.Start()
        $listener = $l
        $port = $p
        break
    } catch {
        $l.Close()
    }
}
if ($port -eq 0) {
    $m = "Xato: 8080-8085 portlari band, sayt ishga tushmadi."
    Write-Host $m -ForegroundColor Red
    Add-Content -LiteralPath $logFile -Value ((Get-Date).ToString("HH:mm:ss") + " " + $m)
    exit 1
}
$m = "Server ishlamoqda: http://localhost:$port/  (to'xtatish: Ctrl+C)"
Write-Host $m -ForegroundColor Green
Add-Content -LiteralPath $logFile -Value ((Get-Date).ToString("HH:mm:ss") + " " + $m)

$mime = @{
    ".html" = "text/html; charset=utf-8"
    ".css"  = "text/css; charset=utf-8"
    ".js"   = "application/javascript; charset=utf-8"
    ".json" = "application/json"
    ".png"  = "image/png"
    ".jpg"  = "image/jpeg"
    ".jpeg" = "image/jpeg"
    ".gif"  = "image/gif"
    ".svg"  = "image/svg+xml"
    ".ico"  = "image/x-icon"
    ".webp" = "image/webp"
    ".woff" = "font/woff"
    ".woff2"= "font/woff2"
    ".ttf"  = "font/ttf"
    ".mp3"  = "audio/mpeg"
    ".m4a"  = "audio/mp4"
    ".mp4"  = "video/mp4"
    ".m4v"  = "video/x-m4v"
    ".webm" = "video/webm"
    ".ogv"  = "video/ogg"
    ".pdf"  = "application/pdf"
}

function Send-Json($res, $obj, $code = 200) {
    $txt = $obj | ConvertTo-Json -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($txt)
    $res.StatusCode = $code
    $res.ContentType = "application/json; charset=utf-8"
    $res.ContentLength64 = $bytes.Length
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
}

# ---- Fayl imzosi (magic bytes) bo'yicha tekshirish ----
function Test-FileSignature {
    param([byte[]]$bytes, [string]$ext)
    if ($null -eq $bytes -or $bytes.Length -lt 5) { return $false }
    switch ($ext) {
        ".pdf"  { return $bytes[0] -eq 0x25 -and $bytes[1] -eq 0x50 -and $bytes[2] -eq 0x44 -and $bytes[3] -eq 0x46 -and $bytes[4] -eq 0x2D }
        ".png"  { if ($bytes.Length -lt 8) { return $false }; return $bytes[0] -eq 0x89 -and $bytes[1] -eq 0x50 -and $bytes[2] -eq 0x4E -and $bytes[3] -eq 0x47 -and $bytes[4] -eq 0x0D -and $bytes[5] -eq 0x0A -and $bytes[6] -eq 0x1A -and $bytes[7] -eq 0x0A }
        ".jpg"  { return $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xD8 -and $bytes[2] -eq 0xFF }
        ".jpeg" { return $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xD8 -and $bytes[2] -eq 0xFF }
        ".gif"  { return $bytes[0] -eq 0x47 -and $bytes[1] -eq 0x49 -and $bytes[2] -eq 0x46 -and $bytes[3] -eq 0x38 }
        ".webp" { if ($bytes.Length -lt 12) { return $false }; return $bytes[0] -eq 0x52 -and $bytes[1] -eq 0x49 -and $bytes[2] -eq 0x46 -and $bytes[3] -eq 0x46 -and $bytes[8] -eq 0x57 -and $bytes[9] -eq 0x45 -and $bytes[10] -eq 0x42 -and $bytes[11] -eq 0x50 }
        ".mp3"  { return ($bytes[0] -eq 0x49 -and $bytes[1] -eq 0x44 -and $bytes[2] -eq 0x33) -or ($bytes[0] -eq 0xFF -and ($bytes[1] -band 0xE0) -eq 0xE0) }
        ".m4a"  { if ($bytes.Length -lt 8) { return $false }; return $bytes[4] -eq 0x66 -and $bytes[5] -eq 0x74 -and $bytes[6] -eq 0x79 -and $bytes[7] -eq 0x70 }
        ".mp4"  { if ($bytes.Length -lt 8) { return $false }; return $bytes[4] -eq 0x66 -and $bytes[5] -eq 0x74 -and $bytes[6] -eq 0x79 -and $bytes[7] -eq 0x70 }
        ".m4v"  { if ($bytes.Length -lt 8) { return $false }; return $bytes[4] -eq 0x66 -and $bytes[5] -eq 0x74 -and $bytes[6] -eq 0x79 -and $bytes[7] -eq 0x70 }
        ".webm" { return $bytes[0] -eq 0x1A -and $bytes[1] -eq 0x45 -and $bytes[2] -eq 0xDF -and $bytes[3] -eq 0xA3 }
        ".ogv"  { return $bytes[0] -eq 0x4F -and $bytes[1] -eq 0x67 -and $bytes[2] -eq 0x67 -and $bytes[3] -eq 0x53 }
        default { return $true }
    }
}

try {
    while ($listener.IsListening) {
        try {
            $context = $listener.GetContext()
        $req = $context.Request
        $res = $context.Response

        $path = [System.Uri]::UnescapeDataString($req.Url.AbsolutePath)

        # ---- CDN ga fayl yuklash: POST /upload  { name, base64 } ----
        if ($path -eq "/upload" -and $req.HttpMethod -eq "POST") {
            try {
                $sr = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                $body = $sr.ReadToEnd()
                $sr.Dispose()
                $data = $body | ConvertFrom-Json
                $rawName = [string]$data.name
                $b64 = [string]$data.base64
                if (-not $rawName -or -not $b64) {
                    Send-Json $res @{ error = "name va base64 kiritilishi shart" } 400
                    $res.Close()
                    continue
                }
                $ext = [System.IO.Path]::GetExtension($rawName).ToLower()
                $allowed = @(".png", ".jpg", ".jpeg", ".webp", ".gif", ".pdf", ".mp3", ".m4a", ".mp4", ".m4v", ".webm", ".ogv")
                if ($allowed -notcontains $ext) {
                    Send-Json $res @{ error = "Ruhsat etilmagan fayl turi: $ext" } 400
                    $res.Close()
                    continue
                }
$bytes = [System.Convert]::FromBase64String($b64)
if ($bytes.Length -eq 0) {
    Send-Json $res @{ error = "Bo'sh fayl yuklab bo'lmaydi" } 400
    $res.Close()
    continue
}
if (-not (Test-FileSignature $bytes $ext)) {
    Send-Json $res @{ error = "Fayl formati tekshiruvdan o'tmayapti. O'xshash soxta/zararli fayl bo'lishi mumkin - haqiqiy fayl tanlang." } 400
    $res.Close()
    continue
}
if ($bytes.Length -gt $maxUploadBytes) {
    Send-Json $res @{ error = "Fayl juda katta! Maksimal hajm: $maxUploadMb MB" } 413
    $res.Close()
    continue
}
                $safe = [guid]::NewGuid().ToString("N") + $ext
                $ct = @{ ".pdf" = "application/pdf"; ".png" = "image/png"; ".jpg" = "image/jpeg"; ".jpeg" = "image/jpeg"; ".webp" = "image/webp"; ".gif" = "image/gif"; ".mp3" = "audio/mpeg"; ".m4a" = "audio/mp4"; ".mp4" = "video/mp4"; ".m4v" = "video/x-m4v"; ".webm" = "video/webm"; ".ogv" = "video/ogg" }[$ext]

                $wr = [System.Net.HttpWebRequest]::Create("$bunnyStorage/$bunnyZone/$safe")
                $wr.Method = "PUT"
                $wr.Headers.Add("AccessKey", $bunnyApiKey)
                $wr.ContentType = $ct
                $wr.ContentLength = $bytes.Length
                $wr.Timeout = 120000
                $st = $wr.GetRequestStream()
                $st.Write($bytes, 0, $bytes.Length)
                $st.Dispose()
                $upResp = $wr.GetResponse()
                $upResp.Dispose()

                Send-Json $res @{ url = "$bunnyCdnUrl/$safe" } 200
            } catch {
                Send-Json $res @{ error = $_.Exception.Message } 500
            }
            $res.Close()
            continue
        }

        if ($path -eq "/upload/part" -and $req.HttpMethod -eq "POST") {
            try {
                $sr = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                $body = $sr.ReadToEnd()
                $sr.Dispose()
                $data = $body | ConvertFrom-Json
                $uId = [string]$data.uploadId
                $uIdx = [int]$data.index
                $p64 = [string]$data.base64
                if ($uId -notmatch '^[a-f0-9]{8,64}$' -or $uIdx -lt 0 -or $uIdx -ge $maxPartCount -or -not $p64) {
                    Send-Json $res @{ error = "uploadId/index/base64 noto'g'ri" } 400
                    $res.Close()
                    continue
                }
                $pbytes = [System.Convert]::FromBase64String($p64)
                if ($pbytes.Length -eq 0 -or $pbytes.Length -gt $maxPartBytes) {
                    Send-Json $res @{ error = "Qism hajmi noto'g'ri" } 400
                    $res.Close()
                    continue
                }
                $pwr = [System.Net.HttpWebRequest]::Create("$bunnyStorage/$bunnyZone/$uId/$uIdx")
                $pwr.Method = "PUT"
                $pwr.Headers.Add("AccessKey", $bunnyApiKey)
                $pwr.ContentType = "application/octet-stream"
                $pwr.ContentLength = $pbytes.Length
                $pwr.Timeout = 180000
                $pst = $pwr.GetRequestStream()
                $pst.Write($pbytes, 0, $pbytes.Length)
                $pst.Dispose()
                $pResp = $pwr.GetResponse()
                $pResp.Dispose()
                Send-Json $res @{ ok = $true } 200
            } catch {
                Send-Json $res @{ error = $_.Exception.Message } 500
            }
            $res.Close()
            continue
        }

        if ($path -eq "/upload/finish" -and $req.HttpMethod -eq "POST") {
            $uId = ""
            try {
                $sr = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                $body = $sr.ReadToEnd()
                $sr.Dispose()
                $data = $body | ConvertFrom-Json
                $uId = [string]$data.uploadId
                $ext = ([string]$data.ext).ToLower()
                $totalParts = [int]$data.totalParts
                $totalBytes = [int64]$data.totalBytes
                $fallowed = @(".png", ".jpg", ".jpeg", ".webp", ".gif", ".pdf", ".mp3", ".m4a", ".mp4", ".m4v", ".webm", ".ogv")
                if ($uId -notmatch '^[a-f0-9]{8,64}$' -or $fallowed -notcontains $ext) {
                    Send-Json $res @{ error = "uploadId yoki fayl turi noto'g'ri" } 400
                    $res.Close()
                    continue
                }
                if ($totalParts -lt 1 -or $totalParts -gt $maxPartCount -or $totalBytes -lt 1 -or $totalBytes -gt $maxUploadBytes) {
                    Send-Json $res @{ error = "Fayl juda katta! Maksimal hajm: $maxUploadMb MB" } 413
                    $res.Close()
                    continue
                }
                $ct = @{ ".pdf" = "application/pdf"; ".png" = "image/png"; ".jpg" = "image/jpeg"; ".jpeg" = "image/jpeg"; ".webp" = "image/webp"; ".gif" = "image/gif"; ".mp3" = "audio/mpeg"; ".m4a" = "audio/mp4"; ".mp4" = "video/mp4"; ".m4v" = "video/x-m4v"; ".webm" = "video/webm"; ".ogv" = "video/ogg" }[$ext]
                $gr0 = [System.Net.HttpWebRequest]::Create("$bunnyStorage/$bunnyZone/$uId/0")
                $gr0.Method = "GET"
                $gr0.Headers.Add("AccessKey", $bunnyApiKey)
                $gr0.Timeout = 180000
                $gresp0 = $gr0.GetResponse()
                $gst0 = $gresp0.GetResponseStream()
                $ms0 = New-Object System.IO.MemoryStream
                $gst0.CopyTo($ms0)
                $headBytes = $ms0.ToArray()
                $gst0.Dispose()
                $ms0.Dispose()
                $gresp0.Dispose()
                if (-not (Test-FileSignature $headBytes $ext)) {
                    try {
                        $dr = [System.Net.HttpWebRequest]::Create("$bunnyStorage/$bunnyZone/$uId")
                        $dr.Method = "DELETE"
                        $dr.Headers.Add("AccessKey", $bunnyApiKey)
                        $dr.Timeout = 60000
                        $dresp = $dr.GetResponse()
                        $dresp.Dispose()
                    } catch {}
                    Send-Json $res @{ error = "Fayl formati tekshiruvdan o'tmayapti. O'xshash soxta/zararli fayl bo'lishi mumkin - haqiqiy fayl tanlang." } 400
                    $res.Close()
                    continue
                }
                $safe = [guid]::NewGuid().ToString("N") + $ext
                $wr = [System.Net.HttpWebRequest]::Create("$bunnyStorage/$bunnyZone/$safe")
                $wr.Method = "PUT"
                $wr.Headers.Add("AccessKey", $bunnyApiKey)
                $wr.ContentType = $ct
                $wr.ContentLength = $totalBytes
                $wr.Timeout = 300000
                $wst = $wr.GetRequestStream()
                for ($i = 0; $i -lt $totalParts; $i++) {
                    $gr = [System.Net.HttpWebRequest]::Create("$bunnyStorage/$bunnyZone/$uId/$i")
                    $gr.Method = "GET"
                    $gr.Headers.Add("AccessKey", $bunnyApiKey)
                    $gr.Timeout = 180000
                    $gresp = $gr.GetResponse()
                    $gst = $gresp.GetResponseStream()
                    $gst.CopyTo($wst)
                    $gst.Dispose()
                    $gresp.Dispose()
                }
                $wst.Dispose()
                $upResp = $wr.GetResponse()
                $upResp.Dispose()
                try {
                    $dr = [System.Net.HttpWebRequest]::Create("$bunnyStorage/$bunnyZone/$uId")
                    $dr.Method = "DELETE"
                    $dr.Headers.Add("AccessKey", $bunnyApiKey)
                    $dr.Timeout = 60000
                    $dresp = $dr.GetResponse()
                    $dresp.Dispose()
                } catch {}
                Send-Json $res @{ url = "$bunnyCdnUrl/$safe" } 200
            } catch {
                if ($uId -match '^[a-f0-9]{8,64}$') {
                    try {
                        $dr = [System.Net.HttpWebRequest]::Create("$bunnyStorage/$bunnyZone/$uId")
                        $dr.Method = "DELETE"
                        $dr.Headers.Add("AccessKey", $bunnyApiKey)
                        $dr.Timeout = 60000
                        $dresp = $dr.GetResponse()
                        $dresp.Dispose()
                    } catch {}
                }
                Send-Json $res @{ error = $_.Exception.Message } 500
            }
            $res.Close()
            continue
        }

        if ($path -eq "/upload/abort" -and $req.HttpMethod -eq "POST") {
            try {
                $sr = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                $body = $sr.ReadToEnd()
                $sr.Dispose()
                $data = $body | ConvertFrom-Json
                $uId = [string]$data.uploadId
                if ($uId -match '^[a-f0-9]{8,64}$') {
                    try {
                        $dr = [System.Net.HttpWebRequest]::Create("$bunnyStorage/$bunnyZone/$uId")
                        $dr.Method = "DELETE"
                        $dr.Headers.Add("AccessKey", $bunnyApiKey)
                        $dr.Timeout = 60000
                        $dresp = $dr.GetResponse()
                        $dresp.Dispose()
                    } catch {}
                }
                Send-Json $res @{ ok = $true } 200
            } catch {
                Send-Json $res @{ error = $_.Exception.Message } 500
            }
            $res.Close()
            continue
        }

        if ($path -eq "/health") {
            Send-Json $res @{ status = "ok"; service = "VirtualKitob"; time = (Get-Date).ToString("o") }
            $res.Close()
            continue
        }

        # ---- Ko'rishlar / reyting / izohlar: GET-POST /engage ----
        if ($path -eq "/engage") {
            try {
                $script = Join-Path $root "server-engage.mjs"
                $out = ""
                if ($req.HttpMethod -eq "POST") {
                    $srB = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                    $body = $srB.ReadToEnd()
                    $srB.Dispose()
                    $bj = $body | ConvertFrom-Json
                    $args = @("post", ("" + [string]$bj.action), ("" + [string]$bj.key))
                    if (([string]$bj.action) -eq "rate") { $args += ("" + [string]$bj.stars) }
                    elseif (([string]$bj.action) -eq "comment") { $args += ("" + [string]$bj.name); $args += ("" + [string]$bj.text) }
                    $out = (& node $script @args) -join "`n"
                } else {
                    $out = (& node $script get) -join "`n"
                }
                $obj = $out | ConvertFrom-Json
                Send-Json $res $obj 200
            } catch {
                Send-Json $res @{ error = $_.Exception.Message } 500
            }
            $res.Close()
            continue
        }

        # ---- AI tavsif (Ollama lokal): GET /ai-desc  va  POST /ai-desc {text, lang} ----
        if ($path -eq "/ai-desc") {
            try {
                $ollama = "http://localhost:11434"
                if ($req.HttpMethod -eq "GET") {
                    try {
                        $stReq = [System.Net.HttpWebRequest]::Create("$ollama/api/tags")
                        $stReq.Method = "GET"
                        $stReq.Timeout = 5000
                        $stResp = $stReq.GetResponse()
                        $srT = New-Object System.IO.StreamReader($stResp.GetResponseStream())
                        $tagsBody = $srT.ReadToEnd()
                        $srT.Dispose()
                        $stResp.Dispose()
                        $hasModel = @($tagsBody | ConvertFrom-Json | Select-Object -ExpandProperty models | ForEach-Object { $_.name } | Where-Object { $_ -match '^llama3\.1(:8b)?' }).Count -gt 0
                        Send-Json $res @{ online = $true; model = $hasModel } 200
                    } catch {
                        Send-Json $res @{ online = $false } 200
                    }
                    $res.Close()
                    continue
                }
                if ($req.HttpMethod -eq "POST") {
                    $srAd = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                    $bodyAd = $srAd.ReadToEnd()
                    $srAd.Dispose()
                    $bjAd = $bodyAd | ConvertFrom-Json
                    $textAd = ([string]$bjAd.text).Trim()
                    $langAd = "uz"
                    if ([string]$bjAd.lang -in @("uz", "ru", "en")) { $langAd = [string]$bjAd.lang }
                    if ($textAd.Length -lt 20) {
                        Send-Json $res @{ error = "Matn juda qisqa" } 400
                        $res.Close()
                        continue
                    }
                    try {
                        $chk = [System.Net.HttpWebRequest]::Create("$ollama/api/tags")
                        $chk.Method = "GET"
                        $chk.Timeout = 4000
                        $chkResp = $chk.GetResponse()
                        $chkResp.Dispose()
                    } catch {
                        Send-Json $res @{ error = "offline" } 503
                        $res.Close()
                        continue
                    }
                    if ($textAd.Length -gt 7000) { $textAd = $textAd.Substring(0, 7000) }
                    if ($langAd -eq "ru") {
                        $prompt = "Вы редактор онлайн-библиотеки VirtualKitob. Ниже часть текста книги. Напишите краткое описание этой книги на РУССКОМ языке (3-5 предложений):`n`n" + $textAd
                    } elseif ($langAd -eq "en") {
                        $prompt = "You are an editor of the VirtualKitob online library. Below is part of a book's text. Write a short description of this book in ENGLISH (3-5 sentences):`n`n" + $textAd
                    } else {
                        $prompt = "Siz VirtualKitob onlayn kutubxonasi muharririsiz. Quyida kitob matnining bir qismi keltirilgan. Shunga qarab kitob haqida O'ZBEK TILIDA qisqacha tavsif yozing (3-5 gap):`n`n" + $textAd
                    }
                    $pjs = @{ model = "llama3.1:8b"; prompt = $prompt; stream = $false; options = @{ num_predict = 400 } } | ConvertTo-Json -Compress -Depth 4
                    $pBytes = [System.Text.Encoding]::UTF8.GetBytes($pjs)
                    $gr = [System.Net.HttpWebRequest]::Create("$ollama/api/generate")
                    $gr.Method = "POST"
                    $gr.ContentType = "application/json"
                    $gr.Timeout = 300000
                    $gr.ContentLength = $pBytes.Length
                    $gs = $gr.GetRequestStream()
                    $gs.Write($pBytes, 0, $pBytes.Length)
                    $gs.Dispose()
                    $grResp = $gr.GetResponse()
                    $srG = New-Object System.IO.StreamReader($grResp.GetResponseStream(), [System.Text.Encoding]::UTF8)
                    $genBody = $srG.ReadToEnd()
                    $srG.Dispose()
                    $grResp.Dispose()
                    $genJ = $genBody | ConvertFrom-Json
                    $desc = ([string]$genJ.response).Trim()
                    if (-not $desc) {
                        Send-Json $res @{ error = "Ollama javob bermadi" } 502
                        $res.Close()
                        continue
                    }
                    Send-Json $res @{ desc = $desc } 200
                } else {
                    Send-Json $res @{ error = "Faqat GET/POST ruxsat etiladi" } 405
                }
            } catch {
                Send-Json $res @{ error = $_.Exception.Message } 500
            }
            $res.Close()
            continue
        }

        # ---- AI yordamchi: POST /ai  { q, lang, book } ----
        if ($path -eq "/ai") {
            try {
                $script = Join-Path $root "api\ai.js"
                if ($req.HttpMethod -eq "POST") {
                    $srA = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                    $bodyA = $srA.ReadToEnd()
                    $srA.Dispose()
                    $bjA = $bodyA | ConvertFrom-Json
                    $qA = ([string]$bjA.q).Trim()
                    if (-not $qA) {
                        Send-Json $res @{ error = "Savol kiritilishi shart" } 400
                        $res.Close()
                        continue
                    }
                    $langA = "uz"
                    if ([string]$bjA.lang -in @("uz", "ru", "en")) { $langA = [string]$bjA.lang }
                    $textA = ([string]$bjA.text)
                    $bodyJsonA = @{ q = $qA; lang = $langA; book = $bjA.book; text = $textA } | ConvertTo-Json -Compress -Depth 5
                    $outA = ($bodyJsonA | & node $script --stdin) -join "`n"
                    $objA = $outA | ConvertFrom-Json
                    Send-Json $res $objA 200
                } else {
                    Send-Json $res @{ status = "ok"; service = "VirtualKitob AI" } 200
                }
            } catch {
                Send-Json $res @{ error = $_.Exception.Message } 500
            }
            $res.Close()
            continue
        }

        # ---- CDN proksi (CORS muammosini yechish): /cdn/<fayl> -> bunny CDN ----
        if ($path -like "/cdn/*") {
            try {
                $cdnFile = $path.Substring(5)
                $wr = [System.Net.HttpWebRequest]::Create("$bunnyCdnUrl/$cdnFile")
                $wr.Method = "GET"
                $wr.Timeout = 120000
                $cdnResp = $wr.GetResponse()
                $stream = $cdnResp.GetResponseStream()
                $out = New-Object System.IO.MemoryStream
                $buffer = New-Object byte[] 65536
                while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) { $out.Write($buffer, 0, $read) }
                $out.Close(); $stream.Close()
                $bytes = $out.ToArray()
                $ct = $cdnResp.ContentType
                $res.ContentType = if ($ct) { $ct } else { "application/octet-stream" }
                $res.ContentLength64 = $bytes.Length
                $res.OutputStream.Write($bytes, 0, $bytes.Length)
                $cdnResp.Dispose()
            } catch {
                $res.StatusCode = 502
                $msg = [System.Text.Encoding]::UTF8.GetBytes("Proksi xato: $($_.Exception.Message)")
                $res.ContentLength64 = $msg.Length
                $res.OutputStream.Write($msg, 0, $msg.Length)
            }
            $res.Close()
            continue
        }

        if ($path -eq "/") { $path = "/index.html" }

        $fullPath = Join-Path $root ($path.TrimStart("/") -replace "/", "\")
        # Xavfsizlik - ildizdan tashqariga chiqishni bloklash
        if ($fullPath.StartsWith($root) -and (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            $ext = [System.IO.Path]::GetExtension($fullPath).ToLower()
            if ($mime.ContainsKey($ext)) { $res.ContentType = $mime[$ext] } else { $res.ContentType = "application/octet-stream" }
            $bytes = [System.IO.File]::ReadAllBytes($fullPath)
            $res.ContentLength64 = $bytes.Length
            $res.OutputStream.Write($bytes, 0, $bytes.Length)
        } else {
            $res.StatusCode = 404
            $msg = [System.Text.Encoding]::UTF8.GetBytes("404 - Topilmadi")
            $res.ContentLength64 = $msg.Length
            $res.OutputStream.Write($msg, 0, $msg.Length)
        }
        $res.Close()
        } catch {
            $m = "Request xato: $($_.Exception.Message)"
            Add-Content -LiteralPath $logFile -Value ((Get-Date).ToString("HH:mm:ss") + " " + $m)
        }
    }
} catch {
    $msg = "SERVER TO'XTADI: $($_.Exception.Message)"
    Write-Host $msg -ForegroundColor Red
    Add-Content -LiteralPath $logFile -Value ((Get-Date).ToString("HH:mm:ss") + " " + $msg)
} finally {
    try { $listener.Stop() } catch {}
    Write-Host "Server to'xtatildi."
}