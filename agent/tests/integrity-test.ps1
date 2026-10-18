# Pruebas del verificador de integridad (app\integrity.ps1) con una raiz y un almacen de prueba. ASCII.
$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ver = Join-Path $Root 'app\integrity.ps1'
$env:SANTUARIO_TEST = '1'
$pass = 0; $fail = 0
function Check([string]$name, $got, $want) { if ("$got" -eq "$want") { $script:pass++ } else { $script:fail++; "FALLA: $name -> obtuve '$got', esperaba '$want'" } }
$T = Join-Path $env:TEMP ('santuario-int-test-' + $PID)
$R = Join-Path $T 'usb'; $S = Join-Path $T 'store'
New-Item -ItemType Directory -Force (Join-Path $R 'app'), (Join-Path $R 'agent'), (Join-Path $R 'data'), $S | Out-Null
Set-Content (Join-Path $R 'app\a.ps1') 'write-host a'; Set-Content (Join-Path $R 'agent\policy.json') '{"x":1}'; Set-Content (Join-Path $R 'data\secreto.json') '{"t":1}'
Copy-Item $ver (Join-Path $R 'app\integrity.ps1')
function Run([string[]]$extra) { & powershell -NoProfile -ExecutionPolicy Bypass -File $ver -Root $R -StoreDir $S -NoPrompt @extra *> $null; $LASTEXITCODE }

Check 'sin base de confianza: no arranca' (Run) 2
Check 'aprobar la primera huella' (Run @('-TestAccept')) 0
Check 'almacen creado' (Test-Path (Join-Path $S 'integrity.json')) $true
Check 'copia del verificador en el PC' (Test-Path (Join-Path $S 'integrity-run.ps1')) $true
Check 'sin cambios: ok' (Run) 0
Set-Content (Join-Path $R 'data\secreto.json') '{"t":2}'
Check 'cambiar data\ no cuenta' (Run) 0
Add-Content (Join-Path $R 'app\a.ps1') 'evil'
Check 'script modificado: bloquea' (Run) 1
Check 'script modificado: sigue bloqueado' (Run) 1
Check 'aprobar el cambio' (Run @('-TestAccept')) 0
Check 'tras aprobar: ok' (Run) 0
Set-Content (Join-Path $R 'app\nuevo.bat') 'echo plantado'
Check 'archivo nuevo: bloquea' (Run) 1
Remove-Item (Join-Path $R 'app\nuevo.bat')
Check 'archivo nuevo retirado: ok' (Run) 0
Remove-Item (Join-Path $R 'agent\policy.json')
Check 'archivo eliminado: bloquea' (Run) 1
Set-Content (Join-Path $R 'agent\policy.json') '{"x":1}'
Check 'archivo restaurado: ok' (Run) 0
Set-Content (Join-Path $R 'agent\policy.json') '{"x":2}'
Check 'politica modificada: bloquea' (Run) 1
# sin la variable de prueba, -StoreDir y -TestAccept se ignoran (no se puede aprobar sin preguntar)
$env:SANTUARIO_TEST = ''
$out = & powershell -NoProfile -ExecutionPolicy Bypass -File $ver -Root $R -StoreDir $S -NoPrompt -TestAccept *> $null;
if (-not (Test-Path (Join-Path $env:SystemDrive ('Users\' + $env:USERNAME + '\AppData\Local\Santuario\integrity.json')))) { Check 'produccion: -TestAccept no aprueba (sale distinto de 0)' ($LASTEXITCODE -ne 0) $true }
# los .bat usan rutas absolutas y verifican
foreach ($f in 'Santuario.bat', 'Santuario-Agente.bat', 'Configurar-Telegram.bat', 'Instalar-Cerebro.bat') {
    $txt = [IO.File]::ReadAllText((Join-Path $Root $f))
    Check "$f verifica integridad" ($txt -match 'verify\.bat') $true
    Check "$f sin 'powershell' ni 'taskkill' ni 'ping' sueltos" ($txt -match '(?m)^\s*(powershell|taskkill|ping|chcp)\s') $false
}
Check 'env.bat define rutas absolutas' ([IO.File]::ReadAllText((Join-Path $Root 'app\env.bat')) -match 'NoDefaultCurrentDirectoryInExePath=1') $true
Remove-Item -LiteralPath $T -Recurse -Force -ErrorAction SilentlyContinue
"RESULTADO INTEGRIDAD: $pass correctas, $fail con fallo"
