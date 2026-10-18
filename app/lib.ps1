# Santuario - biblioteca comun del router (la usan la consola, app\santuario.ps1, y el demonio, agent\daemon.ps1).
# Solo ASCII a proposito (PowerShell 5.1 lee mal los acentos sin BOM). Los textos con acentos viven en brain.json.
Add-Type -AssemblyName Microsoft.VisualBasic

$Root = Split-Path -Parent $PSScriptRoot
$Base = 'http://127.0.0.1:11434'
$Brain = [IO.File]::ReadAllText((Join-Path $Root 'brain.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
$Regions = [ordered]@{}
foreach ($r in $Brain.regions) { $Regions[$r.id] = $r }
$Default = ($Brain.regions | Where-Object { $_.default } | Select-Object -First 1).id

# Rechazos tipicos de un modelo con filtros -> se reintenta con la region libre
$RefusalRx = 'no puedo (ayudar|ayudarte|ayudarle|proporcionar|cumplir|asistir|responder|generar|crear|darte)|lo siento,? pero no|no estoy (en condiciones|autorizado|permitido)|no me es posible|como (asistente|modelo) (de ia|de inteligencia|de lenguaje),? no|i can.?t (help|assist|provide)|i.m sorry,? but'
$LibreFamily = 'libre', 'libre8', 'libre2', 'gemma', 'analyst', 'analyst_lite'

function Normalize([string]$s) {
    $d = $s.Normalize([Text.NormalizationForm]::FormD)
    $sb = New-Object Text.StringBuilder
    foreach ($c in $d.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne 'NonSpacingMark') { [void]$sb.Append($c) }
    }
    $sb.ToString().ToLowerInvariant()
}

$CI = New-Object Microsoft.VisualBasic.Devices.ComputerInfo
function Avail-GB { [math]::Round($CI.AvailablePhysicalMemory / 1GB, 1) }
function Total-GB { [math]::Round($CI.TotalPhysicalMemory / 1GB, 1) }

function Get-Installed {
    $n = @{}
    try { (Invoke-RestMethod "$Base/api/tags" -TimeoutSec 15).models | ForEach-Object { $n[($_.name -replace ':latest$', '')] = $true } } catch {}
    $n
}

function Wait-Ollama {
    for ($i = 0; $i -lt 60; $i++) {
        try { Invoke-RestMethod "$Base/api/tags" -TimeoutSec 2 | Out-Null; return $true } catch { Start-Sleep -Milliseconds 700 }
    }
    return $false
}

# Region final a usar: aplica mejora (upgrade_to) si hay RAM, y respaldo (fallback) si falta modelo o RAM.
function Resolve-Region([string]$id, [double]$extra, [int]$depth = 0) {
    $r = $Regions[$id]
    if (-not $r -or $depth -gt 6) { return $Regions[$Default] }
    $free = (Avail-GB) + $extra
    if ($r.upgrade_to -and $Installed[$Regions[$r.upgrade_to].model] -and $free -ge $Regions[$r.upgrade_to].min_free_ram_gb) {
        return $Regions[$r.upgrade_to]
    }
    if ($Installed[$r.model] -and $free -ge $r.min_free_ram_gb) { return $r }
    if ($r.fallback) { return (Resolve-Region $r.fallback $extra ($depth + 1)) }
    if ($Installed[$r.model]) { return $r }
    return $Regions[$Default]
}

function Pick-Region([string]$text) {
    $n = Normalize $text
    foreach ($r in ($Brain.regions | Where-Object { $_.auto -and $_.triggers } | Sort-Object { [int]$_.priority })) {
        if ($n -match $r.triggers) { return $r.id }
    }
    return $Default
}

function Unload([string]$model) {
    try {
        $b = @{ model = $model; keep_alive = 0 } | ConvertTo-Json
        Invoke-RestMethod "$Base/api/generate" -Method Post -Body $b -ContentType 'application/json' -TimeoutSec 30 | Out-Null
    } catch {}
}

# Pregunta al modelo SIN imprimir nada (para el demonio y las tareas). Devuelve el texto.
function Ask-Model([string]$model, $messages, [int]$numPredict = 400, [double]$temp = 0.4, [int]$timeoutSec = 1200) {
    $payload = @{ model = $model; messages = $messages; stream = $false; think = $false; options = @{ num_predict = $numPredict; temperature = $temp } } | ConvertTo-Json -Depth 6
    $x = Invoke-RestMethod "$Base/api/chat" -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($payload)) -ContentType 'application/json; charset=utf-8' -TimeoutSec $timeoutSec
    [string]$x.message.content
}

# Comprueba que quien escucha en el puerto de Ollama es el ollama.exe de ESTA USB (y no otro programa que se haya adelantado al puerto
# para leer todo lo que se escriba). Si no se puede averiguar (permisos), no bloquea.
function Test-OllamaIsOurs {
    try {
        $port = [int](($Base -split ':')[-1].TrimEnd('/'))
        $c = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction Stop)
        if ($c.Count -eq 0) { return $true }
        $mine = (Join-Path $Root 'app\ollama\ollama.exe')
        foreach ($x in $c) {
            $pr = Get-Process -Id $x.OwningProcess -ErrorAction Stop
            if (-not $pr.Path) { return $true }
            if (-not [string]::Equals($pr.Path, $mine, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        }
        $true
    } catch { $true }
}

# Modo de pruebas (SANTUARIO_TEST=1): cada pregunta al usuario se imprime tambien en la salida estandar con una marca, para que un probador\r\n# automatico (agent\tests\e2e-real.ps1) pueda leer lo mismo que ve una persona. Sin la variable no cambia nada.
function Read-Host {
    param([Parameter(Position = 0)][string]$Prompt, [switch]$AsSecureString)
    if ($env:SANTUARIO_TEST -eq '1') { Write-Host ('<<PROMPT>> ' + $Prompt) }
    Microsoft.PowerShell.Utility\Read-Host @PSBoundParameters
}
