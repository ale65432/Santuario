# Pruebas del motor de tareas (sin red, sin Ollama, sin Edge). Uso: powershell -File tasks-unit.ps1
# Usa una carpeta temporal para tareas y claves; NO toca tus tareas reales ni tu token. ASCII a proposito.
$ErrorActionPreference = 'Continue'
$App = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'app'
$Ag = Split-Path -Parent $PSScriptRoot
. (Join-Path $App 'lib.ps1')
. (Join-Path $Ag 'hands.ps1')
. (Join-Path $Ag 'tasks.ps1')
$tmp = Join-Path $env:TEMP ('santuario-tasks-test-' + $PID)
New-Item -ItemType Directory -Force $tmp | Out-Null
$script:TaskDir = $tmp
$script:SecretDirOverride = $tmp
$script:SantRoot = $tmp                # el audit de hands.ps1 tambien va a la carpeta temporal
$script:AgentDir = Join-Path $tmp 'agent'; New-Item -ItemType Directory -Force $script:AgentDir | Out-Null

$pass = 0; $fail = 0
function Check([string]$name, $got, $want) { if ("$got" -eq "$want") { $script:pass++ } else { $script:fail++; "FALLA: $name -> obtuve '$got', esperaba '$want'" } }
$now = [datetime]'2026-10-08T14:30:00'      # jueves
function P([string]$t) { Parse-TaskRequest $t $now }

# ---------------- lectura de frases
$r = P 'recuerdame manana a las 9 llamar al banco'
Check 'manana 9: ok' $r.ok $true; Check 'manana 9: tipo' $r.tipo 'recordatorio'; Check 'manana 9: texto' $r.texto 'llamar al banco'; Check 'manana 9: cuando' $r.cuando.proximo '2026-10-09T09:00:00'
$r = P 'recuerdame en 20 minutos sacar la pasta'
Check 'en 20 min: cuando' $r.cuando.proximo '2026-10-08T14:50:00'; Check 'en 20 min: texto' $r.texto 'sacar la pasta'
$r = P 'avisame hoy a las 6 de la tarde que tome agua'
Check 'hoy 6 tarde: cuando' $r.cuando.proximo '2026-10-08T18:00:00'; Check 'hoy 6 tarde: texto' $r.texto 'tome agua'
$r = P 'cada dia a las 8 busca noticias de Monterrey'
Check 'cada dia: modo' $r.cuando.modo 'diaria'; Check 'cada dia: tipo' $r.tipo 'busqueda'; Check 'cada dia: texto' $r.texto 'noticias de Monterrey'; Check 'cada dia: proximo (8:00 de hoy ya paso)' $r.cuando.proximo '2026-10-09T08:00:00'
$r = P 'cada lunes a las 9 recuerdame pagar la renta'
Check 'cada lunes: modo' $r.cuando.modo 'semanal'; Check 'cada lunes: dow' $r.cuando.dow 1; Check 'cada lunes: proximo' $r.cuando.proximo '2026-10-12T09:00:00'; Check 'cada lunes: texto' $r.texto 'pagar la renta'
$r = P 'cada 2 horas recuerdame tomar agua'
Check 'cada 2 horas: modo' $r.cuando.modo 'intervalo'; Check 'cada 2 horas: min' $r.cuando.cada_min 120
$r = P 'el viernes a las 5 de la tarde recuerdame la junta'
Check 'viernes: cuando' $r.cuando.proximo '2026-10-09T17:00:00'; Check 'viernes: texto' $r.texto 'la junta'
$r = P 'recuerdame a las 9 de la noche cenar'
Check '9 noche: cuando' $r.cuando.proximo '2026-10-08T21:00:00'; Check '9 noche: texto' $r.texto 'cenar'
$r = P 'recuerdame manana llamar a mama'
Check 'manana sin hora: 9:00' $r.cuando.proximo '2026-10-09T09:00:00'; Check 'manana sin hora: texto' $r.texto 'llamar a mama'
$r = P 'programa cada dia a las 7 de la manana dime una frase motivadora'
Check 'pregunta: tipo' $r.tipo 'pregunta'; Check 'pregunta: hora' $r.cuando.proximo '2026-10-09T07:00:00'
$r = P 'recuerdame pasado manana a las 10 revisar correo'
Check 'pasado manana' $r.cuando.proximo '2026-10-10T10:00:00'
$r = P 'en media hora recuerdame apagar el horno'
Check 'media hora' $r.cuando.proximo '2026-10-08T15:00:00'
$r = P 'recuerdame a las 5 salir'
Check 'a las 5 sin periodo = 17:00' $r.cuando.proximo '2026-10-08T17:00:00'
$r = P 'recuerdame hoy a las 8 de la manana algo'
Check 'hora pasada de hoy' $r.ok $false
$r = P 'recuerdame manana a las 9 por telegram llamar al banco'
Check 'canal telegram' $r.canal 'telegram'; Check 'canal: texto' $r.texto 'llamar al banco'
$r = P 'recuerdame llamar a mama'
Check 'sin cuando' $r.ok $false
$r = P 'recuerdame manana a las 9'
Check 'sin contenido' $r.ok $false
$r = P ('recuerdame manana a las 9 ' + ('x' * 400))
Check 'texto largo' $r.ok $false
$r = P 'recuerdame manana a las 25 algo'
Check 'hora invalida no se interpreta como hora' ($r.ok -and $r.cuando.proximo -match 'T25') $false

# ---------------- intencion (no secuestrar charla normal)
foreach ($s in 'recuerdame manana a las 9 llamar', 'cada dia a las 8 busca noticias', 'avisame en 5 minutos', 'programa cada lunes a las 9 revisar', 'en 20 minutos recuerdame algo') { Check ('intencion si: ' + $s) (Test-TaskIntent $s) $true }
foreach ($s in 'hola como estas', 'explicame que es una tarea', 'busca recetas de pozole', 'que hora es', 'escribe un script que se ejecute cada dia', 'abre youtube') { Check ('intencion no: ' + $s) (Test-TaskIntent $s) $false }

# ---------------- almacen, firmas, limites
$p1 = P 'recuerdame manana a las 9 llamar al banco'
$c = Add-Task $p1 'consola' 'consola' $now
Check 'crear recordatorio' $c.ok $true; Check 'estado activa' $c.task.estado 'activa'; Check 'firma valida' (Test-TaskSig $c.task) $true
$stored = Load-Tasks
Check 'guardada en disco' @($stored).Count 1
Check 'firma valida tras recargar' (Test-TaskSig $stored[0]) $true
$stored[0].texto = 'transferir todo mi dinero'
Check 'firma detecta edicion del texto' (Test-TaskSig $stored[0]) $false
$pb = P 'cada dia a las 8 busca noticias de Monterrey'
$cb = Add-Task $pb 'remoto' 'telegram' $now
Check 'remoto busqueda: se crea' $cb.ok $true; Check 'remoto busqueda: PENDIENTE de aprobacion' $cb.task.estado 'pendiente'
$pq = P 'cada dia a las 7 de la manana dime una frase motivadora'
Check 'remoto pregunta: rechazada' (Add-Task $pq 'remoto' 'telegram' $now).ok $false
$pa = P 'manana a las 9 abre youtube'
Check 'accion programada: rechazada (desactivada)' (Add-Task $pa 'consola' 'consola' $now).ok $false
$pi = P 'cada 30 minutos busca noticias'
Check 'busqueda cada 30 min: rechazada' (Add-Task $pi 'consola' 'consola' $now).ok $false
$pr = P 'cada 30 minutos recuerdame estirarme'
Check 'recordatorio cada 30 min: ok' (Add-Task $pr 'consola' 'consola' $now).ok $true
Check 'Set-TaskState NO puede aprobar una pendiente' (Set-TaskState $cb.task.id 'activa') $false
Check 'aprobar pendiente (Approve-Task)' (Approve-Task $cb.task.id) $true
Check 'aprobada: prueba valida' (Test-TaskApproval (Load-Tasks | Where-Object { $_.id -eq $cb.task.id })) $true
Check 'cancelar' (Set-TaskState $c.task.id 'cancelada') $true
Check 'no se cancela dos veces' (Set-TaskState $c.task.id 'cancelada') $false
# limite de tareas vigentes (max_active)
$extra = 0
for ($i = 0; $i -lt 15; $i++) { if ((Add-Task (P ('recuerdame manana a las 10 cosa numero ' + $i)) 'consola' 'consola' $now).ok) { $extra++ } }
Check 'tope de tareas vigentes' (@(Load-Tasks | Where-Object { $_.estado -in 'activa', 'pendiente' }).Count) ([int]$script:TPol.scheduler.max_active)

# ---------------- planificador
Remove-Item (Get-TaskFile) -Force
$script:Delivered = New-Object System.Collections.ArrayList
function Deliver-Message([string]$canal, [string]$text, [string]$id = '') { [void]$script:Delivered.Add(@{ canal = $canal; text = $text; id = $id }) }
function Resolve-Region { @{ model = 'stub'; alias = 'stub'; id = 'general' } }
function Ask-Model { param($model, $messages, $numPredict, $temp, $timeoutSec) 'respuesta de prueba' }
function Do-GoogleSearch { param($q) @{ ok = $true; query = $q; results = @(@{ t = 'Titulo uno'; u = 'https://example.org/a'; s = 'texto uno' }) } }

# a) recordatorio vencido hace 1 min: se entrega; "una vez" queda completada
$ta = Add-Task (P 'recuerdame en 1 minutos tomar agua') 'consola' 'consola' $now
$later = $now.AddMinutes(2)
$n = Run-DueTasks $later
Check 'vencida: se ejecuto 1' $n 1
Check 'entrega: texto' $script:Delivered[0].text 'Recordatorio: tomar agua'
Check 'una vez -> completada' ((Load-Tasks | Where-Object { $_.id -eq $ta.task.id }).estado) 'completada'
Check 'no se repite' (Run-DueTasks $later.AddMinutes(1)) 0
# b) intervalo: se reprograma desde "ahora" (sin ponerse al dia)
$script:Delivered.Clear()
$tb = Add-Task (P 'cada 10 minutos recuerdame estirarme') 'consola' 'consola' $now
[void](Run-DueTasks $now.AddMinutes(11))
$tb2 = Load-Tasks | Where-Object { $_.id -eq $tb.task.id }
Check 'intervalo: sigue activa' $tb2.estado 'activa'; Check 'intervalo: proximo = ahora + 10' $tb2.cuando.proximo ($now.AddMinutes(21).ToString('s')); Check 'intervalo: 1 ejecucion' $tb2.ejecuciones 1
# c) diaria: proxima manana a la misma hora
$tc = Add-Task (P 'cada dia a las 9 recuerdame hacer ejercicio') 'consola' 'consola' $now
[void](Run-DueTasks ([datetime]'2026-10-09T09:01:00'))
Check 'diaria: siguiente dia' ((Load-Tasks | Where-Object { $_.id -eq $tc.task.id }).cuando.proximo) '2026-10-10T09:00:00'
# d) atrasada y de tipo busqueda: NO se ejecuta
$script:Delivered.Clear()
$td = Add-Task (P 'manana a las 9 busca el clima') 'consola' 'consola' $now
[void](Run-DueTasks ([datetime]'2026-10-09T11:00:00'))
if (@($script:Delivered | Where-Object { $_.text -match 'no se ejecuto' }).Count -ne 1) { $script:Delivered | ForEach-Object { '   >> entregado: [' + $_.id + '] ' + $_.text } }
Check 'busqueda atrasada: avisa' @($script:Delivered | Where-Object { $_.text -match 'no se ejecuto' }).Count 1
Check 'busqueda atrasada: completada sin ejecutar' ((Load-Tasks | Where-Object { $_.id -eq $td.task.id }).estado) 'completada'
# e) busqueda a tiempo: ejecuta con el buscador y resume
$script:Delivered.Clear()
$te = Add-Task (P 'manana a las 9 busca el clima') 'consola' 'consola' $now
[void](Run-DueTasks ([datetime]'2026-10-09T09:00:30'))
Check 'busqueda a tiempo: entrega resumen' (@($script:Delivered | Where-Object { $_.text -match 'respuesta de prueba' }).Count -ge 1) $true
Check 'busqueda no entrega enlaces completos' (@($script:Delivered | Where-Object { $_.text -match 'https?://' }).Count) 0
# f) firma alterada: se BLOQUEA
$script:Delivered.Clear()
$tf = Add-Task (P 'recuerdame en 1 minutos algo inocente') 'consola' 'consola' $now
$all = Load-Tasks; foreach ($x in $all) { if ($x.id -eq $tf.task.id) { $x.texto = 'algo malicioso' } }; Save-Tasks $all
[void](Run-DueTasks $now.AddMinutes(5))
Check 'firma alterada: bloqueada' ((Load-Tasks | Where-Object { $_.id -eq $tf.task.id }).estado) 'bloqueada'
Check 'firma alterada: se avisa' (@($script:Delivered | Where-Object { $_.text -match 'BLOQUEADA' }).Count) 1
Check 'firma alterada: NO se ejecuto el texto' (@($script:Delivered | Where-Object { $_.text -match 'malicioso' }).Count) 0
# g) caducidad
$script:Delivered.Clear()
$tg = Add-Task (P 'cada dia a las 6 recuerdame algo') 'consola' 'consola' $now
[void](Run-DueTasks ($now.AddDays(40)))
Check 'caducada' ((Load-Tasks | Where-Object { $_.id -eq $tg.task.id }).estado) 'caducada'
# h) una tarea con error no tumba a las demas
$script:Delivered.Clear()
function Ask-Model { throw 'fallo simulado del modelo' }
$th = Add-Task (P 'cada dia a las 7 de la manana dime algo') 'consola' 'consola' $now
$ti = Add-Task (P 'recuerdame en 1 minutos otra cosa') 'consola' 'consola' $now
[void](Run-DueTasks ([datetime]'2026-10-09T07:00:10'))
Check 'error en una tarea: se avisa y sigue' (@($script:Delivered | Where-Object { $_.text -match 'Error en la tarea' }).Count -ge 1) $true

# ---------------- ataques al almacen y a la programacion
Remove-Item (Get-TaskFile) -Force
$script:Delivered.Clear()
$rb = Add-Task (P 'cada dia a las 8 busca noticias') 'remoto' 'telegram' $now
Check 'remoto busqueda: pendiente' $rb.task.estado 'pendiente'
$all = Load-Tasks; foreach ($x in $all) { if ($x.id -eq $rb.task.id) { $x.estado = 'activa' } }; Save-Tasks $all           # "atacante" la activa a mano, sin aprobar
[void](Run-DueTasks ([datetime]'2026-10-09T08:00:30'))
Check 'activada a mano SIN aprobacion: bloqueada' ((Load-Tasks | Where-Object { $_.id -eq $rb.task.id }).estado) 'bloqueada'
Check 'activada a mano: se avisa y no se ejecuta' (@($script:Delivered | Where-Object { $_.text -match 'aprobacion' }).Count) 1
Remove-Item (Get-TaskFile) -Force
$script:Delivered.Clear()
$rs = Add-Task (P 'cada 120 minutos recuerdame algo') 'consola' 'consola' $now
$all = Load-Tasks; foreach ($x in $all) { if ($x.id -eq $rs.task.id) { $x.cuando.cada_min = 1 } }; Save-Tasks $all             # baja el intervalo
Check 'cambiar la programacion invalida la firma' (Test-TaskSig (Load-Tasks | Select-Object -First 1)) $false
[void](Run-DueTasks $now.AddMinutes(130))
Check 'programacion alterada: bloqueada' ((Load-Tasks | Select-Object -First 1).estado) 'bloqueada'
# archivo ilegible: NUNCA se vuelve a guardar vacio
Remove-Item (Get-TaskFile) -Force
$keep = Add-Task (P 'recuerdame manana a las 9 no perder esto') 'consola' 'consola' $now
[IO.File]::WriteAllText((Get-TaskFile), '{ esto no es json [', (New-Object Text.UTF8Encoding($false)))
$threw = $false; try { [void](Load-Tasks) } catch { $threw = $true }
Check 'archivo corrupto: Load-Tasks avisa (no devuelve vacio)' $threw $true
$threw2 = $false; try { [void](Add-Task (P 'recuerdame manana a las 9 otra') 'consola' 'consola' $now) } catch { $threw2 = $true }
Check 'archivo corrupto: Add-Task no sobrescribe' $threw2 $true
Check 'archivo corrupto: contenido intacto' ((Get-Content (Get-TaskFile) -Raw).Trim()) '{ esto no es json ['
Remove-Item (Get-TaskFile) -Force
# si guardar falla, la tarea NO se ejecuta (ni se repite en bucle)
$script:Delivered.Clear()
$tz = Add-Task (P 'recuerdame en 1 minutos prueba de disco') 'consola' 'consola' $now
$origSave = ${function:Save-Tasks}
function Save-Tasks { throw 'disco lleno (simulado)' }
$threwRun = $false; try { [void](Run-DueTasks $now.AddMinutes(3)) } catch { $threwRun = $true }
Set-Item function:Save-Tasks $origSave
Check 'si falla el guardado: la ejecucion se aborta' $threwRun $true
Check 'si falla el guardado: NO se entrego nada' $script:Delivered.Count 0
[void](Run-DueTasks $now.AddMinutes(3))
Check 'al recuperarse el disco: se ejecuta UNA vez' (@($script:Delivered | Where-Object { $_.text -match 'prueba de disco' }).Count) 1
[void](Run-DueTasks $now.AddMinutes(4))
Check 'y no se repite' (@($script:Delivered | Where-Object { $_.text -match 'prueba de disco' }).Count) 1
# STOP detiene el lote
Remove-Item (Get-TaskFile) -Force
$script:Delivered.Clear()
[void](Add-Task (P 'recuerdame en 1 minutos uno') 'consola' 'consola' $now)
New-Item -ItemType File -Force (Join-Path $script:AgentDir 'STOP') | Out-Null
[void](Run-DueTasks $now.AddMinutes(3))
Remove-Item (Join-Path $script:AgentDir 'STOP') -Force
Check 'STOP: no se ejecuta nada' $script:Delivered.Count 0
# horas y "cada N dias"
$r = P 'cada 2 dias a las 9 recuerdame regar las plantas'
Check 'cada 2 dias: modo' $r.cuando.modo 'intervalo'; Check 'cada 2 dias: minutos' $r.cuando.cada_min 2880; Check 'cada 2 dias: texto' $r.texto 'regar las plantas'
$r = P 'recuerdame manana a las 9 amigos'
Check '"9 amigos" no es "9 am"' $r.texto 'amigos'
# candado de politica
$script:SecretDirOverride = $tmp
Remove-Item (Join-Path $tmp 'policy.sha256') -Force -ErrorAction SilentlyContinue
Check 'politica: primera vez = nuevo' (Test-PolicyApproved) 'nuevo'
Approve-Policy
Check 'politica: aprobada = ok' (Test-PolicyApproved) 'ok'
[IO.File]::WriteAllText((Join-Path $tmp 'policy.sha256'), 'HUELLA-DE-OTRA-POLITICA')
Check 'politica: cambiada = cambio' (Test-PolicyApproved) 'cambio'
# ---------------- secretos: el token nunca sale en mensajes de error
$fake = ('1234567890' + ':' + 'AAAbbbCCCdddEEEfffGGGhhhIIIjjjKKK12')
Check 'redacta token en URL' ((Redact-Secrets ('fallo en https://api.telegram.org/bot' + $fake + '/getUpdates')) -match 'AAAbbb') $false
Check 'redacta token suelto' ((Redact-Secrets ('error ' + $fake)) -match 'AAAbbb') $false

cmd /c rmdir /s /q ('"' + $tmp + '"') 2>$null
"RESULTADO TAREAS: $pass correctas, $fail con fallo"
