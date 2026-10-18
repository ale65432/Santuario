# Santuario - VERIFICADOR del inicio automatico. Instalar-Inicio-Automatico.bat copia este archivo a %LOCALAPPDATA%\Santuario
# y el acceso directo de Inicio ejecuta ESA copia (en el PC), no la de la USB. ASCII a proposito.
# Arranca el agente SOLO si: la USB con el mismo numero de serie esta puesta (con la letra que tenga ahora) y los scripts no cambiaron.
param([switch]$Check)   # -Check: solo verifica e imprime el resultado; NO arranca el agente (para pruebas)
$ErrorActionPreference = 'Stop'
$cfgFile = Join-Path $PSScriptRoot 'autostart.json'
function Stop-With([string]$msg) { Write-Host ('Santuario: ' + $msg); if (-not $Check) { Start-Sleep 60 }; exit 1 }
if (-not (Test-Path $cfgFile)) { Stop-With 'falta autostart.json. Ejecuta Instalar-Inicio-Automatico.bat otra vez.' }
$cfg = [IO.File]::ReadAllText($cfgFile) | ConvertFrom-Json
$rest = ([string]$cfg.sant).Substring(2)
$sant = $null
foreach ($d in @(Get-CimInstance Win32_LogicalDisk)) {
    if ([string]$d.VolumeSerialNumber -eq [string]$cfg.serial) { $cand = $d.DeviceID + $rest; if (Test-Path (Join-Path $cand 'Santuario-Agente.bat')) { $sant = $cand; break } }
}
if (-not $sant) { Write-Host 'Santuario: la USB de Santuario no esta conectada (o no es la que autorizaste). No arranco el agente.'; if (-not $Check) { Start-Sleep 20 }; exit 1 }
$sb = New-Object Text.StringBuilder
foreach ($f in @($cfg.files)) {
    $p = Join-Path $sant $f
    if (-not (Test-Path $p)) { Stop-With ('falta ' + $f + '. No arranco.') }
    [void]$sb.Append((Get-FileHash $p -Algorithm SHA256).Hash)
}
$sha = [Security.Cryptography.SHA256]::Create()
$now = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($sb.ToString())))).Replace('-', '')
if ($now -ne [string]$cfg.fp) {
    Stop-With 'los scripts del agente CAMBIARON desde que autorizaste el inicio automatico. No lo arranco. Si los cambiaste tu, ejecuta Instalar-Inicio-Automatico.bat de nuevo para aprobarlos.'
}
if ($Check) { Write-Host 'VERIFICACION OK: el agente se arrancaria.'; return }
Start-Process -FilePath (Join-Path $sant 'Santuario-Agente.bat') -WorkingDirectory $sant -WindowStyle Minimized
