# Santuario - comandos de la CONSOLA para tareas y agente (/tareas, /cancelar, /aprobar, /agente, /avisos, /remoto, y crear tareas en lenguaje natural).
# Se carga con dot-source desde app\santuario.ps1 despues de hands.ps1, tasks.ps1 y telegram.ps1. Solo ASCII a proposito.
# Aqui el dueno esta presente: sus ordenes son "consola". Los resumenes que ve los genera el CODIGO, no el modelo.

function Get-DaemonState {
    $pidFile = Join-Path $script:TaskDir 'daemon.pid'
    $alive = $false; $pid2 = 0
    if (Test-Path $pidFile) {
        try { $pid2 = [int](([IO.File]::ReadAllText($pidFile)).Trim()); $alive = [bool](Get-Process -Id $pid2 -ErrorAction SilentlyContinue) } catch {}
    }
    $beat = $null
    $hb = Join-Path $script:TaskDir 'heartbeat.txt'
    if ($alive -and (Test-Path $hb)) { try { $beat = ((Get-Date) - [datetime]::Parse(([IO.File]::ReadAllText($hb)).Trim())).TotalSeconds } catch {} }
    @{ alive = $alive; pid = $pid2; beat_age = $beat }
}
function Show-AgentStatus {
    $s = Get-DaemonState
    Write-Host ''
    if ($s.alive) { Write-Host ('  Agente 24/7: CORRIENDO (pid {0}{1})' -f $s.pid, $(if ($null -ne $s.beat_age) { ', latido hace ' + [int]$s.beat_age + ' s' } else { '' })) -ForegroundColor Green }
    else { Write-Host '  Agente 24/7: DETENIDO. Las tareas programadas solo se ejecutan con el agente. Abre Santuario-Agente.bat.' -ForegroundColor Yellow }
    $o = Get-TgOwner
    Write-Host ('  Telegram: token {0}; dueno {1}' -f $(if (Test-TgToken) { 'guardado' } else { 'NO configurado' }), $(if ($o) { 'emparejado' } else { 'sin emparejar' })) -ForegroundColor Gray
    $tools = 'apagadas'
    $tu = Get-RemoteToolsUntil
    if ($tu -and $tu -gt (Get-Date)) { $tools = 'ENCENDIDAS hasta ' + $tu.ToString('dd/MM HH:mm') }
    $pst = Test-PolicyApproved
    if ($pst -eq 'cambio') { Write-Host '  POLITICA CAMBIADA: policy.json ya no coincide con lo que aprobaste. El canal remoto esta DESACTIVADO. Revisa el archivo y escribe /agente aprobar.' -ForegroundColor Red }
    Write-Host ('  Herramientas remotas (buscar en Google desde Telegram): {0}' -f $tools) -ForegroundColor Gray
    $act = @(Load-Tasks | Where-Object { $_.estado -eq 'activa' }).Count
    $pen = @(Load-Tasks | Where-Object { $_.estado -eq 'pendiente' }).Count
    Write-Host ('  Tareas activas: {0}   pendientes de aprobar: {1}   (usa /tareas)' -f $act, $pen) -ForegroundColor Gray
    Write-Host ''
}
function Show-Inbox([bool]$quiet = $false) {
    $f = Join-Path $script:TaskDir 'inbox.txt'
    if (-not (Test-Path $f)) { if (-not $quiet) { Write-Host '  No hay avisos nuevos.' -ForegroundColor DarkGray }; return }
    $txt = [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8).Trim()
    if (-not $txt) { return }
    if ($quiet) {
        $n = ([regex]::Matches($txt, '(?m)^---$')).Count
        Write-Host ('  Tienes {0} aviso(s) del agente sin leer: escribe /avisos' -f $n) -ForegroundColor Yellow
        return
    }
    Write-Host ''; Write-Host '  AVISOS DEL AGENTE' -ForegroundColor Cyan
    Write-Host $txt
    Write-Host ''
    Remove-Item $f -Force -ErrorAction SilentlyContinue
}

# Crear una tarea en lenguaje natural: el codigo muestra QUE se guardara y pide confirmacion.
function Handle-ConsoleTask([string]$q) {
    $p = Parse-TaskRequest $q
    if (-not $p.ok) {
        Write-Host ('  No pude programar eso: ' + $p.error + '.') -ForegroundColor DarkYellow
        Write-Host '  Ejemplos: "recuerdame manana a las 9 llamar al banco" | "cada dia a las 8 busca noticias de Monterrey" | "en 20 minutos recuerdame sacar la pasta"' -ForegroundColor DarkGray
        return
    }
    Write-Host ''
    Write-Host '  TAREA A PROGRAMAR' -ForegroundColor Cyan
    Write-Host ('    Tipo   : ' + $p.tipo)
    Write-Host ('    Texto  : ' + $p.texto)
    Write-Host ('    Cuando : ' + (Format-When $p.cuando) + $(if ($p.cuando.modo -ne 'una_vez') { '  (proxima: ' + ([datetime]::Parse($p.cuando.proximo)).ToString('dd/MM HH:mm') + ')' } else { '' }))
    Write-Host ('    Aviso  : por ' + $p.canal)
    if ($p.canal -eq 'telegram' -and -not (Get-TgOwner)) { Write-Host '    (Telegram aun no esta emparejado: el aviso llegara al buzon de la consola. Ejecuta Configurar-Telegram.bat)' -ForegroundColor DarkYellow }
    if ($p.tipo -in 'busqueda', 'pregunta') { Write-Host '    (la busqueda/pregunta se ejecuta sola mas adelante, con el modelo local y Edge)' -ForegroundColor DarkGray }
    $a = Read-Host '  Guardo esta tarea? (s/n)'
    if (-not ($a -and $a.Trim().ToLowerInvariant() -in 's', 'si', 'y', 'yes')) { Write-Host '  No se guardo.' -ForegroundColor DarkGray; return }
    $c = Add-Task $p 'consola' $p.canal
    if (-not $c.ok) { Write-Host ('  No se pudo guardar: ' + $c.error) -ForegroundColor Red; return }
    Write-Audit 'tarea' $c.task.id 'confirmada' ('creada ' + $c.task.tipo) 'consola'
    Write-Host ('  Guardada: ' + $c.task.id + '  (expira ' + ([datetime]::Parse($c.task.expira)).ToString('dd/MM') + '). /tareas para verlas, /cancelar ' + $c.task.id + ' para quitarla.') -ForegroundColor Green
    if (-not (Get-DaemonState).alive) { Write-Host '  OJO: el agente esta detenido; la tarea se ejecutara cuando abras Santuario-Agente.bat.' -ForegroundColor Yellow }
}

# Devuelve $true si el comando era de tareas/agente (ya atendido).
function Handle-AgentCommand([string]$t, [string]$q) {
    if ($t -eq '/tareas') {
        $l = @(Load-Tasks | Sort-Object { $_.id })
        if ($l.Count -eq 0) { Write-Host '  No hay tareas.' -ForegroundColor DarkGray; return $true }
        Write-Host ''
        foreach ($x in $l) {
            $col = switch ($x.estado) { 'activa' { 'Green' } 'pendiente' { 'Yellow' } 'bloqueada' { 'Red' } default { 'DarkGray' } }
            Write-Host ('  ' + (Format-Task $x)) -ForegroundColor $col
        }
        Write-Host ''
        return $true
    }
    if ($t -match '^/cancelar\s+(t\d+)$') {
        if (Set-TaskState $Matches[1] 'cancelada') { Write-Audit 'tarea' $Matches[1] 'confirmada' 'cancelada' 'consola'; Write-Host ('  Tarea ' + $Matches[1] + ' cancelada.') -ForegroundColor Green }
        else { Write-Host '  No encontre esa tarea vigente.' -ForegroundColor DarkYellow }
        return $true
    }
    if ($t -match '^/aprobar\s+(t\d+)$') {
        $id = $Matches[1]
        $task = Load-Tasks | Where-Object { $_.id -eq $id -and $_.estado -eq 'pendiente' } | Select-Object -First 1
        if (-not $task) { Write-Host '  No hay una tarea pendiente con ese id.' -ForegroundColor DarkYellow; return $true }
        Write-Host ('  Tarea pendiente: ' + (Format-Task $task)) -ForegroundColor Yellow
        if (-not (Test-TaskSig $task)) { Write-Host '  Su firma no es valida: no se puede aprobar. Cancelala.' -ForegroundColor Red; return $true }
        if (Confirm-Action ('Aprobar la tarea ' + $id + ' (' + $task.tipo + ': ' + $task.texto + ')')) {
            if (Approve-Task $id) { Write-Audit 'tarea' $id 'confirmada' 'aprobada' 'consola'; Write-Host '  Aprobada.' -ForegroundColor Green } else { Write-Host '  No se pudo aprobar (firma invalida o ya no esta pendiente).' -ForegroundColor Red }
        } else { Write-Host '  No aprobada.' -ForegroundColor DarkGray }
        return $true
    }
    if ($t -eq '/agente aprobar') {
        Write-Host ('  policy.json actual (huella ' + (Get-PolicyHash).Substring(0, 12) + '...). Revisalo antes de aprobar: define sitios, programas, tipos de tareas y limites.') -ForegroundColor Yellow
        if (Confirm-Action 'Aprobar el policy.json actual como valido (el canal remoto se reactiva)') { Approve-Policy; Write-Audit 'politica' 'aprobar' 'confirmada' 'aprobada' 'consola'; Write-Host '  Politica aprobada.' -ForegroundColor Green }
        else { Write-Host '  No aprobada.' -ForegroundColor DarkGray }
        return $true
    }
    if ($t -eq '/agente') { Show-AgentStatus; return $true }
    if ($t -eq '/avisos') { Show-Inbox; return $true }
    if ($t -match '^/remoto(?:\s+(.*))?$') {
        $arg = ([string]$Matches[1]).Trim()
        if ($arg -match '^herramientas\s+on(?:\s+(\d+))?$') {
            $h = if ($Matches[1]) { [math]::Min([int]$Matches[1], 24) } else { [int]$script:TgCfgRoot.tools_ttl_hours }
            Set-RemoteTools $h
            Write-Audit 'remoto' 'herramientas on' 'confirmada' ('por ' + $h + ' h') 'consola'
            Write-Host ('  Herramientas remotas ENCENDIDAS por {0} h (buscar en Google desde Telegram, con perfil de Edge temporal). Caducan solas.' -f $h) -ForegroundColor Yellow
        } elseif ($arg -eq 'herramientas off') {
            Remove-Item (Get-ToolsFile) -Force -ErrorAction SilentlyContinue
            Write-Audit 'remoto' 'herramientas off' 'confirmada' 'apagadas' 'consola'
            Write-Host '  Herramientas remotas APAGADAS.' -ForegroundColor Green
        } elseif ($arg -eq 'desvincular') {
            if (Confirm-Action 'Desvincular tu cuenta de Telegram (el bot dejara de obedecerte hasta emparejar de nuevo)') {
                Remove-Item (Get-TgOwnerFile) -Force -ErrorAction SilentlyContinue
                Write-Audit 'remoto' 'desvincular' 'confirmada' 'dueno borrado' 'consola'
                Write-Host '  Desvinculado (el agente deja de obedecer a esa cuenta en unos segundos, sin reiniciar). Para volver a emparejar: cierra el agente y ejecuta Configurar-Telegram.bat' -ForegroundColor Green
            }
        } else {
            Show-AgentStatus
            Write-Host '  Comandos: /remoto herramientas on [horas] | /remoto herramientas off | /remoto desvincular' -ForegroundColor DarkGray
        }
        return $true
    }
    $false
}
$script:TgCfgRoot = ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'policy.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json).remote
