# Santuario - conector de Telegram (Bot API oficial, long polling SALIENTE: no abre puertos). PowerShell 5.1, solo ASCII a proposito.
# Se carga con dot-source despues de hands.ps1 y tasks.ps1 (usa Redact-Secrets, Sanitize-Untrusted, Get-SecretDir, Get-RealFolders).
#
# Seguridad (ver agent\PLAN-AGENTE.md):
#  - El token se guarda cifrado con DPAPI en la carpeta REAL del usuario del PC (no en la USB). Nunca en logs, historial ni argumentos.
#  - Solo responde al dueno: from.id Y chat.id numericos, chat privado. Todo lo demas se ignora en silencio.
#  - Emparejamiento: codigo de un solo uso que se muestra SOLO en la consola del PC.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$script:TgCfg = ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'policy.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json).remote.telegram
$script:TgMinute = New-Object System.Collections.ArrayList
$script:TgHour = New-Object System.Collections.ArrayList

# ------------------------------------------------------------------ token (DPAPI)
function Get-TgTokenFile { Join-Path (Get-SecretDir) 'telegram.dpapi' }
function Test-TgToken { Test-Path (Get-TgTokenFile) }
function Save-TgToken([System.Security.SecureString]$sec) {
    [IO.File]::WriteAllText((Get-TgTokenFile), (ConvertFrom-SecureString $sec), [Text.Encoding]::ASCII)
}
function Get-TgTokenPlain {
    $f = Get-TgTokenFile
    if (-not (Test-Path $f)) { return $null }
    $sec = ConvertTo-SecureString ([IO.File]::ReadAllText($f).Trim())
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# ------------------------------------------------------------------ llamada a la API (unica puerta; el token vive solo aqui dentro)
# El host de la API NO se toma de policy.json sin validar: el token descifrado solo puede ir a https://api.telegram.org.
# (Las pruebas con un servidor falso local activan $script:TgAllowTestBase y aun asi solo admiten http://127.0.0.1 o localhost.)
$script:TgAllowTestBase = $false
function Test-TgBase([string]$base) {
    $b = ([string]$base).TrimEnd('/')
    if ($b -eq 'https://api.telegram.org') { return $true }
    if ($script:TgAllowTestBase) {
        $u = $null
        if ([Uri]::TryCreate($b, [UriKind]::Absolute, [ref]$u) -and $u.Scheme -eq 'http' -and ($u.Host -eq '127.0.0.1' -or $u.Host -eq 'localhost')) { return $true }
    }
    $false
}
function Invoke-Tg([string]$method, $payload = $null, [int]$timeoutSec = 30) {
    if (-not (Test-TgBase $script:TgCfg.api_base)) { throw 'api_base no permitido: el token solo se envia a https://api.telegram.org (revisa policy.json).' }
    $tok = Get-TgTokenPlain
    if (-not $tok) { throw 'Telegram no esta configurado (falta el token). Ejecuta Configurar-Telegram.bat.' }
    try {
        $url = $script:TgCfg.api_base.TrimEnd('/') + '/bot' + $tok + '/' + $method
        $body = if ($null -ne $payload) { $payload | ConvertTo-Json -Depth 6 -Compress } else { '{}' }
        $resp = Invoke-WebRequest -Uri $url -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8' -UseBasicParsing -TimeoutSec $timeoutSec
        # PowerShell 5.1 decodifica como Latin-1 si la respuesta no declara charset: se leen los bytes como UTF-8 (acentos y enes)
        $ms = $resp.RawContentStream; $ms.Position = 0
        $sr = New-Object IO.StreamReader($ms, [Text.Encoding]::UTF8)
        $r = $sr.ReadToEnd() | ConvertFrom-Json
        if (-not $r.ok) { throw ('Telegram respondio con error: ' + [string]$r.description) }
        return $r.result
    } catch {
        $m = [string]$_.Exception.Message
        if ($tok) { $m = $m.Replace($tok, '[TOKEN]') }
        throw (Redact-Secrets $m)
    } finally { $tok = $null; $url = $null }
}
function Get-TgUpdates([long]$offset, [int]$timeout) {
    $p = @{ timeout = $timeout; allowed_updates = @('message') }
    if ($offset -ne 0) { $p.offset = $offset }
    @(Invoke-Tg 'getUpdates' $p ($timeout + 15))
}

# Envia texto PLANO (sin parse_mode, sin previsualizacion de enlaces), troceado y con tope.
function Send-Tg([long]$chatId, [string]$text) {
    $max = [int]$script:TgCfg.max_reply_chars
    $text = Sanitize-Untrusted $text ($max * 3)
    $text = $text -replace '(?i)\b(?:https?|ftp)://\S+', '[enlace omitido]'      # Telegram vuelve pulsable cualquier URL: un tercero podria colarla en un resumen
    $text = $text -replace '(?i)\bwww\.\S+', '[enlace omitido]'
    $chunks = @()
    for ($i = 0; $i -lt $text.Length; $i += $max) { $chunks += $text.Substring($i, [math]::Min($max, $text.Length - $i)) }
    if ($chunks.Count -eq 0) { return }
    foreach ($c in $chunks) {
        [void](Invoke-Tg 'sendMessage' @{ chat_id = $chatId; text = $c; disable_web_page_preview = $true } 20)
        if ($chunks.Count -gt 1) { Start-Sleep -Milliseconds 1100 }
    }
}

# ------------------------------------------------------------------ dueno (lista blanca)
function Get-TgOwnerFile { Join-Path $script:TaskDir 'remote.json' }
function Get-OwnerSig([long]$userId, [long]$chatId, [string]$when) { Get-Sig ((@('owner', $userId, $chatId, $when) -join [string][char]31)) }
function Get-TgOwner {
    $f = Get-TgOwnerFile
    if (-not (Test-Path $f)) { return $null }
    try {
        $o = [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($o.user_id -and $o.chat_id -and $o.firma -and ($o.firma -eq (Get-OwnerSig ([long]$o.user_id) ([long]$o.chat_id) ([string]$o.emparejado)))) { return $o }
    } catch {}
    $null
}
function Save-TgOwner([long]$userId, [long]$chatId) {
    if (-not (Test-Path $script:TaskDir)) { New-Item -ItemType Directory -Force $script:TaskDir | Out-Null }
    $when = (Get-Date).ToString('s')
    $o = [ordered]@{ user_id = $userId; chat_id = $chatId; emparejado = $when; firma = (Get-OwnerSig $userId $chatId $when) }
    [IO.File]::WriteAllText((Get-TgOwnerFile), ($o | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
}

# Herramientas remotas (buscar en Google desde Telegram): las enciende el dueno EN EL PC, con caducidad y firma (max 24 h).
function Get-ToolsFile { Join-Path $script:TaskDir 'remote-tools.json' }
function Set-RemoteTools([int]$hours) {
    if (-not (Test-Path $script:TaskDir)) { New-Item -ItemType Directory -Force $script:TaskDir | Out-Null }
    $until = (Get-Date).AddHours([math]::Min([math]::Max($hours, 1), 24)).ToString('s')
    $o = [ordered]@{ hasta = $until; firma = (Get-Sig ('tools' + [string][char]31 + $until)) }
    [IO.File]::WriteAllText((Get-ToolsFile), ($o | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
}
function Get-RemoteToolsUntil {
    $f = Get-ToolsFile
    if (-not (Test-Path $f)) { return $null }
    try {
        $o = [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if (-not $o.firma -or $o.firma -ne (Get-Sig ('tools' + [string][char]31 + [string]$o.hasta))) { return $null }
        $u = [datetime]::Parse($o.hasta)
        if ($u -gt (Get-Date).AddHours(25)) { return $null }
        return $u
    } catch { return $null }
}
function Test-RemoteTools { $u = Get-RemoteToolsUntil; return [bool]($u -and $u -gt (Get-Date)) }
# Devuelve el mensaje SOLO si es del dueno: chat privado, mismo from.id y chat.id, texto propio (no reenviado, no de otro bot), reciente.
function Get-OwnerMessage($u, $owner) {
    $m = $u.message
    if (-not $m -or -not $m.chat -or -not $m.from) { return $null }
    if ($m.chat.type -ne 'private') { return $null }
    if ([long]$m.from.id -ne [long]$owner.user_id -or [long]$m.chat.id -ne [long]$owner.chat_id) { return $null }
    if ($m.from.is_bot) { return $null }
    if ($m.forward_origin -or $m.forward_from -or $m.forward_date -or $m.via_bot) { return $null }
    if ($m.text -isnot [string] -or -not $m.text) { return $null }
    $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [long]$m.date
    if ($age -gt [int]$script:TgCfg.drop_older_than_sec) { return $null }
    $m
}
# Limite por remitente autorizado (6/min, 60/hora por defecto).
function Test-TgRate {
    $now = Get-Date
    foreach ($pair in @(@($script:TgMinute, 60), @($script:TgHour, 3600))) {
        $list = $pair[0]
        for ($i = $list.Count - 1; $i -ge 0; $i--) { if (($now - $list[$i]).TotalSeconds -ge $pair[1]) { $list.RemoveAt($i) } }
    }
    if ($script:TgMinute.Count -ge [int]$script:TgCfg.rate_per_min -or $script:TgHour.Count -ge [int]$script:TgCfg.rate_per_hour) { return $false }
    [void]$script:TgMinute.Add($now); [void]$script:TgHour.Add($now)
    $true
}

# ------------------------------------------------------------------ emparejamiento (solo el dueno de la consola lo inicia)
function New-PairCode {
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $b = New-Object byte[] 8; $rng.GetBytes($b)
    $s = -join ($b | ForEach-Object { $alphabet[$_ % $alphabet.Length] })
    $s.Substring(0, 4) + '-' + $s.Substring(4, 4)
}
# Espera "/emparejar CODIGO" en un chat privado. 3 intentos fallidos o el tiempo cancelan la ventana. Ignora mensajes antiguos.
function Wait-TgPairing([string]$code, [int]$timeoutMin = 10) {
    $deadline = (Get-Date).AddMinutes($timeoutMin); $fails = 0; $offset = [long]0
    $old = @(Get-TgUpdates -1 0)
    if ($old.Count -gt 0) { $offset = [long]$old[$old.Count - 1].update_id + 1 }
    while ((Get-Date) -lt $deadline -and $fails -lt 3) {
        $ups = @(Get-TgUpdates $offset 5)
        foreach ($u in $ups) {
            $offset = [long]$u.update_id + 1
            $m = $u.message
            if (-not $m -or $m.chat.type -ne 'private' -or $m.from.is_bot -or $m.forward_origin -or $m.forward_from -or $m.via_bot -or $m.text -isnot [string]) { continue }
            if ($m.text.Trim() -match '^/emparejar\s+(\S+)$') {
                if ($Matches[1].ToUpperInvariant() -eq $code.ToUpperInvariant()) {
                    Save-TgOwner ([long]$m.from.id) ([long]$m.chat.id)
                    try { Send-Tg ([long]$m.chat.id) 'Santuario emparejado. Soy tu agente local. Escribe /ayuda para ver que puedo hacer desde aqui.' } catch {}
                    [void](Get-TgUpdates $offset 0)       # confirma los mensajes procesados
                    return @{ ok = $true }
                }
                $fails++
            }
        }
    }
    @{ ok = $false; error = $(if ($fails -ge 3) { 'demasiados intentos fallidos' } else { 'se agoto el tiempo' }) }
}
