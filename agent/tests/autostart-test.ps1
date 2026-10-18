# Prueba del VERIFICADOR del inicio automatico, sin instalar nada y sin arrancar el agente. Usa una carpeta temporal. ASCII a proposito.
$sant = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$app = Join-Path $sant 'app'
$tmp = Join-Path $env:TEMP ('santuario-autostart-test-' + $PID)
New-Item -ItemType Directory -Force $tmp | Out-Null
Copy-Item (Join-Path $app 'autostart-run.ps1') (Join-Path $tmp 'autostart-run.ps1')
$files = 'agent\daemon.ps1', 'agent\hands.ps1', 'agent\tasks.ps1', 'agent\telegram.ps1', 'agent\policy.json', 'app\lib.ps1', 'app\env.bat', 'app\serve.bat', 'Santuario-Agente.bat', 'brain.json', 'app\ollama\ollama.exe'
$sb = New-Object Text.StringBuilder
foreach ($f in $files) { [void]$sb.Append((Get-FileHash (Join-Path $sant $f) -Algorithm SHA256).Hash) }
$sha = [Security.Cryptography.SHA256]::Create()
$fp = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($sb.ToString())))).Replace('-', '')
$serial = [string](Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='" + $sant.Substring(0, 2) + "'")).VolumeSerialNumber
$pass = 0; $fail = 0
function Check([string]$name, $got, $want) { if ("$got" -eq "$want") { $script:pass++; "  ok  $name" } else { $script:fail++; "  FALLA $name -> '$got' (esperaba '$want')" } }
function Run-Verifier($cfg) {
    [IO.File]::WriteAllText((Join-Path $tmp 'autostart.json'), ($cfg | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tmp 'autostart-run.ps1') -Check 2>&1 | Out-String
    $out
}
$good = [ordered]@{ sant = $sant; serial = $serial; fp = $fp; files = $files }
Check 'todo correcto: se arrancaria' ((Run-Verifier $good) -match 'VERIFICACION OK') $true
$bad = [ordered]@{ sant = $sant; serial = $serial; fp = ('0' * 64); files = $files }
Check 'scripts alterados (huella distinta): NO arranca' ((Run-Verifier $bad) -match 'CAMBIARON') $true
$other = [ordered]@{ sant = $sant; serial = '00000000'; fp = $fp; files = $files }
Check 'otra USB con la misma letra (serie distinta): NO arranca' ((Run-Verifier $other) -match 'no esta conectada') $true
$missing = [ordered]@{ sant = $sant; serial = $serial; fp = $fp; files = ($files + 'agent\no-existe.ps1') }
Check 'falta un archivo vigilado: NO arranca' ((Run-Verifier $missing) -match 'falta') $true
Remove-Item (Join-Path $tmp 'autostart.json') -Force
Check 'sin configuracion: NO arranca' (((& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tmp 'autostart-run.ps1') -Check 2>&1) | Out-String) -match 'falta autostart.json') $true
cmd /c rmdir /s /q ('"' + $tmp + '"') 2>$null
"RESULTADO AUTOARRANQUE: $pass correctas, $fail con fallo"
