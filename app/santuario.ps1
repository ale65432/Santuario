# Santuario - enrutador del cerebro (PowerShell 5.1). Solo ASCII a proposito.
# Lee las regiones de brain.json, elige la region segun la solicitud y la RAM libre, y mantiene un modelo en RAM.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName Microsoft.VisualBasic

. (Join-Path $PSScriptRoot 'lib.ps1')

# --- Encabezado fijo (Zeus + SANTUARIO, ~25% de la terminal) ---
. (Join-Path $PSScriptRoot 'header.ps1')

function Show-Brain {
    Write-Host ''
    Write-Host ("  Cerebro de {0}   (RAM: {1} GB total, {2} GB libres)" -f $Brain.name, (Total-GB), (Avail-GB)) -ForegroundColor Cyan
    foreach ($r in $Brain.regions) {
        $st = if ($Installed[$r.model]) { 'ok   ' } else { 'FALTA' }
        $col = if ($Installed[$r.model]) { 'Gray' } else { 'DarkYellow' }
        Write-Host ("  [{0}] /{1,-13} {2,-27} {3,-30} ~{4} GB" -f $st, $r.id, $r.label, $r.base_name, $r.ram_gb) -ForegroundColor $col
    }
    Write-Host ''
}

$http = New-Object System.Net.Http.HttpClient
$http.Timeout = [TimeSpan]::FromMinutes(30)

function Chat([string]$model, $messages) {
    $payload = @{ model = $model; messages = $messages; stream = $true; think = $false } | ConvertTo-Json -Depth 6
    $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Post), "$Base/api/chat"
    $req.Content = New-Object System.Net.Http.StringContent ($payload, [Text.Encoding]::UTF8, 'application/json')
    $resp = $http.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    if (-not $resp.IsSuccessStatusCode) {
        $err = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        throw "Ollama respondio $($resp.StatusCode): $err"
    }
    $reader = New-Object IO.StreamReader ($resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult(), [Text.Encoding]::UTF8)
    $full = New-Object Text.StringBuilder
    $stats = $null
    while (-not $reader.EndOfStream) {
        $line = $reader.ReadLine()
        if (-not $line) { continue }
        $o = $line | ConvertFrom-Json
        if ($o.message -and $o.message.content) {
            [Console]::Write($o.message.content)
            [void]$full.Append($o.message.content)
        }
        if ($o.done) { $stats = $o }
    }
    $reader.Dispose()
    Write-Host ''
    if ($stats -and $stats.eval_duration -gt 0) {
        $tps = [math]::Round($stats.eval_count / ($stats.eval_duration / 1e9), 1)
        Write-Host ("  [{0} tokens, {1} tok/s]" -f $stats.eval_count, $tps) -ForegroundColor DarkGray
    }
    $full.ToString()
}

# ui.header_fixed (brain.json): false = scroll normal de la terminal (por defecto); true = encabezado anclado sin historial
$fixedHdr = [bool]($Brain.ui -and $Brain.ui.header_fixed)
$splashShown = Show-Header $fixedHdr
Set-Status 'iniciando el cerebro (Ollama)...'
if (-not $fixedHdr) { Write-Host '  iniciando el cerebro (Ollama)...' -ForegroundColor DarkGray }
if (-not (Wait-Ollama)) {
    Write-Host '  No se pudo iniciar Ollama (puerto 11434 ocupado o bloqueado).' -ForegroundColor Red
    Read-Host 'Enter para salir' | Out-Null
    Reset-Header
    exit 1
}
if (-not (Test-OllamaIsOurs)) {
    Write-Host '  ALERTA: el puerto de Ollama lo tiene ocupado OTRO programa (no es el Ollama de esta USB). Cierralo y vuelve a abrir Santuario.' -ForegroundColor Red
    Read-Host 'Enter para salir' | Out-Null
    Reset-Header
    exit 1
}
$Installed = Get-Installed
# retencion: los registros de chat y de auditoria de la consola se borran a los 30 dias (la USB puede perderse)
try { $cut30 = (Get-Date).AddDays(-30); Get-ChildItem (Join-Path $Root 'logs') -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(chat-.*\.txt|audit-\d{4}-.*\.jsonl)$' -and $_.LastWriteTime -lt $cut30 } | ForEach-Object { [IO.File]::Delete($_.FullName) } } catch {}
Set-Status ("listo | RAM {0} GB total, {1} GB libres | /cerebro muestra las regiones" -f (Total-GB), (Avail-GB))
Write-Host ''
if (-not $splashShown) { Write-Host '  S A N T U A R I O' -ForegroundColor Cyan }
Write-Host '  Tu cerebro local y portable. Cada solicitud va a la region adecuada.' -ForegroundColor DarkGray
if (-not $Installed[$Regions[$Default].model]) {
    Write-Host '  El cerebro no esta instalado. Cierra y ejecuta Instalar-Cerebro.bat.' -ForegroundColor Red
    Show-Brain
    Read-Host 'Enter para salir' | Out-Null
    Reset-Header
    exit 1
}
Show-Brain
# Enlace con el agente 24/7 integrado: el agente se cierra solo cuando esta consola termina
try { $cpd = Join-Path $Root 'data\agent'; New-Item -ItemType Directory -Force $cpd | Out-Null; [IO.File]::WriteAllText((Join-Path $cpd 'console.pid'), [string]$PID, [Text.Encoding]::ASCII) } catch {}
if ($env:SANT_INTEGRADO -eq '1') { Write-Host '  Agente 24/7 integrado: tareas programadas y Telegram arrancan en segundo plano (/agente para ver el estado).' -ForegroundColor DarkGray }
Write-Host '  Comandos: /cerebro  /auto  /<region>  /manos  /tareas  /agente  /avisos  /remoto  /taller  /reset  /bye' -ForegroundColor DarkGray
Write-Host '  Tareas: "recuerdame manana a las 9 ..." | "cada dia a las 8 busca ..."  (las ejecuta el agente: Santuario-Agente.bat)' -ForegroundColor DarkGray
Write-Host '  Auto: si una region con filtros se niega a responder, reintenta con la region libre.' -ForegroundColor DarkGray
Write-Host ''

$mode = 'auto'
$history = New-Object System.Collections.ArrayList
$loaded = $null
$loadedRam = 0.0
$MaxMsgs = 12

# Manos (Edge + programas). Apagadas por defecto; se activan con /manos. Ver agent\PLAN.md y agent\policy.json
. (Join-Path $Root 'agent\hands.ps1')
# Tareas programadas y agente 24/7 (el demonio las ejecuta; aqui se crean y se gestionan). Ver agent\PLAN-AGENTE.md
. (Join-Path $Root 'agent\tasks.ps1')
. (Join-Path $Root 'agent\telegram.ps1')
. (Join-Path $Root 'agent\console-agent.ps1')
# Habilidades del taller (leer/analizar/mejorar codigo, revisar el PC, crear paginas web). Solo consola. Ver agent\PLAN-SKILLS.md
. (Join-Path $Root 'agent\skills\skills.ps1')
Show-Inbox $true

# Precalentado: carga la region por defecto en segundo plano mientras el dueno escribe, para que el primer mensaje no espere la carga.
# Solo si hay RAM de sobra (min_free_ram_gb + 0.5 GB) y nadie la tiene cargada; no bloquea la consola.
try {
    $warm = Resolve-Region $Default 0.0
    if ($warm -and $Installed[$warm.model] -and (Avail-GB) -ge ([double]$warm.min_free_ram_gb + 0.5) -and $warm.id -eq $Default) {
        $wb = @{ model = $warm.model; prompt = ''; keep_alive = '10m'; stream = $false } | ConvertTo-Json
        $wr = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Post), "$Base/api/generate"
        $wr.Content = New-Object System.Net.Http.StringContent ($wb, [Text.Encoding]::UTF8, 'application/json')
        [void]$http.SendAsync($wr)                      # fire-and-forget
        $loaded = $warm.model; $loadedRam = [double]$warm.ram_gb
        Write-Host ("  (precalentando {0} en segundo plano)" -f $warm.label) -ForegroundColor DarkGray
    }
} catch {}

try {
while ($true) {
    $q = Read-Host 'tu'
    if ([string]::IsNullOrWhiteSpace($q)) { continue }
    $t = $q.Trim().ToLowerInvariant()
    if ($t -in '/bye', '/exit', '/salir') { break }
    if ($t -eq '/manos') {
        $script:HandsOn = $true; Show-HandsInfo; Write-Audit 'manos' 'on' 'dueno' 'activadas'
        Set-Status 'manos ACTIVAS: Edge saldra a internet; el modelo sigue local'
        continue
    }
    if ($t -eq '/manos off') {
        $script:HandsOn = $false; Close-HandsEdge; Write-Audit 'manos' 'off' 'dueno' 'desactivadas'
        Write-Host '  (manos apagadas; Edge de Santuario cerrado)' -ForegroundColor DarkGray; continue
    }
    if ($t -eq '/manos login') {
        if (Test-StopFlag) { Write-Host '  Manos detenidas (existe agent\STOP).' -ForegroundColor Red; continue }
        $script:HandsOn = $true
        try {
            $lr = Do-OpenUrl 'https://www.youtube.com/' $false 'youtube'
            Write-Audit 'login' 'youtube' 'auto' $lr.msg
            Write-Host ('  ' + $lr.msg) -ForegroundColor Cyan
            if ($lr.ok) { Set-Ctx 'youtube' }
            Write-Host '  Inicia sesion TU MISMO en la ventana de Edge (YouTube, redes). Santuario no ve ni escribe tus credenciales.' -ForegroundColor Gray
            Read-Host '  Cuando termines, pulsa Enter' | Out-Null
        } catch { Stop-HandsSafe $_.Exception.Message }
        continue
    }
    if ($t -eq '/manos borrar-sesion') {
        try { Clear-HandsProfile } catch { Stop-HandsSafe $_.Exception.Message }
        continue
    }
    if ($t -eq '/reset') { $history.Clear(); Write-Host '  (historial borrado)' -ForegroundColor DarkGray; continue }
    if ($t -eq '/cerebro') { $Installed = Get-Installed; Show-Brain; continue }
    if ($t -eq '/auto') { $mode = 'auto'; Write-Host '  (modo: auto)' -ForegroundColor DarkGray; continue }
    if ($t.StartsWith('/') -and $Regions.Contains($t.TrimStart('/'))) {
        $mode = $t.TrimStart('/'); Write-Host "  (modo fijo: $mode)" -ForegroundColor DarkGray; continue
    }
    try { if (Handle-SkillCommand $t $q) { Write-Host ''; continue } } catch { Stop-HandsSafe $_.Exception.Message; continue }
    try { if (Handle-AgentCommand $t $q) { continue } } catch { Stop-HandsSafe $_.Exception.Message; continue }
    if ($t.StartsWith('/')) { Write-Host '  Comando desconocido. Usa /cerebro para ver las regiones.' -ForegroundColor DarkYellow; continue }

    # Habilidades del taller en lenguaje natural ("analiza el codigo de la carpeta ...", "revisa la seguridad de mi pc", "crea una pagina web ...").
    try { if (Handle-SkillIntent $q) { Write-Host ''; continue } } catch { Stop-HandsSafe $_.Exception.Message; continue }

    # Tareas programadas en lenguaje natural ("recuerdame manana a las 9...", "cada dia a las 8 busca..."): el codigo pide confirmacion.
    if (Test-TaskIntent $q) { try { Handle-ConsoleTask $q } catch { Stop-HandsSafe $_.Exception.Message }; Write-Host ''; continue }

    # Peticiones de "manos" (abrir sitios/programas, buscar): las atiende el ejecutor con politica y confirmaciones.
    # Nunca pasan por el reintento hacia la region libre ni por el enrutado por contenido.
    if (Invoke-HandsRequest $q) { Write-Host ''; continue }

    $want = if ($mode -eq 'auto') { Pick-Region $q } else { $mode }
    $region = Resolve-Region $want $loadedRam
    $model = $region.model
    if ($loaded -ne $model) {
        if ($loaded) { Unload $loaded }
        $note = if ($region.id -ne $want) { " (pedida: $want, ajustada por RAM/instalacion)" } else { '' }
        Write-Host ("  -> {0} [{1}]{2}" -f $region.label, $region.base_name, $note) -ForegroundColor Yellow
        Write-Host '  (cargando region, la primera vez tarda)' -ForegroundColor DarkGray
    }
    $loaded = $model; $loadedRam = [double]$region.ram_gb
    Set-Status ("region: {0} [{1}] | RAM libre {2} GB" -f $region.label, $region.base_name, (Avail-GB))

    [void]$history.Add(@{ role = 'user'; content = $q })
    while ($history.Count -gt $MaxMsgs) { $history.RemoveAt(0) }
    # presupuesto de contexto (num_ctx 4096 ~ 12000 caracteres incluyendo el sistema): se descartan los turnos mas viejos antes de que Ollama recorte a ciegas
    $histChars = 0; foreach ($hm in $history) { $histChars += ([string]$hm.content).Length }
    while ($history.Count -gt 1 -and $histChars -gt 8000) { $histChars -= ([string]$history[0].content).Length; $history.RemoveAt(0) }
    try {
        $answer = Chat $model @($history)
        if ($mode -eq 'auto' -and $region.id -notin $LibreFamily -and (Normalize $answer) -match $RefusalRx) {
            $region = Resolve-Region 'libre' $loadedRam
            Write-Host ("  -> rechazo detectado, reintentando con: {0} [{1}]" -f $region.label, $region.base_name) -ForegroundColor Yellow
            if ($loaded -ne $region.model) { Unload $loaded; Write-Host '  (cargando region, la primera vez tarda)' -ForegroundColor DarkGray }
            $loaded = $region.model; $loadedRam = [double]$region.ram_gb
            $answer = Chat $region.model @($history)
        }
        [void]$history.Add(@{ role = 'assistant'; content = $answer })
        # Registro en disco: la region de scroll no conserva historial, asi que nada se pierde
        try {
            $logFile = Join-Path $Root ("logs\chat-{0}.txt" -f (Get-Date -Format 'yyyy-MM-dd'))
            if (-not ($Brain.ui -and $Brain.ui.chat_log -eq $false)) { [IO.File]::AppendAllText($logFile, ("[{0}] tu: {1}`r`n[{2}] santuario ({3}): {4}`r`n`r`n" -f (Get-Date -Format 'HH:mm:ss'), (Redact-Secrets $q), (Get-Date -Format 'HH:mm:ss'), $region.id, (Redact-Secrets $answer)), (New-Object Text.UTF8Encoding($false))) }
        } catch {}
    } catch {
        Write-Host ("  ERROR: " + $_.Exception.Message) -ForegroundColor Red
        [void]$history.RemoveAt($history.Count - 1)
    }
    Write-Host ''
}
} finally {
    if ($script:Pol.browser.close_edge_on_exit) { Close-HandsEdge }
    try { [IO.File]::Delete((Join-Path $Root 'data\agent\console.pid')) } catch {}
}
if ($loaded) { Unload $loaded }
Reset-Header
