# Pruebas del lanzador cifrado (Santuario.exe): sellar, ejecutar, volver a cifrar, claves incorrectas, alteraciones, cierre brusco,
# cambiar clave, descifrar y entrada maliciosa (zip-slip). Usa una copia de prueba en C:\ (NUNCA toca la USB real). ASCII.
$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$src = Join-Path $Root 'app\launcher\Santuario.cs'
$csc = Join-Path $env:windir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$pass = 0; $fail = 0
function Check([string]$name, $got, $want) { if ("$got" -eq "$want") { $script:pass++ } else { $script:fail++; "FALLA: $name -> obtuve '$got', esperaba '$want'" } }
function CheckTrue([string]$name, $cond) { Check $name ([bool]$cond) $true }

$T = Join-Path $env:SystemDrive ('santuario-vault-test-' + $PID)
New-Item -ItemType Directory -Force $T | Out-Null
$exe = Join-Path $T 'Santuario.exe'
& $csc /nologo /target:exe /optimize+ /out:$exe /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll $src 2>&1 | Out-Null
Check 'el lanzador compila' (Test-Path $exe) $true
if (-not (Test-Path $exe)) { "RESULTADO BOVEDA: $pass correctas, $fail con fallo"; return }

function WF([string]$rel, [string]$text) { $p = Join-Path $T $rel; New-Item -ItemType Directory -Force (Split-Path -Parent $p) | Out-Null; [IO.File]::WriteAllText($p, $text, (New-Object Text.UTF8Encoding($false))) }
WF 'app\env.bat' "@echo off`r`n"
WF 'app\ollama\ollama.exe' ('FAKEBIN' * 1000)
WF 'app\ollama\lib\x.dll' 'dll'
WF 'app\ollama-windows-amd64.zip' 'zipfalso'
WF 'models\m.gguf' ('MODELO' * 5000)
WF 'agent\hands.ps1' 'Write-Host SECRETO-EN-CLARO-SCRIPT'
WF 'brain.json' '{"name":"Santuario"}'
WF 'data\agent\tasks.json' '[{"t":"SECRETO-EN-CLARO-TAREA"}]'
WF 'logs\chat.txt' 'tu: mi clave es SECRETO-EN-CLARO-CHAT'
WF 'README.md' 'hola'
$stub = "@echo off`r`necho sesion >> `"%~dp0data\agent\ran.txt`"`r`nif exist `"%~dp0espera.flag`" ping -n 60 127.0.0.1 >nul`r`nexit /b 0`r`n"
[IO.File]::WriteAllText((Join-Path $T 'Santuario.bat'), $stub, [Text.Encoding]::ASCII)
function Snapshot { $h = @{}; Get-ChildItem $T -Recurse -File -Force | Where-Object { $_.Name -notin 'Santuario.exe', 'Santuario.vault', 'Santuario.vault.tmp', 'Santuario.vault.prev', '.abierto' } | ForEach-Object { $h[$_.FullName.Substring($T.Length)] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }; $h }
$orig = Snapshot
$modelHash = (Get-FileHash (Join-Path $T 'models\m.gguf')).Hash
$pw = 'clave-de-prueba-123'
function Exe([string]$stdin, [string[]]$a = @()) { $o = ($stdin | & $exe @a 2>&1 | Out-String); [pscustomobject]@{ out = $o; rc = $LASTEXITCODE } }
function ListTop { (Get-ChildItem $T -Force | ForEach-Object { $_.Name }) -join ',' }

Check 'estado inicial: sin cifrar' ((Exe '' @('--estado')).out -match 'SIN CIFRAR') $true
# ---- sellar
$r = Exe "$pw`n$pw`n" @('--sellar')
Check 'sellar: termina bien' $r.rc 0
Check 'sellar: solo quedan el exe, la boveda y las carpetas publicas' ((ListTop) -replace 'Santuario.exe|Santuario.vault|models|app', '' -replace ',', '').Length 0
Check 'sellar: existe la boveda' (Test-Path (Join-Path $T 'Santuario.vault')) $true
Check 'sellar: no quedan scripts en claro' (Test-Path (Join-Path $T 'agent')) $false
Check 'sellar: no queda data ni logs' ((Test-Path (Join-Path $T 'data')) -or (Test-Path (Join-Path $T 'logs'))) $false
Check 'sellar: app\ solo tiene lo publico' ((Get-ChildItem (Join-Path $T 'app') -Force | ForEach-Object Name | Sort-Object) -join ',') 'ollama,ollama-windows-amd64.zip'
Check 'sellar: modelos intactos' ((Get-FileHash (Join-Path $T 'models\m.gguf')).Hash) $modelHash
Check 'sellar: models y ollama ocultos' (((Get-Item (Join-Path $T 'models') -Force).Attributes -band [IO.FileAttributes]::Hidden) -ne 0) $true
$vb = [IO.File]::ReadAllBytes((Join-Path $T 'Santuario.vault'))
$vtxt = [Text.Encoding]::GetEncoding(28591).GetString($vb)
Check 'la boveda no contiene textos en claro' ($vtxt.Contains('SECRETO-EN-CLARO')) $false
Check 'la boveda no contiene nombres de archivo en claro' ($vtxt.Contains('hands.ps1') -or $vtxt.Contains('tasks.json')) $false
Check 'la boveda empieza con la marca' ($vtxt.StartsWith('SANTVLT1')) $true
Check 'estado: cifrado' ((Exe '' @('--estado')).out -match 'CIFRADO') $true
Check 'sellar de nuevo: se niega' (Exe "$pw`n$pw`n" @('--sellar')).rc 2

# ---- ejecutar con clave incorrecta
$r = Exe "mala-clave-0000`nmala-clave-0000`n" @()
Check 'clave incorrecta: no abre' ($r.rc -ne 0) $true
Check 'clave incorrecta: no aparece nada en claro' (Test-Path (Join-Path $T 'agent')) $false
Check 'clave incorrecta: avisa' ($r.out -match 'incorrecta') $true

# ---- ejecutar con la clave correcta: corre el programa, y al salir vuelve a cifrar conservando los cambios
$r = Exe "$pw`n"
Check 'ejecutar: termina bien' $r.rc 0
Check 'ejecutar: el programa se ejecuto' $r.out.Contains('Cifrando de nuevo') $true
Check 'tras salir: sin scripts en claro' (Test-Path (Join-Path $T 'agent')) $false
Check 'tras salir: sin marcador .abierto' (Test-Path (Join-Path $T '.abierto') -PathType Leaf) $false
$r = Exe "$pw`n"
Check 'segunda ejecucion: ok' $r.rc 0
# ---- los cambios hechos durante la sesion persisten (ran.txt crecio) -> se comprueba al descifrar
# ---- boveda alterada
$bak = [IO.File]::ReadAllBytes((Join-Path $T 'Santuario.vault'))
$bad = $bak.Clone(); $bad[$bad.Length - 50] = $bad[$bad.Length - 50] -bxor 1
[IO.File]::WriteAllBytes((Join-Path $T 'Santuario.vault'), $bad)
$r = Exe "$pw`n"
Check 'boveda alterada: no se abre' ($r.rc -ne 0) $true
Check 'boveda alterada: nada en claro' (Test-Path (Join-Path $T 'agent')) $false
Check 'boveda alterada: lo dice' ($r.out -match 'modificada|incorrecta') $true
[IO.File]::WriteAllBytes((Join-Path $T 'Santuario.vault'), $bak)
$trunc = $bak[0..200]
[IO.File]::WriteAllBytes((Join-Path $T 'Santuario.vault'), [byte[]]$trunc)
Check 'boveda truncada: no se abre' ((Exe "$pw`n").rc -ne 0) $true
[IO.File]::WriteAllBytes((Join-Path $T 'Santuario.vault'), [byte[]]@(1, 2, 3))
Check 'boveda basura: no se abre' ((Exe "$pw`n").rc -ne 0) $true
[IO.File]::WriteAllBytes((Join-Path $T 'Santuario.vault'), $bak)

# ---- cierre brusco: el lanzador muere con los archivos en claro; la siguiente vez se recupera
[IO.File]::WriteAllText((Join-Path $T 'espera.flag'), 'x')          # el stub espera 60 s (el flag vive en la raiz y se cifra... se crea tras abrir)
$psi = New-Object Diagnostics.ProcessStartInfo $exe
$psi.UseShellExecute = $false; $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.WorkingDirectory = $T
$pr = [Diagnostics.Process]::Start($psi); $pr.StandardInput.WriteLine($pw); $pr.StandardInput.Flush()
for ($i = 0; $i -lt 40 -and -not (Test-Path (Join-Path $T '.abierto')); $i++) { Start-Sleep -Milliseconds 500 }
Check 'sesion abierta: hay archivos en claro y marcador' ((Test-Path (Join-Path $T 'agent\hands.ps1')) -and (Test-Path (Join-Path $T '.abierto'))) $true
[IO.File]::WriteAllText((Join-Path $T 'data\agent\creado-en-sesion.txt'), 'dato nuevo')
Get-CimInstance Win32_Process | Where-Object { $_.ParentProcessId -eq $pr.Id } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Stop-Process -Id $pr.Id -Force
Start-Sleep 2
Check 'cierre brusco: quedan archivos en claro (por eso existe la recuperacion)' (Test-Path (Join-Path $T 'agent\hands.ps1')) $true
Remove-Item (Join-Path $T 'espera.flag') -Force -ErrorAction SilentlyContinue
$r = Exe "$pw`n"
Check 'recuperacion: avisa de la sesion anterior' ($r.out -match 'no se cerro bien') $true
Check 'recuperacion: vuelve a cifrar' (Test-Path (Join-Path $T 'agent')) $false
# ---- cambiar clave
$pw2 = 'otra-clave-nueva-456'
$r = Exe "$pw`n$pw2`n$pw2`n" @('--cambiar-clave')
Check 'cambiar clave: ok' $r.rc 0
Check 'clave vieja ya no sirve' ((Exe "$pw`n").rc -ne 0) $true
Check 'clave nueva sirve' ((Exe "$pw2`n").rc) 0
# ---- descifrar de forma permanente: todo vuelve identico (y lo escrito en sesion se conserva)
$r = Exe "$pw2`n" @('--abrir')
Check 'abrir: ok' $r.rc 0
Check 'abrir: se quito la boveda' (Test-Path (Join-Path $T 'Santuario.vault')) $false
$after = Snapshot
$missing = @($orig.Keys | Where-Object { -not $after.ContainsKey($_) })
$changed = @($orig.Keys | Where-Object { $after.ContainsKey($_) -and $after[$_] -ne $orig[$_] -and $_ -notmatch 'ran\.txt' })
Check 'abrir: no falta ningun archivo' $missing.Count 0
Check 'abrir: ningun archivo cambio de contenido' $changed.Count 0
Check 'abrir: lo creado en la sesion brusca se conservo' (Test-Path (Join-Path $T 'data\agent\creado-en-sesion.txt')) $true
Check 'abrir: ran.txt acumulo las sesiones' (([IO.File]::ReadAllText((Join-Path $T 'data\agent\ran.txt')) -split "`n" | Where-Object { $_ -match 'sesion' }).Count -ge 2) $true
Check 'abrir: modelos intactos' ((Get-FileHash (Join-Path $T 'models\m.gguf')).Hash) $modelHash
Check 'abrir: carpetas ya no ocultas' (((Get-Item (Join-Path $T 'models') -Force).Attributes -band [IO.FileAttributes]::Hidden) -eq 0) $true
Check 'sin cifrar: se ejecuta normal sin pedir clave' ((Exe '').rc) 0
Check 'sin cifrar: el programa corrio' ((Get-Content (Join-Path $T 'data\agent\ran.txt') | Where-Object { $_ -match 'sesion' }).Count -ge 3) $true

# ---- boveda maliciosa (zip-slip): se fabrica una con el mismo formato y se comprueba que no escribe fuera de la carpeta
Add-Type -AssemblyName System.IO.Compression
function New-Vault([string]$password, [hashtable]$entries, [string]$path) {
    $ms = New-Object IO.MemoryStream
    $zip = New-Object IO.Compression.ZipArchive($ms, [IO.Compression.ZipArchiveMode]::Create, $true)
    foreach ($k in $entries.Keys) { $e = $zip.CreateEntry($k); $s = $e.Open(); $b = [Text.Encoding]::UTF8.GetBytes($entries[$k]); $s.Write($b, 0, $b.Length); $s.Dispose() }
    $zip.Dispose(); $plain = $ms.ToArray()
    $salt = New-Object byte[] 16; (New-Object Security.Cryptography.RNGCryptoServiceProvider).GetBytes($salt)
    $iter = 10000
    $h = New-Object Security.Cryptography.HMACSHA256 (, [Text.Encoding]::UTF8.GetBytes($password))
    $out = New-Object byte[] 64
    foreach ($blk in 1, 2) {
        $s2 = $salt + [byte[]]@(0, 0, 0, $blk); $u = $h.ComputeHash($s2); $t = $u.Clone()
        for ($i = 1; $i -lt $iter; $i++) { $u = $h.ComputeHash($u); for ($j = 0; $j -lt 32; $j++) { $t[$j] = $t[$j] -bxor $u[$j] } }
        [Array]::Copy($t, 0, $out, ($blk - 1) * 32, 32)
    }
    $enc = $out[0..31]; $mac = $out[32..63]
    $aes = [Security.Cryptography.Aes]::Create(); $aes.Mode = 'CBC'; $aes.Padding = 'PKCS7'; $aes.Key = [byte[]]$enc; $aes.GenerateIV()
    $ct = $aes.CreateEncryptor().TransformFinalBlock($plain, 0, $plain.Length)
    $body = [Text.Encoding]::ASCII.GetBytes('SANTVLT1') + [BitConverter]::GetBytes([int]$iter) + $salt + $aes.IV + $ct
    $tag = (New-Object Security.Cryptography.HMACSHA256 (, [byte[]]$mac)).ComputeHash($body)
    [IO.File]::WriteAllBytes($path, [byte[]]($body + $tag))
}
$T2 = Join-Path $env:SystemDrive ('santuario-vault-test2-' + $PID)
New-Item -ItemType Directory -Force (Join-Path $T2 'inner') | Out-Null
Copy-Item $exe (Join-Path $T2 'Santuario.exe')
$evilName = '../escape-' + $PID + '.txt'
New-Vault 'clave-maliciosa-123' @{ 'ok.txt' = 'bien'; $evilName = 'FUERA' } (Join-Path $T2 'Santuario.vault')
$r2 = ('clave-maliciosa-123' | & (Join-Path $T2 'Santuario.exe') 2>&1 | Out-String)
Check 'zip-slip: no se escribe fuera de la carpeta' (Test-Path (Join-Path $env:SystemDrive ('escape-' + $PID + '.txt'))) $false
Check 'zip-slip: no se escribe en la carpeta padre' (Test-Path (Join-Path (Split-Path -Parent $T2) ('escape-' + $PID + '.txt'))) $false
Check 'zip-slip: el lanzador lo rechaza por entrada sospechosa' ($r2 -match 'sospechosa') $true
Check 'zip-slip: no se escribio NADA (ni las entradas buenas)' (Test-Path (Join-Path $T2 'ok.txt')) $false
Check 'zip-slip: la boveda maliciosa si era valida (clave correcta)' ($r2 -notmatch 'incorrecta') $true
Remove-Item -LiteralPath $T2 -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $T -Recurse -Force -ErrorAction SilentlyContinue
"RESULTADO BOVEDA: $pass correctas, $fail con fallo"
