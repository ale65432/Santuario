# Santuario - instala el INICIO AUTOMATICO (opcional, a peticion del dueno). Solo ASCII a proposito.
# Cambios en el PC anfitrion (nada en el registro, sin administrador, sin servicios):
#   1) un acceso directo en la carpeta Inicio del usuario;
#   2) en %LOCALAPPDATA%\Santuario: autostart.json (ruta, NUMERO DE SERIE de la USB, huella de los scripts) y una COPIA del verificador.
# El acceso directo ejecuta el verificador que vive en el PC (no el de la USB): quien escriba en la USB no puede quitarle la comprobacion.
# -DryRun solo muestra que haria, sin escribir nada.
param([switch]$DryRun)
$ErrorActionPreference = 'Stop'
$sant = Split-Path -Parent $PSScriptRoot
$startup = [Environment]::GetFolderPath('Startup')
$hostDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Santuario'
$files = 'agent\daemon.ps1', 'agent\hands.ps1', 'agent\tasks.ps1', 'agent\telegram.ps1', 'agent\policy.json', 'app\lib.ps1', 'app\env.bat', 'app\serve.bat', 'Santuario-Agente.bat', 'brain.json', 'app\ollama\ollama.exe'
$sb = New-Object Text.StringBuilder
foreach ($f in $files) { [void]$sb.Append((Get-FileHash (Join-Path $sant $f) -Algorithm SHA256).Hash) }
$sha = [Security.Cryptography.SHA256]::Create()
$fp = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($sb.ToString())))).Replace('-', '')
$drive = $sant.Substring(0, 2)
$serial = [string](Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='" + $drive + "'")).VolumeSerialNumber
if (-not $serial) { throw 'No pude leer el numero de serie de la unidad de la USB.' }
$lnkPath = Join-Path $startup 'Santuario-Agente.lnk'
$verifier = Join-Path $hostDir 'autostart-run.ps1'
$args2 = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File "' + $verifier + '"'
Write-Host ('  Acceso directo : ' + $lnkPath)
Write-Host ('  Ejecuta        : powershell.exe ' + $args2)
Write-Host ('  Verificador    : copia en ' + $verifier + ' (en tu PC)')
Write-Host ('  Configuracion  : ' + (Join-Path $hostDir 'autostart.json') + '  (USB serie ' + $serial + ', huella ' + $fp.Substring(0, 12) + '...)')
Write-Host ('  La huella cubre: ' + ($files -join ', '))
if ($DryRun) { Write-Host '  [ensayo] No se escribio nada.'; return }
New-Item -ItemType Directory -Force $hostDir | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'autostart-run.ps1') $verifier -Force
$cfg = [ordered]@{ sant = $sant; serial = $serial; fp = $fp; files = $files; instalado = (Get-Date).ToString('s') }
[IO.File]::WriteAllText((Join-Path $hostDir 'autostart.json'), ($cfg | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
$ws = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut($lnkPath)
$lnk.TargetPath = 'powershell.exe'; $lnk.Arguments = $args2; $lnk.WorkingDirectory = $hostDir; $lnk.WindowStyle = 7
$lnk.Description = 'Santuario agente 24/7 (opcional)'
$lnk.Save()
Write-Host '  Instalado.' -ForegroundColor Green
