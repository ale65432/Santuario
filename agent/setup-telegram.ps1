# Santuario - configura Telegram: guarda el token CIFRADO (DPAPI, en tu PC, no en la USB) y empareja al dueno con un codigo.
# Solo ASCII a proposito. Lo ejecuta Configurar-Telegram.bat. El token NO se muestra, no se registra y no se pasa por argumentos.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$AppDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'app'
. (Join-Path $AppDir 'lib.ps1')
. (Join-Path $PSScriptRoot 'hands.ps1')
. (Join-Path $PSScriptRoot 'tasks.ps1')
. (Join-Path $PSScriptRoot 'telegram.ps1')

Write-Host ''
Write-Host '  CONFIGURAR TELEGRAM PARA SANTUARIO' -ForegroundColor Cyan
Write-Host '  ----------------------------------' -ForegroundColor DarkGray
Write-Host '  1) En Telegram abre @BotFather, envia /newbot y sigue los pasos. Te dara un TOKEN.'
Write-Host '  2) Pega el token aqui (no se vera en pantalla). Se guarda cifrado en ESTE PC (no en la USB).'
Write-Host '  3) Te mostrare un codigo; envialo a tu bot como:  /emparejar CODIGO'
Write-Host '  Solo tu cuenta quedara autorizada. Cualquier otra persona es ignorada en silencio.' -ForegroundColor DarkGray
Write-Host '  Este paso usa internet (api.telegram.org). El modelo local sigue sin internet.' -ForegroundColor DarkGray
Write-Host ''

# Si el agente esta corriendo, ambos hacen getUpdates a la vez y pueden "robarse" el mensaje de emparejamiento: se pide cerrarlo primero.
$pidFile = Join-Path $script:TaskDir 'daemon.pid'
if (Test-Path $pidFile) {
    try {
        $dp = [int](([IO.File]::ReadAllText($pidFile)).Trim())
        $dw = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $dp) -ErrorAction SilentlyContinue
        if ($dw -and $dw.CommandLine -match 'daemon\.ps1') {
            Write-Host '  El agente (Santuario-Agente.bat) esta corriendo. Cierra su ventana y vuelve a ejecutar este script.' -ForegroundColor Red
            return
        }
    } catch {}
}

try {
    if (Test-TgToken) {
        $a = Read-Host '  Ya hay un token guardado. Lo reemplazo? (s/n)'
        $replace = ($a -and $a.Trim().ToLowerInvariant() -in 's', 'si', 'y', 'yes')
    } else { $replace = $true }
    if ($replace) {
        $sec = Read-Host '  Pega el token del bot' -AsSecureString
        if ($sec.Length -lt 20) { throw 'Eso no parece un token de Telegram.' }
        Save-TgToken $sec
        $sec = $null
    }
    $me = Invoke-Tg 'getMe'
    Write-Host ('  Bot verificado: @' + $me.username) -ForegroundColor Green
    [void](Invoke-Tg 'deleteWebhook' @{ drop_pending_updates = $false })
    Write-Host ''
    Write-Host '  Recomendado en BotFather para este bot: /setjoingroups -> Disable   y   /setprivacy -> Enable' -ForegroundColor DarkYellow
    $code = New-PairCode
    Write-Host ''
    Write-Host ('  Abre Telegram, entra a @' + $me.username + ' y envia exactamente:') -ForegroundColor White
    Write-Host ('      /emparejar ' + $code) -ForegroundColor Yellow
    Write-Host '  (el codigo vale 10 minutos y se muestra solo aqui)' -ForegroundColor DarkGray
    Write-Host ''
    $r = Wait-TgPairing $code 10
    if ($r.ok) {
        Write-Host '  EMPAREJADO. Ahora ejecuta Santuario-Agente.bat para dejar el agente corriendo.' -ForegroundColor Green
        Write-Audit 'telegram' 'emparejar' 'confirmada' 'dueno emparejado' 'consola'
    } else {
        Write-Host ('  No se emparejo: ' + $r.error + '. Vuelve a ejecutar este script.') -ForegroundColor Red
    }
} catch {
    Write-Host ('  ERROR: ' + (Redact-Secrets $_.Exception.Message)) -ForegroundColor Red
}
