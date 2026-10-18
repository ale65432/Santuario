# Servidor FALSO de la Bot API de Telegram, solo para pruebas locales (127.0.0.1). ASCII a proposito.
# Estado en archivos de -Dir: updates.json (lo escribe la prueba), sent.jsonl (lo que el bot envio), calls.txt (metodos llamados).
param([int]$Port, [string]$Dir, [string]$Token)
$l = New-Object System.Net.HttpListener
$l.Prefixes.Add("http://127.0.0.1:$Port/")
$l.Start()
function Reply($ctx, $obj, [int]$code = 200) {
    $json = $obj | ConvertTo-Json -Depth 8 -Compress
    $b = [Text.Encoding]::UTF8.GetBytes($json)
    $ctx.Response.StatusCode = $code; $ctx.Response.ContentType = 'application/json'
    $ctx.Response.OutputStream.Write($b, 0, $b.Length); $ctx.Response.Close()
}
while ($l.IsListening) {
    $ctx = $l.GetContext()
    try {
        $path = $ctx.Request.Url.AbsolutePath
        if ($path -eq '/__stop') { Reply $ctx @{ ok = $true }; $l.Stop(); break }
        $body = (New-Object IO.StreamReader($ctx.Request.InputStream, [Text.Encoding]::UTF8)).ReadToEnd()
        $req = if ($body) { $body | ConvertFrom-Json } else { $null }
        $m = [regex]::Match($path, '^/bot([^/]+)/(\w+)$')
        if (-not $m.Success -or $m.Groups[1].Value -ne $Token) { Reply $ctx @{ ok = $false; error_code = 401; description = 'Unauthorized' } 401; continue }
        $method = $m.Groups[2].Value
        [IO.File]::AppendAllText((Join-Path $Dir 'calls.txt'), $method + "`r`n")
        switch ($method) {
            'getMe' { Reply $ctx @{ ok = $true; result = @{ id = 1; is_bot = $true; username = 'santuario_test_bot' } } }
            'deleteWebhook' { Reply $ctx @{ ok = $true; result = $true } }
            'sendMessage' {
                $line = (@{ chat_id = $req.chat_id; text = $req.text; preview_off = $req.disable_web_page_preview; parse_mode = $req.parse_mode } | ConvertTo-Json -Compress)
                [IO.File]::AppendAllText((Join-Path $Dir 'sent.jsonl'), $line + "`r`n", (New-Object Text.UTF8Encoding($false)))
                Reply $ctx @{ ok = $true; result = @{ message_id = 1 } }
            }
            'getUpdates' {
                $all = @()
                $f = Join-Path $Dir 'updates.json'
                if (Test-Path $f) { try { $parsed = ConvertFrom-Json ([IO.File]::ReadAllText($f, [Text.Encoding]::UTF8)); foreach ($x in @($parsed)) { foreach ($y in @($x)) { if ($y) { $all += $y } } } } catch {} }
                $off = [long]$req.offset
                $sel = if ($off -eq -1) { @($all | Select-Object -Last 1) } else { @($all | Where-Object { [long]$_.update_id -ge $off }) }
                if ($sel.Count -eq 0) { Start-Sleep -Milliseconds 400 }
                Reply $ctx @{ ok = $true; result = @($sel) }
            }
            default { Reply $ctx @{ ok = $false; error_code = 404; description = 'Not Found' } 404 }
        }
    } catch { try { $ctx.Response.Abort() } catch {} }
}
