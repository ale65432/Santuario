# Santuario - DEMONIO del agente 24/7 (PowerShell 5.1, solo ASCII a proposito).
# Ejecuta tareas programadas y atiende el canal remoto (Telegram). Se lanza con Santuario-Agente.bat (vigilante con reinicio).
#
# Diseno de seguridad (ver agent\PLAN-AGENTE.md):
#  - Proceso APARTE de Ollama: Ollama sigue en modo local (sin internet); solo este proceso habla con Telegram.
#  - Origen de las acciones: 'remoto' (Telegram) y 'tarea' (programadas) NO pueden abrir programas ni sitios ni reproducir audio.
#  - Desde Telegram: charla (region fija, con filtros, sin reintento a la region libre), gestionar tareas y, si el dueno lo habilita en el PC,
#    buscar en Google (perfil de Edge efimero). Todo lo demas se rechaza.
#  - Mensajes de desconocidos: se ignoran en silencio. El contenido de los mensajes NO se registra.
#  - agent\STOP pausa todo (tareas y herramientas). Las tareas atrasadas no se repiten solas.
#  - Si policy.json cambia respecto a lo que el dueno aprobo, el canal remoto se desactiva hasta que lo apruebe en la consola.
# Codigos de salida: 0 = parada limpia | 2 = fallo al arrancar o Ollama caido | 3 = fallo tras estar funcionando un rato.
param([switch]$Once, [string]$TestApiBase = '', [string]$TestRoot = '', [switch]$TestStubModel, [switch]$TestHighRate)
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$script:T0 = Get-Date

$AppDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'app'
. (Join-Path $AppDir 'lib.ps1')
. (Join-Path $PSScriptRoot 'hands.ps1')
. (Join-Path $PSScriptRoot 'tasks.ps1')
. (Join-Path $PSScriptRoot 'telegram.ps1')
# --- modos de PRUEBA (aislan el demonio en una carpeta temporal, con un Telegram falso local y sin modelos); no se usan en produccion
if ($TestApiBase) { $script:TgCfg.api_base = $TestApiBase; $script:TgAllowTestBase = $true }
if ($TestRoot) {
    $script:TRoot = $TestRoot; $script:SantRoot = $TestRoot
    $script:TaskDir = Join-Path $TestRoot 'data\agent'
    $script:SecretDirOverride = Join-Path $TestRoot 'secret'
    $script:AgentDir = Join-Path $TestRoot 'agent'
    foreach ($d in $script:AgentDir, $script:TaskDir) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force $d | Out-Null } }
}
if ($TestHighRate) { $script:TgCfg.rate_per_min = 1000; $script:TgCfg.rate_per_hour = 10000 }
if ($TestStubModel) {
    function Wait-Ollama { $true }
    function Get-Installed { @{ 'santuario-general' = $true } }
    function Ask-Model { param($model, $messages, $numPredict, $temp, $timeoutSec) 'respuesta simulada' }
}

$script:Origin = 'tarea'
$script:AuditTag = 'daemon'
$script:Pol.browser.profile_mode = 'ephemeral'                      # el demonio NUNCA usa el perfil con sesiones iniciadas
$script:HandsOn = $true
$DPol = $script:TPol.daemon
$RPol = $script:TPol.remote
$script:RemoteHistory = New-Object System.Collections.ArrayList
$script:Owner = $null
$script:Offset = [long]0
$script:LogDir = Join-Path $script:TRoot 'logs'
$script:RunDir = $script:TaskDir
foreach ($d in $script:LogDir, $script:RunDir) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force $d | Out-Null } }

# Que un clic en la ventana (QuickEdit) no congele el agente.
try {
    Add-Type -Namespace Win -Name Qe -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int h); [DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint m); [DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint m);' -ErrorAction SilentlyContinue
    $qh = [Win.Qe]::GetStdHandle(-10); $qm = [uint32]0
    if ([Win.Qe]::GetConsoleMode($qh, [ref]$qm)) { [void][Win.Qe]::SetConsoleMode($qh, [uint32](($qm -band [uint32]4294967231) -bor [uint32]128)) }
} catch {}

# ------------------------------------------------------------------ registro (metadatos; nunca contenido de mensajes ni secretos)
function Log-Line([string]$msg) {
    try {
        $f = Join-Path $script:LogDir ('daemon-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd'))
        if ((Test-Path $f) -and ((Get-Item $f).Length -gt ([int]$DPol.log_max_kb * 1KB))) { return }
        [IO.File]::AppendAllText($f, ('{0} {1}' -f (Get-Date -Format 'HH:mm:ss'), (Redact-Secrets $msg)) + "`r`n", (New-Object Text.UTF8Encoding($false)))
    } catch {}
}
function Remove-OldLogs {
    try {
        $cut = (Get-Date).AddDays(-[int]$DPol.log_keep_days)
        Get-ChildItem $script:LogDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(daemon-.*\.log|audit-daemon-.*\.jsonl)$' -and $_.LastWriteTime -lt $cut } | Remove-Item -Force -ErrorAction SilentlyContinue
    } catch {}
}
function Show([string]$msg, [string]$color = 'Gray') { Write-Host ('{0} {1}' -f (Get-Date -Format 'HH:mm:ss'), (Sanitize-Untrusted (Redact-Secrets $msg) 600)) -ForegroundColor $color }

# ------------------------------------------------------------------ entrega de avisos
function Add-Inbox([string]$text) {
    try {
        $f = Join-Path $script:RunDir 'inbox.txt'
        if ((Test-Path $f) -and ((Get-Item $f).Length -gt 200KB)) { return }          # tope: no crece sin limite
        [IO.File]::AppendAllText($f, ('[{0}] {1}' -f (Get-Date -Format 'dd/MM HH:mm'), (Sanitize-Untrusted $text 3000)) + "`r`n---`r`n", (New-Object Text.UTF8Encoding($false)))
    } catch {}
}
function Deliver-Message([string]$canal, [string]$text, [string]$id = '') {
    Log-Line ('aviso canal=' + $canal + ' tarea=' + $id)
    if ($canal -eq 'telegram' -and $script:Owner -and $script:TgReady) {
        try { Send-Tg ([long]$script:Owner.chat_id) $text; return } catch { Log-Line ('error al enviar por telegram: ' + $_.Exception.Message) }
    }
    Add-Inbox $text          # canal consola (o telegram caido): queda en el buzon que la consola muestra al abrir
    Show ('[aviso] ' + $text) 'Cyan'
}

# ------------------------------------------------------------------ canal remoto: texto del dueno -> respuesta
function Remote-Help {
    "Santuario (agente local). Desde aqui puedo:`n" +
    "- Conversar contigo (modelo local).`n" +
    "- Programar recordatorios: ""recuerdame manana a las 9 llamar al banco"".`n" +
    "- /tareas  /cancelar t1  /estado  /stop  /reanudar`n" +
    "- Buscar en Google solo si lo habilitas en el PC (/remoto herramientas on).`n" +
    "No abro programas ni sitios ni reproduzco audio desde Telegram."
}
function Remote-Status {
    $all = @(Load-Tasks)
    $act = @($all | Where-Object { $_.estado -eq 'activa' }).Count
    $pen = @($all | Where-Object { $_.estado -eq 'pendiente' }).Count
    $up = [int]((Get-Date) - $script:T0).TotalMinutes
    ('En linea. Activo hace {0} min. Tareas activas: {1}, pendientes de aprobar: {2}. RAM libre: {3} GB. Herramientas remotas: {4}.{5}' -f $up, $act, $pen, (Avail-GB), $(if (Test-RemoteTools) { 'ON' } else { 'OFF' }), $(if (Test-StopFlag) { ' PAUSADO (STOP).' } else { '' }))
}
function Remote-ListTasks {
    $l = @(@(Load-Tasks) | Where-Object { $_.estado -in 'activa', 'pendiente' })
    if ($l.Count -eq 0) { return 'No hay tareas vigentes.' }
    ($l | ForEach-Object { Format-Task $_ }) -join "`n"
}
function Remote-Chat([string]$text) {
    $region = Resolve-Region ([string]$RPol.region) 0          # region fija con filtros; nunca /libre ni reintento por rechazo
    $sys = 'Eres Santuario, el agente local de tu dueno, y hablas con el por Telegram. Responde en espanol, claro y breve (maximo 8 lineas). ' +
           'Desde este canal NO puedes abrir programas, sitios ni reproducir audio: si te lo piden, di que lo haga en el PC. No inventes datos.'
    $msgs = @(@{ role = 'system'; content = $sys })
    foreach ($h in $script:RemoteHistory) { $msgs += $h }
    $msgs += @{ role = 'user'; content = $text }
    $ans = Ask-Model $region.model $msgs 300 0.5 ([int]$RPol.model_timeout_sec)
    [void]$script:RemoteHistory.Add(@{ role = 'user'; content = $text }); [void]$script:RemoteHistory.Add(@{ role = 'assistant'; content = $ans })
    while ($script:RemoteHistory.Count -gt [int]$RPol.history_msgs) { $script:RemoteHistory.RemoveAt(0) }
    $ans.Trim()
}
function Remote-Search([string]$query) {
    if (-not (Test-RemoteTools)) { return 'Las herramientas remotas estan apagadas. Habilitalas en el PC con /remoto herramientas on (caducan solas).' }
    $r = Do-GoogleSearch $query
    if (-not $r.ok) { return ('No pude buscar: ' + $r.msg) }
    $sum = Summarize-Silent $query $r.results
    $lines = @(); $i = 0
    foreach ($x in $r.results) {
        $i++; if ($i -gt 4) { break }
        $hn = ''; $uu = Test-HttpsUrl $x.u
        if ($uu -and -not (Host-Allowed $uu.Host @('google.com'))) { $hn = ' [' + $uu.Host + ']' }
        $lines += ('{0}. {1}{2}' -f $i, $x.t, $hn)
    }
    ('Busqueda "' + $r.query + '":' + "`n" + $sum + "`n`n" + ($lines -join "`n"))          # sin enlaces: los redirectores los controla un tercero
}
function Handle-Remote([string]$raw) {
    $text = (Sanitize-Untrusted $raw ([int]$script:TgCfg.max_msg_chars)).Trim()
    $n = Normalize $text
    if ($n -match '^/(start|ayuda|help)\b') { return (Remote-Help) }
    if ($n -match '^/estado\b') { return (Remote-Status) }
    if ($n -match '^/tareas\b') { return (Remote-ListTasks) }
    if ($n -match '^/cancelar\s+(t\d+)\b') {
        if (Set-TaskState $Matches[1] 'cancelada') { Write-Audit 'tarea' $Matches[1] 'auto' 'cancelada' 'remoto'; return ('Tarea ' + $Matches[1] + ' cancelada.') }
        return 'No encontre esa tarea (o ya no esta vigente).'
    }
    if ($n -match '^/stop\b') {
        [IO.File]::WriteAllText((Join-Path $script:AgentDir 'STOP'), 'remoto', [Text.Encoding]::ASCII)
        Write-Audit 'stop' 'remoto' 'auto' 'pausado'; Log-Line 'STOP remoto'
        return 'Pausado: ya no ejecuto tareas ni herramientas. /reanudar para seguir.'
    }
    if ($n -match '^/reanudar\b') {
        $sf = Join-Path $script:AgentDir 'STOP'
        if (-not (Test-Path $sf)) { return 'No estaba pausado.' }
        if (([IO.File]::ReadAllText($sf)).Trim() -eq 'remoto') { Remove-Item $sf -Force; Log-Line 'reanudado por remoto'; return 'Reanudado.' }
        return 'La pausa se puso desde el PC; solo se levanta alli (borrando agent\STOP).'
    }
    if (Test-StopFlag) { return 'Estoy en pausa (STOP). Escribe /reanudar o /estado.' }
    if ($n.StartsWith('/')) { return 'Comando no reconocido. /ayuda'}
    if (Test-TaskIntent $text) {
        $p = Parse-TaskRequest $text
        if (-not $p.ok) { return ('No pude programar eso: ' + $p.error + '. Ejemplo: "recuerdame manana a las 9 llamar al banco".') }
        $c = Add-Task $p 'remoto' 'telegram'
        if (-not $c.ok) { return ('No pude programar eso: ' + $c.error) }
        Write-Audit 'tarea' $c.task.id 'auto' ('creada ' + $c.task.tipo + ' estado=' + $c.task.estado) 'remoto'
        $when = Format-When $c.task.cuando
        if ($c.task.estado -eq 'pendiente') {
            Show ('Tarea ' + $c.task.id + ' (' + $c.task.tipo + ') pendiente de aprobacion en el PC.') 'Yellow'
            return ('Anotado (' + $c.task.id + ', ' + $c.task.tipo + ', ' + $when + '), pero queda PENDIENTE: apruebala en el PC con /aprobar ' + $c.task.id + '.')
        }
        return ('Listo ' + $c.task.id + ': ' + $c.task.tipo + ' "' + $c.task.texto + '" (' + $when + ').')
    }
    if ($n -match '^(?:busca|buscar|investiga|investigar|googlea)\s+(.+)$') {
        $q = Clean-Query ($Matches[1] -replace '(?i)\s+en\s+google$', '')
        if (-not $q -or (Test-LongOrCode $text)) { return 'Dime una consulta corta (sin codigo), por ejemplo: "busca clima en Monterrey".' }
        return (Remote-Search $q)
    }
    return (Remote-Chat $text)
}

# ------------------------------------------------------------------ estado de Telegram (se reconecta solo, con espera creciente)
$script:TgReady = $false
$script:TgNextTry = [datetime]::MinValue
$script:TgBackoff = 5
$script:TgFails = 0
$script:Ignored = 0
$script:PolicyOk = $true
function Try-ConnectTelegram {
    if ((Get-Date) -lt $script:TgNextTry) { return }
    try {
        [void](Invoke-Tg 'deleteWebhook' @{ drop_pending_updates = $false })
        $old = @(Get-TgUpdates -1 0)                              # descarta lo acumulado mientras estaba apagado
        if ($old.Count -gt 0) { $script:Offset = [long]$old[$old.Count - 1].update_id + 1 }
        $script:TgReady = $true; $script:TgBackoff = 5; $script:TgFails = 0
        Show 'Telegram conectado (dueno emparejado).' 'Green'; Log-Line 'telegram ok'
        try { Send-Tg ([long]$script:Owner.chat_id) ('Santuario en linea. ' + (Remote-Status)) } catch {}
    } catch {
        Log-Line ('telegram no disponible (reintento en ' + $script:TgBackoff + ' s): ' + $_.Exception.Message)
        $script:TgNextTry = (Get-Date).AddSeconds($script:TgBackoff); $script:TgBackoff = [math]::Min(300, $script:TgBackoff * 2)
    }
}
# El dueno se relee en cada vuelta: "/remoto desvincular" o un emparejamiento nuevo surten efecto sin reiniciar el agente.
function Refresh-Owner {
    $o = if ($script:PolicyOk) { Get-TgOwner } else { $null }
    if (-not (Test-TgToken)) { $o = $null }
    $same = ($null -eq $o -and $null -eq $script:Owner) -or ($o -and $script:Owner -and [long]$o.user_id -eq [long]$script:Owner.user_id -and [long]$o.chat_id -eq [long]$script:Owner.chat_id)
    if (-not $same) {
        $script:Owner = $o; $script:TgReady = $false; $script:TgNextTry = [datetime]::MinValue; $script:TgBackoff = 5
        if ($o) { Log-Line 'dueno emparejado/cambiado'; Show 'Dueno de Telegram detectado.' 'Green' } else { Log-Line 'dueno desvinculado o canal remoto desactivado'; Show 'Canal remoto de Telegram desactivado.' 'Yellow' }
    }
}
function Check-Policy {
    $s = Test-PolicyApproved
    if ($s -eq 'nuevo') { Approve-Policy; Log-Line 'politica registrada (primera vez)'; $script:PolicyOk = $true }
    elseif ($s -eq 'ok') { if (-not $script:PolicyOk) { Log-Line 'politica aprobada de nuevo'; Show 'Politica aprobada.' 'Green' }; $script:PolicyOk = $true }
    else {
        if ($script:PolicyOk) { Log-Line 'policy.json CAMBIO: canal remoto desactivado'; Show 'policy.json cambio desde lo que aprobaste: canal remoto DESACTIVADO. En la consola escribe /agente aprobar.' 'Red' }
        $script:PolicyOk = $false
    }
}

# ------------------------------------------------------------------ bucle
function Process-Updates {
    try { $ups = @(Get-TgUpdates $script:Offset ([int]$script:TgCfg.poll_timeout_sec)) }
    catch { Log-Line ('error al consultar telegram: ' + $_.Exception.Message); $script:TgFails++; Start-Sleep -Seconds ([math]::Min(60, [math]::Pow(2, [math]::Min($script:TgFails, 6)))); return }
    $script:TgFails = 0
    foreach ($u in $ups) {
        $script:Offset = [long]$u.update_id + 1
        $m = Get-OwnerMessage $u $script:Owner
        if (-not $m) {
            $script:Ignored++                                         # desconocidos, grupos, reenvios, medios...: silencio
            $mm = $u.message
            if ($mm -and $mm.from -and $mm.chat -and [long]$mm.from.id -eq [long]$script:Owner.user_id -and [long]$mm.chat.id -eq [long]$script:Owner.chat_id -and $mm.date) {
                $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [long]$mm.date
                if ($age -gt [int]$script:TgCfg.drop_older_than_sec) { Log-Line ('mensaje del dueno descartado por antiguedad (' + $age + ' s): revisa el reloj del PC') }
            }
            continue
        }
        $exempt = ($m.text -match '^/(stop|estado|reanudar)\b')       # la parada de emergencia no se frena con el limite de mensajes
        if (-not (Test-TgRate) -and -not $exempt) { Log-Line 'limite de mensajes del dueno'; continue }
        if ($m.text.Length -gt [int]$script:TgCfg.max_msg_chars) { try { Send-Tg ([long]$m.chat.id) ('Mensaje demasiado largo (maximo ' + $script:TgCfg.max_msg_chars + ' caracteres).') } catch {}; continue }
        Log-Line ('mensaje del dueno ({0} caracteres)' -f $m.text.Length)
        $script:Origin = 'remoto'
        try { $reply = Handle-Remote $m.text } catch { $reply = 'Error interno al procesar eso.'; Log-Line ('error: ' + $_.Exception.Message) } finally { $script:Origin = 'tarea' }
        try { Send-Tg ([long]$m.chat.id) $reply } catch { Log-Line ('error al responder: ' + $_.Exception.Message) }
    }
}

$mutex = $null; $owned = $false
try {
    $created = $false
    $mutex = New-Object System.Threading.Mutex($true, 'Local\SantuarioAgente', [ref]$created)
    if (-not $created) { Show 'Ya hay un agente corriendo (mutex). Salgo sin tocar nada.' 'Yellow'; exit 0 }
    $owned = $true                                    # solo la instancia DUENA limpia pid, Edge y mutex al salir
    [IO.File]::WriteAllText((Join-Path $script:RunDir 'daemon.pid'), [string]$PID, [Text.Encoding]::ASCII)
    if ($DPol.keep_awake) {
        Add-Type -Namespace Win -Name Pwr -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);' -ErrorAction SilentlyContinue
        [void][Win.Pwr]::SetThreadExecutionState([uint32]2147483649)     # ES_CONTINUOUS | ES_SYSTEM_REQUIRED: el PC no se suspende solo mientras el agente corre
    }
    Show 'Santuario Agente 24/7 iniciado. Cierra esta ventana (o crea agent\QUIT) para detenerlo.' 'Cyan'
    Log-Line 'inicio'; Write-Audit 'daemon' 'inicio' 'auto' ('pid ' + $PID)
    Remove-OldLogs; Remove-OrphanEphemeralEdge
    if (-not (Wait-Ollama)) { Show 'Ollama no responde (127.0.0.1:11434). Salgo para que el vigilante lo reinicie.' 'Red'; exit 2 }
    if (-not (Test-OllamaIsOurs)) { Show 'El puerto de Ollama lo ocupa OTRO programa (no es el de la USB). No sigo.' 'Red'; Log-Line 'puerto de ollama ocupado por otro programa'; exit 2 }
    $Installed = Get-Installed
    Check-Policy
    Refresh-Owner
    if (-not $script:Owner) { Show 'Telegram sin configurar/emparejar o canal remoto desactivado (Configurar-Telegram.bat). Solo tareas por consola.' 'Yellow' }

    $lastBeat = [datetime]::MinValue; $lastDay = (Get-Date).Date; $lastCheck = Get-Date; $ollamaFails = 0
    while ($true) {
        if (-not (Test-Path $script:TRoot)) { Show 'La USB no esta; espero...' 'Yellow'; Start-Sleep -Seconds 5; continue }
        if ((Get-Date) - $lastBeat -gt [TimeSpan]::FromSeconds([int]$DPol.heartbeat_sec)) {
            try { [IO.File]::WriteAllText((Join-Path $script:RunDir 'heartbeat.txt'), (Get-Date).ToString('s'), [Text.Encoding]::ASCII) } catch {}
            $lastBeat = Get-Date
            if ($DPol.keep_awake) { [void][Win.Pwr]::SetThreadExecutionState([uint32]2147483649) }
            if ((Get-Date).Date -ne $lastDay) { $lastDay = (Get-Date).Date; Remove-OldLogs }
        }
        if (((Get-Date) - $lastCheck).TotalSeconds -ge 60) {          # cada minuto: Ollama vivo, politica sin cambios, Edge inactivo cerrado
            $lastCheck = Get-Date
            try { Invoke-RestMethod "$Base/api/tags" -TimeoutSec 5 | Out-Null; $ollamaFails = 0 } catch { $ollamaFails++; Log-Line ('Ollama no responde (' + $ollamaFails + '/3)') }
            if ($ollamaFails -ge 3 -and -not $TestStubModel) { Show 'Ollama se cayo. Salgo para que el vigilante lo reinicie.' 'Red'; exit 2 }
            Check-Policy
            if ($script:Edge -and $script:EdgeLastUse -and (((Get-Date) - $script:EdgeLastUse).TotalMinutes -gt 10)) { Close-HandsEdge; Log-Line 'Edge cerrado por inactividad' }
        }
        if ($env:SANT_INTEGRADO -eq '1') {                              # modo integrado: el agente vive mientras la consola de Santuario siga abierta
            $cpf = Join-Path $script:RunDir 'console.pid'
            if (-not (Test-Path -LiteralPath $cpf) -and $script:ConsoleSeen) { Log-Line 'la consola de Santuario termino: el agente integrado termina'; break }
            if (Test-Path -LiteralPath $cpf) {
                $script:ConsoleSeen = $true
                $cp = 0; try { $cp = [int](([IO.File]::ReadAllText($cpf)).Trim()) } catch {}
                if ($cp -gt 0 -and -not (Get-Process -Id $cp -ErrorAction SilentlyContinue)) { Log-Line 'la consola de Santuario se cerro: el agente integrado termina'; break }
            }
        }
        if (Test-Path (Join-Path $script:AgentDir 'QUIT')) { Remove-Item (Join-Path $script:AgentDir 'QUIT') -Force; Log-Line 'salida pedida (QUIT)'; break }
        Refresh-Owner
        $paused = Test-StopFlag
        if (-not $paused) {
            $script:Origin = 'tarea'
            try { if ($script:PolicyOk) { [void](Run-DueTasks (Get-Date)) } } catch { Log-Line ('error en tareas: ' + $_.Exception.Message) }
        }
        if ($script:Owner) {
            if ($script:TgReady) { Process-Updates } else { Try-ConnectTelegram; Start-Sleep -Seconds ([int]$DPol.idle_poll_sec) }
        } else { Start-Sleep -Seconds ([int]$DPol.idle_poll_sec) }
        if ($Once) { break }
    }
    exit 0
} catch {
    Log-Line ('FALLO del demonio: ' + $_.Exception.Message)
    Show ('FALLO: ' + $_.Exception.Message) 'Red'
    $code = if (((Get-Date) - $script:T0).TotalSeconds -gt 120) { 3 } else { 2 }
    exit $code
} finally {
    if ($owned) {
        try { Close-HandsEdge } catch {}
        try { if ($DPol.keep_awake) { [void][Win.Pwr]::SetThreadExecutionState([uint32]2147483648) } } catch {}
        try { Remove-Item (Join-Path $script:RunDir 'daemon.pid') -Force -ErrorAction SilentlyContinue } catch {}
        try { $mutex.ReleaseMutex() } catch {}
        Log-Line 'fin'
    }
    try { if ($mutex) { $mutex.Dispose() } } catch {}
}
