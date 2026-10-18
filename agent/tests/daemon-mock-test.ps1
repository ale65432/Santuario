# Prueba de extremo a extremo del demonio con un Telegram FALSO local (sin internet, sin tu token real, sin modelos, sin Edge).
# Todo ocurre en una carpeta temporal. Uso: powershell -File daemon-mock-test.ps1     (tarda ~3-4 min). ASCII a proposito.
$ErrorActionPreference = 'Continue'
$Ag = Split-Path -Parent $PSScriptRoot
$App = Join-Path (Split-Path -Parent $Ag) 'app'
. (Join-Path $App 'lib.ps1'); . (Join-Path $Ag 'hands.ps1'); . (Join-Path $Ag 'tasks.ps1'); . (Join-Path $Ag 'telegram.ps1')
$tmp = Join-Path $env:TEMP ('santuario-mock-' + $PID)
New-Item -ItemType Directory -Force $tmp | Out-Null
$script:TaskDir = Join-Path $tmp 'data\agent'; $script:SecretDirOverride = Join-Path $tmp 'secret'; $script:SantRoot = $tmp
New-Item -ItemType Directory -Force $script:TaskDir | Out-Null
$port = Get-Random -Minimum 30000 -Maximum 40000
$tok = ('1234567890' + ':' + 'AAAbbbCCCdddEEEfffGGGhhhIIIjjjKKK99')
$api = "http://127.0.0.1:$port"
$script:TgCfg.api_base = $api
$script:TgAllowTestBase = $true
$pass = 0; $fail = 0
function Check([string]$name, $got, $want) { if ("$got" -eq "$want") { $script:pass++; "  ok  $name" } else { $script:fail++; "  FALLA $name -> '$got' (esperaba '$want')" } }
$oacute = [char]0xF3

function Start-Mock { Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'mock-telegram.ps1'), '-Port', $port, '-Dir', $tmp, '-Token', $tok -WindowStyle Hidden -PassThru }
function Wait-Mock { for ($i = 0; $i -lt 40; $i++) { try { Invoke-RestMethod "$api/bot$tok/getMe" -Method Post -Body '{}' -ContentType 'application/json' -TimeoutSec 2 | Out-Null; return $true } catch { Start-Sleep -Milliseconds 300 } }; $false }
function Start-Daemon([string]$tag) {
    $d = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Ag 'daemon.ps1'), '-TestRoot', $tmp, '-TestApiBase', $api, '-TestStubModel', '-TestHighRate' -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $tmp "daemon-$tag.out.txt") -RedirectStandardError (Join-Path $tmp "daemon-$tag.err.txt")
    $null = $d.Handle
    $d
}
function Stop-Daemon($d) {
    New-Item -ItemType File -Force (Join-Path $tmp 'agent\QUIT') | Out-Null
    $null = $d.WaitForExit(40000)
    if (-not $d.HasExited) { Stop-Process -Id $d.Id -Force }
}
$mock = $null; $daemon = $null
try {
    $mock = Start-Mock
    [void](Wait-Mock)
    Save-TgToken (ConvertTo-SecureString $tok -AsPlainText -Force)
    $script:updates = New-Object System.Collections.ArrayList; $script:uid = 100
    function Write-Updates($list, [string]$name = 'updates.json') { [IO.File]::WriteAllText((Join-Path $tmp $name), (ConvertTo-Json -InputObject @($list) -Depth 8), (New-Object Text.UTF8Encoding($false))) }
    function New-Upd([long]$from, [long]$chat, [string]$type, [string]$text, [hashtable]$extra = @{}, [long]$date = 0) {
        $script:uid++
        if ($date -eq 0) { $date = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
        $msg = @{ message_id = $script:uid; from = @{ id = $from; is_bot = $false; first_name = 'X' }; chat = @{ id = $chat; type = $type }; date = $date; text = $text }
        foreach ($k in $extra.Keys) { $msg[$k] = $extra[$k] }
        @{ update_id = $script:uid; message = $msg }
    }
    function Push([long]$from, [long]$chat, [string]$type, [string]$text, [hashtable]$extra = @{}) { [void]$script:updates.Add((New-Upd $from $chat $type $text $extra)); Write-Updates $script:updates }
    function Sent { @(Get-Content (Join-Path $tmp 'sent.jsonl') -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object { $_ | ConvertFrom-Json }) }
    function Sent-Count { @(Sent).Count }
    function Wait-Sent([int]$n, [int]$sec = 25) { $end = (Get-Date).AddSeconds($sec); while ((Get-Date) -lt $end) { if ((Sent-Count) -ge $n) { return $true }; Start-Sleep -Milliseconds 300 }; $false }
    function Last-Text { $s = @(Sent); if ($s.Count) { [string]$s[$s.Count - 1].text } else { '' } }
    function Any-Text([string]$rx, [int]$sec = 20) { $end = (Get-Date).AddSeconds($sec); while ((Get-Date) -lt $end) { if (@(Sent | Where-Object { $_.text -match $rx }).Count -gt 0) { return $true }; Start-Sleep -Milliseconds 300 }; $false }

    '--- tokens y limites (en proceso)'
    $script:TgMinute.Clear(); $script:TgHour.Clear()
    $okCount = 0; for ($i = 0; $i -lt 10; $i++) { if (Test-TgRate) { $okCount++ } }
    Check 'limite por minuto (6)' $okCount 6
    $script:TgMinute.Clear(); $script:TgHour.Clear()
    $owner = [pscustomobject]@{ user_id = 111; chat_id = 111 }
    Check 'dueno: mensaje valido' ([bool](Get-OwnerMessage @{ message = (New-Upd 111 111 'private' 'hola').message } $owner)) $true
    Check 'extrano: ignorado' ([bool](Get-OwnerMessage @{ message = (New-Upd 999 999 'private' 'hola').message } $owner)) $false
    Check 'grupo: ignorado' ([bool](Get-OwnerMessage @{ message = (New-Upd 111 -500 'group' 'hola').message } $owner)) $false
    Check 'mismo usuario en otro chat: ignorado' ([bool](Get-OwnerMessage @{ message = (New-Upd 111 222 'private' 'hola').message } $owner)) $false
    Check 'reenviado: ignorado' ([bool](Get-OwnerMessage @{ message = (New-Upd 111 111 'private' 'hola' @{ forward_origin = @{ type = 'user' } }).message } $owner)) $false
    Check 'via bot: ignorado' ([bool](Get-OwnerMessage @{ message = (New-Upd 111 111 'private' 'hola' @{ via_bot = @{ id = 5 } }).message } $owner)) $false
    Check 'foto sin texto: ignorada' ([bool](Get-OwnerMessage @{ message = @{ from = @{ id = 111; is_bot = $false }; chat = @{ id = 111; type = 'private' }; date = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); photo = @(1) } } $owner)) $false
    Check 'mensaje viejo (10 min): ignorado' ([bool](Get-OwnerMessage @{ message = (New-Upd 111 111 'private' 'hola' @{} ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 600)).message } $owner)) $false

    '--- el token solo va a api.telegram.org'
    $script:TgAllowTestBase = $false
    $saved = $script:TgCfg.api_base
    $script:TgCfg.api_base = 'https://evil.example.com'
    $threw = $false; $msgErr = ''; try { [void](Invoke-Tg 'getMe') } catch { $threw = $true; $msgErr = [string]$_.Exception.Message }
    Check 'api_base ajeno: NO se envia el token' $threw $true
    Check 'api_base ajeno: el mensaje no contiene el token' ($msgErr -match 'AAAbbbCCC') $false
    $script:TgCfg.api_base = 'http://127.0.0.1:1'
    $threw2 = $false; try { [void](Invoke-Tg 'getMe') } catch { $threw2 = $true }
    Check 'localhost sin modo de prueba: rechazado' $threw2 $true
    $script:TgCfg.api_base = $saved; $script:TgAllowTestBase = $true
    Check 'la URL real de Telegram es valida' (Test-TgBase 'https://api.telegram.org') $true
    Check 'http a Telegram no es valido' (Test-TgBase 'http://api.telegram.org') $false
    Check 'dominio parecido no es valido' (Test-TgBase 'https://api.telegram.org.evil.com') $false

    '--- emparejamiento (un intento erroneo y luego el codigo correcto)'
    $sent0 = New-Upd 500 500 'private' 'mensaje anterior (se descarta)'
    Write-Updates @($sent0)
    $good = 'ABCD-2345'
    $next = @($sent0, (New-Upd 999 999 'private' '/emparejar CODIGO-MALO'), (New-Upd 111 111 'private' ('/emparejar ' + $good.ToLower())))
    Write-Updates $next 'updates.next.json'
    Start-Process powershell -ArgumentList '-NoProfile', '-Command', ("Start-Sleep 3; Copy-Item '" + (Join-Path $tmp 'updates.next.json') + "' '" + (Join-Path $tmp 'updates.json') + "' -Force") -WindowStyle Hidden | Out-Null
    $r = Wait-TgPairing $good 1
    Check 'emparejado' $r.ok $true
    $ow = Get-TgOwner
    Check 'dueno guardado (user_id)' $ow.user_id 111; Check 'dueno guardado (chat_id)' $ow.chat_id 111
    Check 'dueno FIRMADO' ([bool]$ow.firma) $true
    Check 'confirmacion enviada al dueno' (@(Sent | Where-Object { $_.chat_id -eq 111 -and $_.text -match 'emparejado' }).Count -ge 1) $true
    $script:updates = New-Object System.Collections.ArrayList
    foreach ($x in $next) { [void]$script:updates.Add($x) }
    $script:uid = 200

    '--- arranque del demonio'
    $base = Sent-Count
    $daemon = Start-Daemon 'a'
    Check 'el demonio anuncia que esta en linea' (Wait-Sent ($base + 1) 40) $true
    Check 'aviso de arranque' (Any-Text 'Santuario en linea') $true

    $n0 = Sent-Count
    '--- desconocidos: silencio total'
    Push 999 999 'private' 'hola soy un extrano'
    Push 999 -700 'group' 'mensaje de grupo'
    Push 999 999 'private' '/estado'
    Push 999 999 'private' '/emparejar ABCD-2345'
    Start-Sleep 4
    Check 'ninguna respuesta a desconocidos' (Sent-Count) $n0

    '--- el dueno'
    Push 111 111 'private' '/estado'
    Check 'responde a /estado' (Wait-Sent ($n0 + 1)) $true; Check '/estado: texto' ((Last-Text) -match 'En linea') $true
    $n1 = Sent-Count
    Push 111 111 'private' 'hola, como estas?'
    Check 'charla con el modelo (simulado)' (Wait-Sent ($n1 + 1)) $true; Check 'charla: texto' (Last-Text) 'respuesta simulada'
    $n2 = Sent-Count
    Push 111 111 'private' ('recuerdame en 3 segundos beber agua con lim' + $oacute + 'n')
    Check 'confirma la tarea' (Wait-Sent ($n2 + 1)) $true; Check 'tarea creada: texto' ((Last-Text) -match 'Listo t1') $true
    Check 'ACENTOS: la o con tilde llega bien (UTF-8)' ((Last-Text) -match ('lim' + $oacute + 'n')) $true
    Check 'el recordatorio LLEGA por Telegram' (Wait-Sent ($n2 + 2) 30) $true; Check 'recordatorio: texto' ((Last-Text) -match 'Recordatorio: beber agua') $true
    $n3 = Sent-Count
    Push 111 111 'private' 'cada dia a las 8 busca noticias de Monterrey'
    Check 'busqueda programada desde Telegram' (Wait-Sent ($n3 + 1)) $true; Check 'queda PENDIENTE de aprobacion en el PC' ((Last-Text) -match 'PENDIENTE') $true
    $n4 = Sent-Count
    Push 111 111 'private' '/tareas'
    Check '/tareas lista' (Wait-Sent ($n4 + 1)) $true; Check '/tareas: contiene la pendiente' ((Last-Text) -match 'pendiente') $true
    $n5 = Sent-Count
    Push 111 111 'private' '/cancelar t2'
    Check 'cancelar tarea' (Wait-Sent ($n5 + 1)) $true; Check 'cancelar: texto' ((Last-Text) -match 'cancelada') $true
    $n6 = Sent-Count
    Push 111 111 'private' 'busca el clima en monterrey en google'
    Check 'busqueda remota con herramientas apagadas' (Wait-Sent ($n6 + 1)) $true; Check 'busqueda: dice que estan apagadas' ((Last-Text) -match 'apagadas') $true
    $n7 = Sent-Count
    Push 111 111 'private' 'abre youtube y pon musica'
    Check 'abrir sitios NO se hace desde Telegram (va al chat)' (Wait-Sent ($n7 + 1)) $true; Check 'respuesta es solo chat' (Last-Text) 'respuesta simulada'
    Check 'no se abrio ningun Edge del demonio' (@(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { $_.CommandLine -match ('santuario-edge-' + $daemon.Id) }).Count) 0
    $n8 = Sent-Count
    Push 111 111 'private' ('x' * 600)
    Check 'mensaje demasiado largo' (Wait-Sent ($n8 + 1)) $true; Check 'largo: aviso' ((Last-Text) -match 'demasiado largo') $true
    $n9 = Sent-Count
    Push 111 111 'private' 'texto reenviado' @{ forward_origin = @{ type = 'user' } }
    Start-Sleep 3
    Check 'reenviado: sin respuesta' (Sent-Count) $n9

    '--- pausa de emergencia'
    $n10 = Sent-Count
    Push 111 111 'private' '/stop'
    Check '/stop responde' (Wait-Sent ($n10 + 1)) $true
    Check 'se creo el archivo STOP' (Test-Path (Join-Path $tmp 'agent\STOP')) $true
    $n11 = Sent-Count
    Push 111 111 'private' 'hola otra vez'
    Check 'en pausa: no conversa' (Wait-Sent ($n11 + 1)) $true; Check 'en pausa: aviso' ((Last-Text) -match 'pausa') $true
    $n12 = Sent-Count
    Push 111 111 'private' '/reanudar'
    Check '/reanudar responde' (Wait-Sent ($n12 + 1)) $true; Check 'STOP desaparece' (-not (Test-Path (Join-Path $tmp 'agent\STOP'))) $true

    '--- segunda instancia (no debe tocar nada de la primera)'
    $second = Start-Daemon 'b'
    $null = $second.WaitForExit(30000)
    Check 'la segunda instancia sale con 0' $second.ExitCode 0
    Check 'el pid de la primera sigue ahi' (Test-Path (Join-Path $tmp 'data\agent\daemon.pid')) $true
    Check 'la primera sigue viva' (-not $daemon.HasExited) $true
    $n13 = Sent-Count
    Push 111 111 'private' '/estado'
    Check 'y sigue respondiendo' (Wait-Sent ($n13 + 1)) $true

    '--- dueno ALTERADO a mano (firma invalida): se desactiva el canal sin reiniciar'
    $ownerFile = Get-TgOwnerFile
    $orig = [IO.File]::ReadAllText($ownerFile)
    [IO.File]::WriteAllText($ownerFile, ($orig -replace '"user_id":\s*111', '"user_id": 999'), (New-Object Text.UTF8Encoding($false)))
    Start-Sleep 7
    $n14 = Sent-Count
    Push 999 111 'private' '/estado'
    Push 111 111 'private' '/estado'
    Start-Sleep 6
    Check 'dueno alterado: ni el falso ni el verdadero reciben respuesta' (Sent-Count) $n14
    [IO.File]::WriteAllText($ownerFile, $orig, (New-Object Text.UTF8Encoding($false)))      # el dueno restaura el archivo valido
    Check 'al restaurarlo: el agente se reconecta solo' (Wait-Sent ($n14 + 1) 40) $true
    Start-Sleep 3
    $n15 = Sent-Count
    Push 111 111 'private' '/estado'
    Check 'y vuelve a responder' (Wait-Sent ($n15 + 1)) $true

    '--- desvincular (borrar remote.json) surte efecto SIN reiniciar'
    Remove-Item $ownerFile -Force
    Start-Sleep 7
    $n16 = Sent-Count
    Push 111 111 'private' '/estado'
    Start-Sleep 6
    Check 'desvinculado: no responde' (Sent-Count) $n16
    [IO.File]::WriteAllText($ownerFile, $orig, (New-Object Text.UTF8Encoding($false)))

    '--- salida limpia'
    Stop-Daemon $daemon
    Check 'el demonio termina con codigo 0' $daemon.ExitCode 0
    Check 'borra su pid al salir' (-not (Test-Path (Join-Path $tmp 'data\agent\daemon.pid'))) $true

    '--- Telegram sin red al arrancar: reintenta solo'
    try { Invoke-RestMethod "$api/__stop" -TimeoutSec 3 | Out-Null } catch {}
    try { if ($mock -and -not $mock.HasExited) { Stop-Process -Id $mock.Id -Force } } catch {}
    Start-Sleep 1
    $base2 = Sent-Count
    $daemon = Start-Daemon 'c'
    Start-Sleep 9                                   # el demonio ya arranco y Telegram aun no responde
    Check 'sin red: el demonio sigue vivo' (-not $daemon.HasExited) $true
    $mock = Start-Mock
    [void](Wait-Mock)
    Check 'al volver la red: se conecta solo y anuncia que esta en linea' (Wait-Sent ($base2 + 1) 90) $true
    Stop-Daemon $daemon

    '--- politica cambiada (policy.json != lo aprobado): el canal remoto NO se activa'
    [IO.File]::WriteAllText((Join-Path $script:SecretDirOverride 'policy.sha256'), 'HUELLA-DE-OTRA-POLITICA')
    $base3 = Sent-Count
    $daemon = Start-Daemon 'd'
    Start-Sleep 10
    Push 111 111 'private' '/estado'
    Start-Sleep 7
    Check 'politica cambiada: sin conexion ni respuestas' (Sent-Count) $base3
    Stop-Daemon $daemon
    Approve-Policy

    '--- seguridad de los registros'
    $leaks = @(Get-ChildItem $tmp -Recurse -File | Where-Object { $_.FullName -notmatch '\\secret\\' } | Select-String -Pattern 'AAAbbbCCCddd' -SimpleMatch -ErrorAction SilentlyContinue)
    Check 'el token no aparece en NINGUN archivo (logs, auditoria, salida)' $leaks.Count 0
    $log = Get-ChildItem (Join-Path $tmp 'logs') -Filter 'daemon-*.log' | Select-Object -First 1
    $logText = if ($log) { Get-Content $log.FullName -Raw } else { '' }
    Check 'el registro NO guarda el contenido de los mensajes' (($logText -match 'beber agua') -or ($logText -match 'hola otra vez') -or ($logText -match 'extrano')) $false
    Check 'el registro existe' ([bool]$log) $true
    $audit = Get-ChildItem (Join-Path $tmp 'logs') -Filter 'audit-daemon-*.jsonl' | Select-Object -First 1
    Check 'auditoria del demonio existe' ([bool]$audit) $true
    $sentTexts = (Sent | ForEach-Object { [string]$_.text }) -join "`n"
    Check 'las respuestas no llevan enlaces' ($sentTexts -match 'https?://') $false
    Check 'se envia sin parse_mode (texto plano)' (@(Sent | Where-Object { $_.parse_mode }).Count) 0
    Check 'se envia sin previsualizacion de enlaces' (@(Sent | Where-Object { $_.preview_off -ne $true }).Count) 0
} catch { 'ERROR en la prueba: ' + $_.Exception.Message + ' @' + $_.InvocationInfo.ScriptLineNumber; $fail++ }
finally {
    try { if ($daemon -and -not $daemon.HasExited) { Stop-Process -Id $daemon.Id -Force } } catch {}
    try { Invoke-RestMethod "$api/__stop" -TimeoutSec 3 | Out-Null } catch {}
    try { if ($mock -and -not $mock.HasExited) { Stop-Process -Id $mock.Id -Force } } catch {}
    Start-Sleep 1
    if ($fail -gt 0) { "(salida del demonio en: $tmp)" } else { cmd /c rmdir /s /q ('"' + $tmp + '"') 2>$null }
}
"RESULTADO DEMONIO: $pass correctas, $fail con fallo"
