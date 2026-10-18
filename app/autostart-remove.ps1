# Santuario - quita el inicio automatico (deshace autostart-install.ps1). ASCII a proposito.
# -DryRun no borra nada. -IncluirSecretos borra tambien el token de Telegram cifrado y las claves de firma de tareas (en %LOCALAPPDATA%\Santuario).
param([switch]$DryRun, [switch]$IncluirSecretos)
$hostDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Santuario'
$targets = @((Join-Path ([Environment]::GetFolderPath('Startup')) 'Santuario-Agente.lnk'), (Join-Path $hostDir 'autostart.json'), (Join-Path $hostDir 'autostart-run.ps1'), (Join-Path $hostDir 'autostart.sha256'))
if ($IncluirSecretos) { $targets += @((Join-Path $hostDir 'telegram.dpapi'), (Join-Path $hostDir 'task.key'), (Join-Path $hostDir 'policy.sha256')) }
foreach ($p in $targets) {
    if (Test-Path $p) {
        if ($DryRun) { Write-Host ('  [ensayo] se borraria: ' + $p) } else { Remove-Item $p -Force; Write-Host ('  Eliminado: ' + $p) }
    } else { Write-Host ('  No existe: ' + $p) }
}
if (-not $IncluirSecretos) {
    $left = @('telegram.dpapi', 'task.key', 'policy.sha256') | Where-Object { Test-Path (Join-Path $hostDir $_) }
    if ($left) { Write-Host ('  NOTA: siguen en tu PC (' + $hostDir + '): ' + ($left -join ', ') + '. Son tu token cifrado y las claves de las tareas; no se borran solos. Para borrarlos: Quitar-Inicio-Automatico.bat TODO') -ForegroundColor Yellow }
}
