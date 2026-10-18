# Pruebas de la habilidad "crear archivos y carpetas". Sin modelo (el contenido se pasa a mano). ASCII.
# Uso (dentro de app\env.bat): powershell -File skills-create-test.ps1
$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$App = Join-Path $Root 'app'; $Ag = Join-Path $Root 'agent'
. (Join-Path $App 'lib.ps1')
. (Join-Path $Ag 'hands.ps1')
. (Join-Path $Ag 'skills\skills.ps1')
$script:Origin = 'consola'
$env:SANTUARIO_TEST = '1'
$script:SkConfirm = { param($d) $true }
$pass = 0; $fail = 0
function Check([string]$name, $got, $want) { if ("$got" -eq "$want") { $script:pass++ } else { $script:fail++; "FALLA: $name -> obtuve '$got', esperaba '$want'" } }
function CheckTrue([string]$name, $cond) { Check $name ([bool]$cond) $true }
$ws = Get-WorkspaceRoot
$made = New-Object System.Collections.ArrayList

# ---- interpretacion de la peticion
$r = Parse-CreateRequest 'crea un archivo notas.txt con el texto hola mundo'
Check 'parse: nombre' $r.name 'notas.txt'; Check 'parse: contenido' $r.content 'hola mundo'; Check 'parse: tipo' $r.kind 'file'
$r = Parse-CreateRequest 'crea un archivo llamado ideas con el contenido: uno, dos y tres'
Check 'parse llamado: nombre' $r.name 'ideas'; Check 'parse llamado: contenido' $r.content 'uno, dos y tres'
$r = Parse-CreateRequest 'crea una carpeta Proyectos'
Check 'parse carpeta: tipo' $r.kind 'folder'; Check 'parse carpeta: nombre' $r.name 'Proyectos'
$r = Parse-CreateRequest 'hazme un script de powershell que liste mis descargas'
Check 'parse script: ext' $r.ext 'ps1'; CheckTrue 'parse script: sin contenido literal (lo redacta el modelo)' ($null -eq $r.content); CheckTrue 'parse script: descripcion' ($r.desc -match 'liste mis descargas')
$r = Parse-CreateRequest 'crea un archivo "C:\Users\Prueba Uno\nota.txt" con el texto hola'
Check 'parse ruta con comillas' $r.name 'C:\Users\Prueba Uno\nota.txt'
$r = Parse-CreateRequest 'crea un archivo C:\temp\datos\lista.csv con el texto a,b,c'
Check 'parse ruta absoluta' $r.name 'C:\temp\datos\lista.csv'; Check 'parse ruta: contenido' $r.content 'a,b,c'

# ---- destinos
$t1 = Resolve-CreateTarget (Parse-CreateRequest 'crea un archivo notas.txt con el texto hola')
Check 'destino simple en el taller' $t1 (Join-Path $ws 'archivos\notas.txt')
$t2 = Resolve-CreateTarget (Parse-CreateRequest 'crea un archivo llamado ideas con el texto x')
CheckTrue 'sin extension: se completa .txt' ($t2 -like '*ideas.txt')
Check 'subruta relativa: rechazada' (Resolve-CreateTarget @{ kind = 'file'; name = 'a\b.txt'; ext = ''; content = 'x'; desc = '' }) $null
Check 'punto-punto: rechazado' (Resolve-CreateTarget @{ kind = 'file'; name = '..\x.txt'; ext = ''; content = 'x'; desc = '' }) $null
Check 'nombre reservado CON: rechazado' (Resolve-CreateTarget @{ kind = 'file'; name = 'CON.txt'; ext = ''; content = 'x'; desc = '' }) $null
Check 'nombre oculto .env: rechazado' (Resolve-CreateTarget @{ kind = 'file'; name = '.env'; ext = ''; content = 'x'; desc = '' }) $null

# ---- validacion de destino
Check 'ext .exe rechazada' (Test-CreateTarget (Join-Path $ws 'archivos\x.exe') 'file').ok $false
Check 'ext .bat rechazada' (Test-CreateTarget (Join-Path $ws 'archivos\x.bat') 'file').ok $false
Check 'ext .reg rechazada' (Test-CreateTarget (Join-Path $ws 'archivos\x.reg') 'file').ok $false
Check 'ext .lnk rechazada' (Test-CreateTarget (Join-Path $ws 'archivos\x.lnk') 'file').ok $false
Check 'credentials.txt rechazado (reservado a secretos)' (Test-CreateTarget (Join-Path $ws 'archivos\credentials.txt') 'file').ok $false
Check 'flujo alterno rechazado' (Test-CreateTarget (Join-Path $ws 'archivos\a.txt:oculto') 'file').ok $false
Check 'carpeta de Santuario (app) rechazada' (Test-CreateTarget (Join-Path $Root 'app\nuevo.txt') 'file').ok $false
$ng = Test-CreateTarget 'C:\Users\Public\fuera.txt' 'file'
Check 'fuera de lo concedido: pide permiso' $ng.need_grant $true
Check 'ruta UNC rechazada' (Test-CreateTarget '\\localhost\c$\x.txt' 'file').ok $false

# ---- crear de verdad (con confirmacion de prueba)
$stamp = [Guid]::NewGuid().ToString('N').Substring(0, 6)
$f1 = 'prueba-' + $stamp + '.txt'
$plan = New-CreatePlan ('crea un archivo ' + $f1 + ' con el texto Hola desde Santuario, acentos: canci' + [char]0xF3 + 'n')
Check 'plan ok' $plan.ok $true
$res = Invoke-CreatePlan $plan
Check 'crea archivo' $res.ok $true
if ($res.ok) { [void]$made.Add($res.path) }
Check 'contenido escrito' ([IO.File]::ReadAllText($res.path)) ('Hola desde Santuario, acentos: canci' + [char]0xF3 + 'n')
Check 'no sobrescribe (segundo intento)' (New-CreatePlan ('crea un archivo ' + $f1 + ' con el texto otro')).ok $false
CheckTrue 'no sobrescribe: motivo' ((New-CreatePlan ('crea un archivo ' + $f1 + ' con el texto otro')).reason -match 'ya existe')
# confirmacion rechazada: no crea
$script:SkConfirm = { param($d) $false }
$f2 = 'rechazado-' + $stamp + '.txt'
$res2 = Invoke-CreatePlan (New-CreatePlan ('crea un archivo ' + $f2 + ' con el texto x'))
Check 'rechazado: no crea' $res2.ok $false; Check 'rechazado: archivo no existe' (Test-Path (Join-Path $ws ('archivos\' + $f2))) $false
$script:SkConfirm = { param($d) $true }
# contenido peligroso o invalido (redactado por un modelo, aqui simulado)
$f3 = 'script-' + $stamp + '.ps1'
$pl3 = New-CreatePlan ('crea un script de powershell llamado ' + $f3 + ' que haga algo') 'Invoke-Expression $x'
$pl3.target = Join-Path $ws ('archivos\' + $f3)
Check 'script con Invoke-Expression: no se crea' (Invoke-CreatePlan $pl3).ok $false
$pl3b = New-CreatePlan ('crea un script de powershell llamado ' + $f3 + ' que haga algo') 'function A { if ('
Check 'script con sintaxis rota: no se crea' (Invoke-CreatePlan $pl3b).ok $false
$pl3c = New-CreatePlan ('crea un script de powershell llamado ' + $f3 + ' que haga algo') ('# lista las descargas' + "`r`n" + 'Get-ChildItem "$env:USERPROFILE\Downloads" | Select-Object -First 10 Name')
$res3 = Invoke-CreatePlan $pl3c
Check 'script sano: se crea' $res3.ok $true
if ($res3.ok) { [void]$made.Add($res3.path) }
$f4 = 'datos-' + $stamp + '.json'
Check 'json invalido: no se crea' (Invoke-CreatePlan (New-CreatePlan ('crea un archivo ' + $f4 + ' con el texto {no es json'))).ok $false
Check 'contenido vacio: no se crea' (Invoke-CreatePlan (New-CreatePlan ('crea un archivo vacio-' + $stamp + '.txt') '')).ok $false
Check 'contenido gigante: no se crea' (Invoke-CreatePlan (New-CreatePlan ('crea un archivo gordo-' + $stamp + '.txt') ('x' * 70000))).ok $false
# secretos en el contenido: la vista previa los tapa
$seen = New-Object System.Collections.ArrayList
$prevT = { param($pl, $v) [void]$seen.Add((Mask-Text $pl.content)) }
$f5 = 'clave-' + $stamp + '.txt'
$secretText = 'mi clave AKIA' + 'QWERTYUIOP' + 'ASDFGH fin'
$r5 = Invoke-CreatePlan (New-CreatePlan ('crea un archivo ' + $f5 + ' con el texto ' + $secretText)) $prevT
if ($r5.ok) { [void]$made.Add($r5.path) }
CheckTrue 'vista previa sin el secreto' (-not (($seen -join '').Contains('AKIAQWERTY')))
# carrera: el archivo aparece entre la vista previa y la escritura
$f6 = 'carrera-' + $stamp + '.txt'
$pl6 = New-CreatePlan ('crea un archivo ' + $f6 + ' con el texto uno')
[IO.File]::WriteAllText($pl6.target, 'intruso')
Check 'carrera: no pisa el archivo que aparecio' (Invoke-CreatePlan $pl6).ok $false
Check 'carrera: contenido intacto' ([IO.File]::ReadAllText($pl6.target)) 'intruso'
[void]$made.Add($pl6.target)
# carpetas
$d1 = 'Carpeta-' + $stamp
$pd = New-CreatePlan ('crea una carpeta ' + $d1)
Check 'plan de carpeta' $pd.ok $true
$rd = Invoke-CreatePlan $pd
Check 'crea carpeta' $rd.ok $true
CheckTrue 'carpeta existe' (Test-Path -LiteralPath (Join-Path $ws ('archivos\' + $d1)) -PathType Container)
if ($rd.ok) { [void]$made.Add($rd.path) }
Check 'carpeta repetida: rechazada' (New-CreatePlan ('crea una carpeta ' + $d1)).ok $false
# carpeta del usuario con permiso de escritura
$U = Join-Path (Get-RealFolders).UserProfile ('santuario-create-test-' + $PID)
New-Item -ItemType Directory -Force $U | Out-Null
$pu = New-CreatePlan ('crea un archivo "' + $U + '\nota.txt" con el texto hola')
Check 'carpeta ajena sin permiso: pide permiso' ($pu.check.need_grant -eq $true) $true
$null = Add-SessionGrant $U 'write'
$pu2 = New-CreatePlan ('crea un archivo "' + $U + '\nota.txt" con el texto hola')
Check 'con permiso de escritura: ok' $pu2.ok $true
Check 'crea en carpeta del usuario' (Invoke-CreatePlan $pu2).ok $true
Check 'lo creado se puede leer luego (/leer)' (Read-FileSafe ($U + '\nota.txt')).ok $true
# lectura sin permiso de lectura aparte: la concesion de escritura no da lectura
Check 'escritura implica lectura de lo creado' (Resolve-SafePath ($U + '\nota.txt') 'read').ok $true
Check 'pero la lista negra sigue: .env no se lee' (Read-FileSafe ($U + '\.env')).ok $false
Check 'lectura sola no da escritura' (Resolve-SafePath ($proj0 = (Join-Path (Get-RealFolders).UserProfile 'santuario-nope')) 'write').ok $false
# origen
$script:Origin = 'remoto'
$thr = $false; try { New-CreatePlan 'crea un archivo x.txt con el texto hola' | Out-Null } catch { $thr = $true }
Check 'origen remoto bloqueado' $thr $true
$script:Origin = 'consola'
# los archivos creados no se ejecutan: ninguna ruta de creacion llama a Start-Process/Invoke-Expression
$src = [IO.File]::ReadAllText((Join-Path $Ag 'skills\creator.ps1'))
Check 'creator.ps1 no ejecuta nada' ($src -match 'Start-Process|Invoke-Expression|\biex\b|Invoke-Item|\.Start\(') $false

foreach ($p in $made) { if ($p -and (Test-Path -LiteralPath $p) -and (Test-UnderRoot $p $ws)) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue } }
Remove-Item -LiteralPath $U -Recurse -Force -ErrorAction SilentlyContinue
"RESULTADO CREAR: $pass pasaron, $fail fallaron"
