# Santuario - verificacion de integridad ANTES de ejecutar nada de la USB. PowerShell 5.1, ASCII.
# Compara el hash de todos los scripts/configuracion de la USB con una copia guardada en ESTE PC (%LOCALAPPDATA% real, fuera de la USB)
# y comprueba la firma Authenticode de los binarios de Ollama. Si algo cambio, pide al dueno que lo apruebe escribiendo SI.
# Uso: integrity.ps1 -Root D:\Santuario\ [-NoPrompt]    (codigo de salida 0 = todo bien, 1 = cambios sin aprobar, 2 = sin base de confianza)
param([string]$Root, [switch]$NoPrompt, [string]$StoreDir = '', [switch]$TestAccept)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')
$real = Join-Path $env:SystemDrive ('Users\' + $env:USERNAME + '\AppData\Local\Santuario')          # carpeta REAL (env.bat redirige LOCALAPPDATA a la USB)
if ($StoreDir -and $env:SANTUARIO_TEST -eq '1') { $real = $StoreDir }                                  # solo para las pruebas
$store = Join-Path $real 'integrity.json'
$runCopy = Join-Path $real 'integrity-run.ps1'
$interactive = (-not $NoPrompt) -and [Environment]::UserInteractive -and (-not [Console]::IsInputRedirected)

function Get-Manifest {
    $m = [ordered]@{}
    $skipDir = '^(data|models|logs|ollama|\.git)$'
    $stack = New-Object System.Collections.Stack; $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $d = [string]$stack.Pop()
        foreach ($e in (New-Object IO.DirectoryInfo($d)).EnumerateFileSystemInfos()) {
            if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($e.Attributes -band [IO.FileAttributes]::Directory) { if ($e.Name -notmatch $skipDir) { $stack.Push($e.FullName) }; continue }
            if ($e.Extension -notin '.ps1', '.bat', '.cmd', '.cs', '.json', '.psm1', '.vbs', '.js', '.exe', '.dll') { continue }
            if ($e.FullName -like (Join-Path $Root 'app\ollama*')) { continue }
            if ($e.FullName -like (Join-Path $Root 'agent\tests\*')) { continue }
            $rel = $e.FullName.Substring($Root.Length).TrimStart('\')
            $m[$rel] = (Get-FileHash -LiteralPath $e.FullName -Algorithm SHA256).Hash
        }
    }
    $m
}
# Huella barata del conjunto de binarios (nombre, tamano, fecha): la comprobacion de firmas es lenta (~1 s por archivo), solo se repite si la huella cambia.
function Get-BinFingerprint {
    $dir = Join-Path $Root 'app\ollama'
    if (-not (Test-Path -LiteralPath $dir)) { return '' }
    $lines = Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.exe', '.dll' } | Sort-Object FullName | ForEach-Object { $_.FullName.Substring($Root.Length) + '|' + $_.Length + '|' + $_.LastWriteTimeUtc.Ticks }
    $b = [Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))
    (([Security.Cryptography.SHA256]::Create()).ComputeHash($b) | ForEach-Object { $_.ToString('x2') }) -join ''
}
function Test-OllamaBinaries {
    $bad = New-Object System.Collections.ArrayList
    $dir = Join-Path $Root 'app\ollama'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    foreach ($f in (Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.exe', '.dll' })) {
        $s = Get-AuthenticodeSignature -LiteralPath $f.FullName
        if ($s.Status -ne 'Valid' -or $s.SignerCertificate.Subject -notmatch 'CN=(Ollama Inc\.|Microsoft (Windows|Corporation)|NVIDIA Corporation)') { [void]$bad.Add($f.FullName.Substring($Root.Length).TrimStart('\') + ' (' + $s.Status + ')') }
    }
    @($bad.ToArray())
}

$cur = Get-Manifest
$sw = [Diagnostics.Stopwatch]::StartNew()
$binFp = Get-BinFingerprint
$savedFp = ''; if (Test-Path -LiteralPath $store) { try { $savedFp = [string](([IO.File]::ReadAllText($store) | ConvertFrom-Json).bin_fp) } catch {} }
$badBin = @()
if ($binFp -ne $savedFp) {
    if ($interactive) { Write-Host '  Comprobando las firmas de Ollama (solo cuando cambian; puede tardar un minuto)...' -ForegroundColor DarkGray }
    $badBin = @(Test-OllamaBinaries)
}
if ($badBin.Count -gt 0) {
    Write-Host ''; Write-Host '  ALERTA: binarios de Ollama sin firma valida (Ollama Inc., Microsoft o NVIDIA) (posible archivo plantado o modificado):' -ForegroundColor Red
    $badBin | Select-Object -First 10 | ForEach-Object { Write-Host ('   - ' + $_) -ForegroundColor Red }
    Write-Host '  Santuario no arranca. Restaura la carpeta app\ollama desde una copia limpia.' -ForegroundColor Red
    exit 1
}

function Save-Store {
    New-Item -ItemType Directory -Force $real | Out-Null
    $o = @{ bin_fp = $binFp; saved = (Get-Date).ToString('s'); files = $cur }
    [IO.File]::WriteAllText($store, ($o | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath (Join-Path $Root 'app\integrity.ps1')) { Copy-Item -LiteralPath (Join-Path $Root 'app\integrity.ps1') -Destination $runCopy -Force }      # el verificador que se ejecuta vive en el PC, no en la USB
}
function Ask([string]$msg) {
    if ($TestAccept -and $env:SANTUARIO_TEST -eq '1') { return $true }
    if (-not $interactive) { return $false }
    $a = Read-Host ('  ' + $msg + ' Escribe SI para aprobar (Enter = no)')
    return ($a -and $a.Trim().ToUpperInvariant() -eq 'SI')
}

if (-not (Test-Path -LiteralPath $store)) {
    Write-Host ''
    Write-Host ('  PRIMERA VEZ en este PC: Santuario va a registrar la huella de ' + $cur.Count + ' archivos (scripts y configuracion) como de confianza.') -ForegroundColor Yellow
    Write-Host '  Solo apruebalo si esta USB es tuya y no estuvo en un equipo que no controlas.' -ForegroundColor Yellow
    if (Ask 'Registrar esta huella?') { Save-Store; Write-Host '  Registrado.' -ForegroundColor Green; exit 0 }
    if ($NoPrompt -or -not $interactive) { Write-Host '  Sin base de confianza: abre Santuario.bat una vez para aprobarla.' -ForegroundColor Red }
    exit 2
}
$saved = [IO.File]::ReadAllText($store) | ConvertFrom-Json
$old = @{}; foreach ($p in $saved.files.PSObject.Properties) { $old[$p.Name] = [string]$p.Value }
$changed = New-Object System.Collections.ArrayList
foreach ($k in $cur.Keys) { if (-not $old.ContainsKey($k)) { [void]$changed.Add('NUEVO     ' + $k) } elseif ($old[$k] -ne $cur[$k]) { [void]$changed.Add('MODIFICADO ' + $k) } }
foreach ($k in $old.Keys) { if (-not $cur.Contains($k)) { [void]$changed.Add('ELIMINADO  ' + $k) } }
if ($changed.Count -eq 0) { exit 0 }
Write-Host ''
Write-Host ('  AVISO DE INTEGRIDAD: ' + $changed.Count + ' archivo(s) de Santuario cambiaron desde la ultima vez que los aprobaste:') -ForegroundColor Yellow
$changed | Select-Object -First 15 | ForEach-Object { Write-Host ('   ' + $_) -ForegroundColor Yellow }
if ($changed.Count -gt 15) { Write-Host ('   ... y ' + ($changed.Count - 15) + ' mas') -ForegroundColor Yellow }
Write-Host '  Si los cambiaste tu (o una actualizacion que pediste), apruebalos. Si no, NO: pudo ser otro equipo.' -ForegroundColor Yellow
if (Ask 'Aprobar estos cambios?') { Save-Store; Write-Host '  Aprobado.' -ForegroundColor Green; exit 0 }
Write-Host '  Santuario no arranca con archivos sin aprobar.' -ForegroundColor Red
exit 1
