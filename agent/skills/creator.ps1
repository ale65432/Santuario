# Santuario - habilidad "crear archivos y carpetas": el dueno pide un archivo (texto dado por el, o redactado por el modelo local)
# y el CODIGO lo valida y lo escribe: carpeta concedida, extension permitida, nunca sobrescribe, vista previa + confirmacion escrita.
# Nada de lo creado se ejecuta jamas. PowerShell 5.1, ASCII. Solo consola. Carga: despues de files.ps1, codescan.ps1 e improve.ps1.

$script:CrExt = @('txt', 'md', 'csv', 'json', 'html', 'htm', 'css', 'js', 'py', 'ps1', 'sql', 'xml', 'yml', 'yaml', 'ini', 'log', 'toml')
$script:CrScriptExt = @{ powershell = 'ps1'; ps = 'ps1'; python = 'py'; javascript = 'js'; js = 'js'; html = 'html'; css = 'css'; sql = 'sql'; json = 'json'; markdown = 'md'; csv = 'csv' }

function Get-DefaultCreateDir {
    $d = Join-Path (Get-WorkspaceRoot) 'archivos'
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force $d | Out-Null }
    $d
}
function Test-SafeFileName([string]$name) {
    if ([string]::IsNullOrWhiteSpace($name) -or $name.Length -gt 100) { return $false }
    if ($name -match '[\\/:*?"<>|\x00-\x1F]' -or $name.EndsWith('.') -or $name.EndsWith(' ') -or $name.StartsWith('.')) { return $false }
    if ($name -match '^(?i:con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$') { return $false }
    if ($script:SkBadPathRx.IsMatch($name)) { return $false }
    $true
}
# Interpreta la peticion del dueno. Devuelve @{ kind = file|folder; name; ext; content; desc } (name puede ser ruta completa).
function Parse-CreateRequest([string]$q) {
    $n = Normalize $q
    $r = @{ kind = 'file'; name = ''; ext = ''; content = $null; desc = '' }
    if ($n -match '\b(carpeta|directorio)\b') { $r.kind = 'folder' }
    $m = [regex]::Match($q, '"([^"]+)"')
    if ($m.Success) { $r.name = $m.Groups[1].Value.Trim() }
    if (-not $r.name) { $m = [regex]::Match($q, "'([^']+)'"); if ($m.Success) { $r.name = $m.Groups[1].Value.Trim() } }
    if (-not $r.name) { $m = [regex]::Match($q, '[A-Za-z]:[\\/][^\s"<>|?*]+(?:\s+(?![A-Za-z]:)[^\s"<>|?*:]+)*?(?=\s+(?:con|que|y|para)\b|$)'); if ($m.Success) { $r.name = $m.Value.Trim() } }
    if (-not $r.name) { $m = [regex]::Match($q, '(?i)(?:llamad[oa]|de nombre|nombrad[oa]|titulad[oa])\s+([^\s,;:]+)'); if ($m.Success) { $r.name = $m.Groups[1].Value.Trim().Trim('.') } }
    if (-not $r.name -and $r.kind -eq 'folder') { $m = [regex]::Match($q, '(?i)\b(?:carpeta|directorio)\s+(?!llamad|de nombre|nombrad)([^\s,;:"]+)'); if ($m.Success) { $r.name = $m.Groups[1].Value.Trim().Trim('.') } }
    if (-not $r.name) { $m = [regex]::Match($q, '(?i)\b(?:archivo|fichero|documento|nota|script|lista|texto)\s+([\w-]+\.[A-Za-z0-9]{1,5})\b'); if ($m.Success) { $r.name = $m.Groups[1].Value } }
    if (-not $r.name) { $m = [regex]::Match($q, '(?i)\b([\w-]+\.(?:txt|md|csv|json|html|css|js|py|ps1|sql|xml|ya?ml|ini|log|toml))\b'); if ($m.Success) { $r.name = $m.Groups[1].Value } }
    foreach ($k in $script:CrScriptExt.Keys) { if ($n -match ('\b' + $k + '\b')) { $r.ext = $script:CrScriptExt[$k]; break } }
    $m = [regex]::Match($q, '(?is)\b(?:con el texto|con el contenido|con la frase|que diga|que contenga|con el siguiente texto)\s*:?\s*(.+)$')
    if ($m.Success) { $c = $m.Groups[1].Value.Trim(); if ($c.Length -ge 2 -and (($c[0] -eq '"' -and $c[-1] -eq '"') -or ($c[0] -eq "'" -and $c[-1] -eq "'"))) { $c = $c.Substring(1, $c.Length - 2) }; $r.content = $c }
    if ($r.kind -eq 'file' -and $null -eq $r.content) { $r.desc = $q.Trim() }
    $r
}
# Nombre final: si no trae extension se completa (la del pedido o .txt). Devuelve ruta absoluta candidata (aun sin validar) o $null.
function Resolve-CreateTarget($req) {
    $name = [string]$req.name
    if (-not $name) {
        $slug = Get-SafeSlug ($(if ($req.desc) { $req.desc } else { 'nuevo' }))
        if ($slug.Length -gt 30) { $slug = $slug.Substring(0, 30).Trim('-') }
        $name = if ($req.kind -eq 'folder') { $slug } else { $slug + '.' + $(if ($req.ext) { $req.ext } else { 'txt' }) }
    }
    $isAbs = ($name -match '^[A-Za-z]:[\\/]')
    if ($req.kind -eq 'file') {
        $leaf = Split-Path -Leaf $name
        if ($leaf -notmatch '\.[A-Za-z0-9]{1,5}$') { $name = $name + '.' + $(if ($req.ext) { $req.ext } else { 'txt' }) }
    }
    if ($isAbs) { return $name }
    if ($name -match '[\\/]' -or $name -match '\.\.') { return $null }          # nombre relativo: solo un nombre simple, nunca subrutas ni ..
    if (-not (Test-SafeFileName $name)) { return $null }
    Join-Path (Get-DefaultCreateDir) $name
}
# Valida un destino para CREAR: carpeta con permiso de escritura, extension permitida, no existe, no es de Santuario/sensible.
function Test-CreateTarget([string]$target, [string]$kind) {
    $full = Get-CanonPath $target
    if (-not $full) { return @{ ok = $false; reason = 'ruta invalida o no permitida' } }
    $leaf = Split-Path -Leaf $full
    if (-not (Test-SafeFileName $leaf)) { return @{ ok = $false; reason = 'nombre de archivo no permitido' } }
    if ($kind -eq 'file') {
        $ext = [IO.Path]::GetExtension($leaf).TrimStart('.').ToLowerInvariant()
        if ($script:CrExt -notcontains $ext) { return @{ ok = $false; reason = ('extension no permitida (.' + $ext + '). Permitidas: ' + ($script:CrExt -join ', ')) } }
        $v = Get-PathVerdict $full $false
        if ($v.action -eq 'sensitive') { return @{ ok = $false; reason = 'nombre reservado a secretos/credenciales' } }
    }
    $parent = Split-Path -Parent $full
    $pc = Resolve-SafePath $parent 'write'
    if (-not $pc.ok) { return @{ ok = $false; path = $full; parent = $parent; need_grant = $true; reason = $pc.reason } }
    $nv = Test-NeverOverwrite $full
    if ($nv) { return @{ ok = $false; reason = $nv } }
    if (Test-Path -LiteralPath $full) { return @{ ok = $false; reason = 'ya existe (no se sobrescribe; usa /mejorar para editar un archivo existente)' } }
    @{ ok = $true; path = $full; parent = $parent }
}
# Escribe el archivo (CreateNew: falla si aparecio mientras decidias) y verifica el hash.
function Write-NewFile([string]$full, [string]$content) {
    $bom = ([IO.Path]::GetExtension($full).ToLowerInvariant() -eq '.ps1') -and ($content -match '[^\x00-\x7F]')      # PowerShell 5.1 necesita BOM para leer UTF-8 con acentos
    $enc = New-Object Text.UTF8Encoding($bom)
    $bytes = $enc.GetPreamble() + $enc.GetBytes($content)
    $fs = $null
    try {
        $fs = New-Object IO.FileStream($full, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $fs.Write($bytes, 0, $bytes.Length)
    } catch { return @{ ok = $false; reason = ('no se pudo crear: ' + $_.Exception.Message) } }
    finally { if ($fs) { $fs.Dispose() } }
    $h1 = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash
    $h0 = (([Security.Cryptography.SHA256]::Create()).ComputeHash($bytes) | ForEach-Object { $_.ToString('X2') }) -join ''
    if ($h1 -ne $h0) { [IO.File]::Delete($full); return @{ ok = $false; reason = 'la verificacion fallo: se elimino el archivo parcial' } }
    @{ ok = $true; path = $full; bytes = $bytes.Length; hash = $h1 }
}
# Pide al modelo local el CONTENIDO del archivo. Devuelve texto o $null. El modelo no escribe nada: solo propone texto.
function Invoke-ContentModel([string]$request, [string]$ext) {
    $region = Resolve-Region $(if ($ext -in 'ps1', 'py', 'js', 'sql', 'html', 'css', 'json') { 'code' } else { 'general' }) $script:loadedRam
    if (Get-Command Use-Region -ErrorAction SilentlyContinue) { Use-Region $region }
    $sys = 'Eres un asistente que redacta el contenido de UN archivo. Responde SOLO JSON {"contenido":"..."} con el texto completo del archivo (sin explicaciones, sin bloques de codigo markdown). ' +
           'Tipo de archivo: .' + $ext + '. Escribe en el idioma de la peticion, con ortografia completa. Si es un script: comentarios breves, sin descargar nada de internet, sin borrar archivos, sin pedir privilegios, sin credenciales.'
    $schema = @{ type = 'object'; properties = @{ contenido = @{ type = 'string'; maxLength = 12000 } }; required = @('contenido') }
    $body = @{ model = $region.alias; stream = $false; think = $false; format = $schema; options = @{ temperature = 0.3; num_predict = 1500; num_ctx = 4096 }; messages = @(@{ role = 'system'; content = $sys }, @{ role = 'user'; content = $request }) } | ConvertTo-Json -Depth 8
    try {
        Write-Host ('  (redactando con ' + $region.base_name + '...)') -ForegroundColor DarkGray
        $x = Invoke-RestMethod "$Base/api/chat" -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 600
        $o = [string]$x.message.content | ConvertFrom-Json
        $c = [string]$o.contenido
        $c = ($c -replace "`r`n", "`n")
        if ($c.Trim().StartsWith('```')) { $c = ($c -replace '(?s)^\s*```[a-zA-Z0-9]*\n', '' -replace '\n```\s*$', '') }
        return $c
    } catch { return $null }
}
# Prepara la creacion (sin escribir): devuelve @{ ok; req; target; content; findings; reason }. $contentOverride permite pruebas sin modelo.
function New-CreatePlan([string]$q, $contentOverride = $null) {
    Assert-Console
    $req = Parse-CreateRequest $q
    $target = Resolve-CreateTarget $req
    if (-not $target) { return @{ ok = $false; reason = 'nombre no valido: usa un nombre simple (sin carpetas ni ..) o una ruta completa con unidad' } }
    $chk = Test-CreateTarget $target $req.kind
    $plan = @{ ok = $chk.ok; req = $req; target = $(if ($chk.path) { $chk.path } else { $target }); check = $chk; reason = $chk.reason }
    if ($req.kind -eq 'folder' -or -not $chk.ok -and -not $chk.need_grant) { return $plan }
    $content = $req.content
    if ($null -ne $contentOverride) { $content = $contentOverride }
    $plan.content = $content
    $plan
}
function Test-GeneratedContent([string]$full, [string]$content) {
    $errs = New-Object System.Collections.ArrayList
    if ($null -eq $content -or $content.Trim().Length -eq 0) { [void]$errs.Add('contenido vacio') }
    elseif ($content.Length -gt 64000) { [void]$errs.Add('contenido demasiado largo (maximo 64000 caracteres)') }
    elseif ([regex]::Matches($content, $script:InvisRx).Count -gt 0 -and [regex]::Matches($content, '[\x00-\x08\x0B\x0C\x0E-\x1F]').Count -gt 0) { [void]$errs.Add('contiene caracteres de control') }
    $lang = Get-Language (Split-Path -Leaf $full)
    $find = @()
    if ($content) {
        $ctx = @{ codeLines = 0; commentLines = 0; todo = 0; longLines = 0; regexTimeouts = 0; dup = @{} }
        $find = @(Scan-Text (Split-Path -Leaf $full) $lang $content $ctx | Where-Object { $_.id -notin 'duplicate', 'big-file', 'long-function', 'rule-capped' })
        if ($lang -eq 'powershell') { $e0 = @($find | Where-Object { $_.id -eq 'ps-syntax' }); if ($e0.Count -gt 0) { [void]$errs.Add('el script tiene errores de sintaxis de PowerShell') } }
        if ($lang -eq 'json') { try { $null = $content | ConvertFrom-Json } catch { [void]$errs.Add('el JSON no es valido') } }
        if (@($find | Where-Object { $_.sev -eq 'A' }).Count -gt 0) { [void]$errs.Add('el contenido incluye patrones peligrosos (' + ((@($find | Where-Object { $_.sev -eq 'A' } | ForEach-Object { $_.id } | Select-Object -Unique)) -join ', ') + '): no se crea') }
    }
    @{ ok = ($errs.Count -eq 0); errors = @($errs.ToArray()); findings = $find }
}
# Ejecuta el plan: valida contenido, muestra vista previa, pide confirmacion y escribe. $confirm = scriptblock para pruebas (solo con SANTUARIO_TEST=1).
function Invoke-CreatePlan($plan, [scriptblock]$preview = $null) {
    Assert-Console
    if (-not $plan.ok) { return @{ ok = $false; reason = $plan.reason } }
    $full = $plan.target
    if ($plan.req.kind -eq 'folder') {
        if (-not (Confirm-Strong ('Crear la carpeta ' + $full))) { return @{ ok = $false; reason = 'no confirmado'; declined = $true } }
        try { New-Item -ItemType Directory -Path $full -ErrorAction Stop | Out-Null } catch { return @{ ok = $false; reason = ('no se pudo crear: ' + $_.Exception.Message) } }
        Write-Audit 'crear' ('carpeta ' + $full.Substring([math]::Max(0, $full.Length - 60))) 'confirmada' 'ok' 'consola'
        return @{ ok = $true; path = $full; kind = 'folder' }
    }
    $v = Test-GeneratedContent $full $plan.content
    if (-not $v.ok) { return @{ ok = $false; reason = ($v.errors -join '; ') } }
    if ($preview) { & $preview $plan $v }
    if (-not (Confirm-Strong ('Crear el archivo ' + $full + ' (' + $plan.content.Length + ' caracteres)'))) { return @{ ok = $false; reason = 'no confirmado'; declined = $true } }
    $t2 = Test-CreateTarget $full 'file'                                      # se revalida justo antes de escribir
    if (-not $t2.ok) { return @{ ok = $false; reason = $t2.reason } }
    $w = Write-NewFile $full $plan.content
    if ($w.ok) { Write-Audit 'crear' ('archivo ' + $full.Substring([math]::Max(0, $full.Length - 60))) 'confirmada' ('bytes=' + $w.bytes) 'consola' }
    $w
}
