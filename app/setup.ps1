# Santuario - instala/reconstruye el cerebro: crea un modelo "santuario-*" por cada region de brain.json
# Uso: Instalar-Cerebro.bat  (con -Pull descarga lo que falte; sin internet solo reconstruye)
# Solo ASCII a proposito (PowerShell 5.1 lee mal los acentos sin BOM). Los textos con acentos viven en brain.json.
param([switch]$Pull)
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Root   = Split-Path -Parent $PSScriptRoot
$Ollama = Join-Path $Root 'app\ollama\ollama.exe'
$Base   = 'http://127.0.0.1:11434'
$Utf8   = New-Object System.Text.UTF8Encoding($false)
$Brain  = [IO.File]::ReadAllText((Join-Path $Root 'brain.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json

function Run-Ollama([string[]]$a) {
    $o = [IO.Path]::GetTempFileName(); $e = [IO.Path]::GetTempFileName()
    $p = Start-Process -FilePath $Ollama -ArgumentList $a -Wait -PassThru -NoNewWindow -RedirectStandardOutput $o -RedirectStandardError $e
    $tail = (Get-Content $e -ErrorAction SilentlyContinue | Select-Object -Last 1)
    Remove-Item $o, $e -Force -ErrorAction SilentlyContinue
    [pscustomobject]@{ Code = $p.ExitCode; Tail = $tail }
}
function Installed-Names {
    $n = @{}
    try { (Invoke-RestMethod "$Base/api/tags" -TimeoutSec 15).models | ForEach-Object { $n[$_.name] = $true } } catch {}
    $n
}
function Has($names, [string]$name) {
    if ($name -notmatch ':') { $name = "${name}:latest" }
    $names.ContainsKey($name)
}

# El servidor tiene que estar activo
try { Invoke-RestMethod "$Base/api/tags" -TimeoutSec 5 | Out-Null }
catch { Write-Host 'Ollama no esta activo. Usa Instalar-Cerebro.bat.' -ForegroundColor Red; exit 1 }

$brainText = ($Brain.regions | ForEach-Object { $_.label.ToLowerInvariant() }) -join ', '   # solo nombres: los modelos pequenos se confunden con listas largas
$ok = 0; $missing = @()

foreach ($r in $Brain.regions) {
    # el origen del modelo solo puede ser hf.co/<usuario>/<repo>:<etiqueta> o un nombre del registro de Ollama; los textos no pueden cerrar el bloque SYSTEM
    if ([string]$r.source -notmatch '^(hf\.co/[\w.-]+/[\w.-]+|[\w.-]+(/[\w.-]+)?):[\w.-]+$') { Write-Host ("[{0}] origen de modelo no permitido en brain.json: {1}" -f $r.id, $r.source) -ForegroundColor Red; $missing += $r.id; continue }
    if (([string]$Brain.identity + [string]$r.role + [string]$r.label) -match '"""') { Write-Host ("[{0}] texto con comillas triples en brain.json: se rechaza" -f $r.id) -ForegroundColor Red; $missing += $r.id; continue }
    $names = Installed-Names
    Write-Host ("[{0}] {1}" -f $r.id, $r.base_name) -NoNewline
    if (-not (Has $names $r.alias)) {
        if (-not (Has $names $r.source)) {
            if ($Pull) {
                Write-Host ' - descargando...' -NoNewline
                $res = Run-Ollama @('pull', $r.source)
                if ($res.Code -ne 0) { Write-Host (' FALLO: ' + $res.Tail) -ForegroundColor Red; $missing += $r.id; continue }
            } else { Write-Host ' - FALTA (usa -Pull para descargar)' -ForegroundColor Yellow; $missing += $r.id; continue }
        }
        $res = Run-Ollama @('cp', $r.source, $r.alias)
        if ($res.Code -ne 0) { Write-Host (' FALLO cp: ' + $res.Tail) -ForegroundColor Red; $missing += $r.id; continue }
    }
    $temp = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', $r.temperature)
    $system = $Brain.identity.Replace('{BRAIN}', $brainText).Replace('{REGION}', $r.label) + "`n" + $r.role
    $mf = "# Generado por setup.ps1 desde brain.json (region: $($r.id)). No editar a mano.`n" +
          "FROM $($r.alias)`n`nPARAMETER num_ctx 4096`nPARAMETER temperature $temp`nPARAMETER top_p 0.9`nPARAMETER repeat_penalty 1.1`n`n" +
          "SYSTEM `"`"`"`n$system`n`"`"`"`n"
    $mfPath = Join-Path $Root ("modelfiles\{0}.Modelfile" -f $r.model)
    [IO.File]::WriteAllText($mfPath, $mf, $Utf8)
    $res = Run-Ollama @('create', $r.model, '-f', $mfPath)
    if ($res.Code -eq 0) { Write-Host ' -> OK' -ForegroundColor Green; $ok++ }
    else { Write-Host (' FALLO create: ' + $res.Tail) -ForegroundColor Red; $missing += $r.id }
}
Write-Host ''
Write-Host ("Regiones listas: {0} de {1}" -f $ok, $Brain.regions.Count)
if ($missing.Count) { Write-Host ('Pendientes: ' + ($missing -join ', ')) -ForegroundColor Yellow }
