# Santuario - habilidad "archivos": sandbox de rutas, concesiones, inventario y lectura segura. PowerShell 5.1, solo ASCII a proposito.
# Se carga con dot-source (despues de lib.ps1 y hands.ps1). SOLO origen "consola": cada funcion publica lo comprueba.
#
# Modelo de seguridad (ver agent\PLAN-SKILLS.md):
#  - Lectura/escritura solo dentro de carpetas CONCEDIDAS por el dueno (por sesion, tras escribir un codigo; o permanentes en skills.json).
#  - Rutas canonizadas: sin "..", sin UNC/dispositivo, sin flujos alternos, sin nombres reservados, sin 8.3, sin unidades de red.
#  - NUNCA se sigue un enlace/junction (reparse point). Los secretos (lista negra) NO se leen: solo se informa de su presencia.
#  - Limites de tamano, cantidad, profundidad y tiempo. El contenido leido es DATO no confiable.

$script:SkDir = $PSScriptRoot
$script:SantRootSk = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:SkCfg = [IO.File]::ReadAllText((Join-Path $script:SkDir 'skills.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
$script:SkUtf8Strict = New-Object Text.UTF8Encoding($false, $true)
$script:SkGrants = @{ read = New-Object System.Collections.ArrayList; write = New-Object System.Collections.ArrayList }
$script:SkSensRx = @($script:SkCfg.sensitive_file_regex | ForEach-Object { New-Object Text.RegularExpressions.Regex($_, 'IgnoreCase') })
$script:SkSensAllowRx = @($script:SkCfg.sensitive_file_allow_regex | ForEach-Object { New-Object Text.RegularExpressions.Regex($_, 'IgnoreCase') })
$script:SkBinExt = @{}; foreach ($x in $script:SkCfg.binary_ext) { $script:SkBinExt[[string]$x] = $true }
$script:SkLang = @{}; foreach ($p in $script:SkCfg.languages.PSObject.Properties) { $script:SkLang[$p.Name] = [string]$p.Value }
# Ayudantes nativos (nombres largos de Windows + bucles por linea del analizador). Se compilan una vez por sesion; si no hay compilador, hay respaldo en PowerShell.
if (-not ('Win.SkFs' -as [type])) {
    try { Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'native.cs'))) -ErrorAction Stop } catch { }
}
$script:SkNative = [bool]('Win.SkScan' -as [type])

function Assert-Console {
    if ($script:Origin -ne 'consola') { throw 'Las habilidades de archivos solo se pueden usar desde la consola local.' }
}

# ------------------------------------------------------------------ rutas
$script:SkBadPathRx = New-Object Text.RegularExpressions.Regex(('[\x00-\x1F\x7F-\x9F<>"|?*' + ((@(0x200B..0x200F) + @(0x202A..0x202E) + @(0x2060..0x2069) + @(0xFEFF) | ForEach-Object { [string][char]$_ }) -join '') + ']'))
# Ruta canonica y segura, o $null si es sospechosa/invalida.
function Get-CanonPath([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return $null }
    $p = $p.Trim().Trim('"')
    if ($p.IndexOf([char]0) -ge 0) { return $null }
    if ($script:SkBadPathRx.IsMatch($p)) { return $null }                           # control, invisibles/bidi y comodines
    if ($p.StartsWith('\\') -or $p.StartsWith('//')) { return $null }               # UNC, \\?\ y \\.\
    if ($p -notmatch '^[A-Za-z]:[\\/]') { return $null }                             # solo rutas absolutas con letra de unidad
    foreach ($seg in $p.Split([char[]]@('\', '/'))) {                                           # Windows recorta punto/espacio final: sin ambiguedad
        if ($seg -ne '' -and $seg -ne '.' -and $seg -ne '..' -and ($seg.EndsWith('.') -or $seg.EndsWith(' '))) { return $null }
    }
    try { $full = [IO.Path]::GetFullPath($p) } catch { return $null }                # resuelve .. y .
    if ($full.StartsWith('\\') -or $full.Length -lt 3 -or $full[1] -ne ':') { return $null }
    $rest = $full.Substring(2)
    if ($rest.Contains(':')) { return $null }                                        # flujo de datos alterno (archivo:stream)
    foreach ($c in $rest.Split('\')) {
        if ($c -eq '') { continue }
        if ($c -match '^(?i:con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$') { return $null }   # nombres de dispositivo
        if ($c.EndsWith(' ') -or $c.EndsWith('.')) { return $null }
    }
    try { if ((New-Object IO.DriveInfo($full.Substring(0, 1))).DriveType -eq 'Network') { return $null } } catch { return $null }
    if (-not $script:SkNative -and $full -match '~\d') { return $null }              # sin el ayudante nativo no se pueden expandir nombres 8.3: se niegan (falla cerrada)
    if ($script:SkNative -and (Test-Path -LiteralPath $full)) {                      # expande nombres cortos 8.3
        $sbL = New-Object Text.StringBuilder 32768
        $n = [Win.SkFs]::GetLongPathNameW($full, $sbL, 32768)
        if ($n -gt 0 -and $n -lt 32768) { $full = $sbL.ToString() }
    }
    if ($full.Length -gt 3) { $full = $full.TrimEnd('\') }
    $full
}
function Test-UnderRoot([string]$full, [string]$root) {
    if (-not $full -or -not $root) { return $false }
    $r = $root.TrimEnd('\')
    [string]::Equals($full.TrimEnd('\'), $r, [StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase)
}
function Get-AttrSafe([string]$p) { try { return [IO.File]::GetAttributes($p) } catch { return $null } }
# Ninguna parte del camino desde la raiz hasta el destino puede ser un enlace (junction/symlink).
function Test-NoReparse([string]$root, [string]$full) {
    $a = Get-AttrSafe $root
    if ($null -ne $a -and ($a -band [IO.FileAttributes]::ReparsePoint)) { return $false }
    if (-not (Test-UnderRoot $full $root)) { return $false }
    $rel = $full.Substring($root.TrimEnd('\').Length).TrimStart('\')
    $cur = $root.TrimEnd('\')
    foreach ($seg in $rel.Split('\')) {
        if (-not $seg) { continue }
        $cur = $cur + '\' + $seg
        $a = Get-AttrSafe $cur
        if ($null -eq $a) { return $true }                                           # aun no existe (p. ej. destino por crear)
        if ($a -band [IO.FileAttributes]::ReparsePoint) { return $false }
    }
    $true
}

# ------------------------------------------------------------------ veredicto por nombre/carpeta
# action: allow | sensitive (no se lee; se informa) | noise (se omite sin ruido)
function Get-PathVerdict([string]$full, [bool]$isDir) {
    $name = [IO.Path]::GetFileName($full.TrimEnd('\'))
    $lower = $name.ToLowerInvariant()
    # la carpeta de datos de Santuario (tokens, tareas, registros) y su carpeta en el PC
    if (-not $script:SkDirs) {
        $script:SkDirs = @{ data = (Join-Path $script:SantRootSk 'data'); ws = (Join-Path $script:SantRootSk ([string]$script:SkCfg.workspace)); host = (Join-Path (Get-RealFolders).LocalAppData 'Santuario') }
    }
    $d = $script:SkDirs
    if ((Test-UnderRoot $full $d.data) -and -not (Test-UnderRoot $full $d.ws)) { return @{ action = 'sensitive'; reason = 'datos privados de Santuario' } }
    if (Test-UnderRoot $full $d.host) { return @{ action = 'sensitive'; reason = 'claves de Santuario en este PC' } }
    if ($isDir) {
        if ($script:SkCfg.sensitive_dirs -contains $lower) { return @{ action = 'sensitive'; reason = 'carpeta sensible o de sistema' } }
        if ($script:SkCfg.noise_dirs -contains $lower) { return @{ action = 'noise'; reason = 'carpeta de dependencias/compilacion' } }
        return @{ action = 'allow'; reason = '' }
    }
    foreach ($rx in $script:SkSensAllowRx) { if ($rx.IsMatch($name)) { return @{ action = 'allow'; reason = '' } } }
    foreach ($rx in $script:SkSensRx) { if ($rx.IsMatch($name)) { return @{ action = 'sensitive'; reason = 'archivo de secretos/credenciales' } } }
    @{ action = 'allow'; reason = '' }
}
# Veredicto de TODA la ruta (cada carpeta intermedia cuenta)
function Get-FullPathVerdict([string]$root, [string]$full) {
    $rel = $full.Substring($root.TrimEnd('\').Length).TrimStart('\')
    $cur = $root.TrimEnd('\')
    $parts = @($rel.Split('\') | Where-Object { $_ })
    for ($i = 0; $i -lt $parts.Count; $i++) {
        $cur = $cur + '\' + $parts[$i]
        $isDir = ($i -lt $parts.Count - 1) -or (Test-Path -LiteralPath $cur -PathType Container)
        $v = Get-PathVerdict $cur $isDir
        if ($v.action -ne 'allow') { return $v }
    }
    @{ action = 'allow'; reason = '' }
}

# ------------------------------------------------------------------ concesiones
function Get-WorkspaceRoot {
    $w = Join-Path $script:SantRootSk ([string]$script:SkCfg.workspace)
    if (-not (Test-Path -LiteralPath $w)) { New-Item -ItemType Directory -Force $w | Out-Null }
    Get-CanonPath $w
}
# Concede una carpeta (sin interaccion: lo usan las pruebas y Request-Grant tras confirmar). Devuelve la ruta canonica o $null.
function Add-SessionGrant([string]$path, [string]$kind = 'read') {
    Assert-Console
    $c = Get-CanonPath $path
    if (-not $c -or -not (Test-Path -LiteralPath $c -PathType Container)) { return $null }
    foreach ($bad in $script:SkCfg.refuse_roots) { if ($c.TrimEnd('\') -eq ([string]$bad).TrimEnd('\')) { return $null } }
    if ($c -match '^[A-Za-z]:\\?$') { return $null }                               # nunca una unidad completa
    $cur0 = $c.Substring(0, 3).TrimEnd('\'); foreach ($sg in @($c.Substring(3).Split('\') | Where-Object { $_ })) { $cur0 = $cur0 + '\' + $sg; $a0 = Get-AttrSafe $cur0; if ($null -ne $a0 -and ($a0 -band [IO.FileAttributes]::ReparsePoint)) { return $null } }     # ningun padre puede ser un enlace
    $prof = (Get-RealFolders).UserProfile
    if ($prof -and $c.TrimEnd('\') -eq $prof.TrimEnd('\')) { return $null }          # tu carpeta de usuario completa: elige una subcarpeta
    $a = Get-AttrSafe $c
    if ($null -ne $a -and ($a -band [IO.FileAttributes]::ReparsePoint)) { return $null }
    $v = Get-PathVerdict $c $true
    if ($v.action -eq 'sensitive') { return $null }
    # que ninguna carpeta del camino hasta la raiz concedida sea sensible (p. ej. C:\Users\<usuario>\AppData\...)
    $drive = $c.Substring(0, 3)
    $segs = @($c.Substring(3).Split('\') | Where-Object { $_ })
    $cur = $drive.TrimEnd('\')
    foreach ($s in $segs) { $cur = $cur + '\' + $s; if ((Get-PathVerdict $cur $true).action -eq 'sensitive') { return $null } }
    $list = $script:SkGrants[$kind]
    if (-not ($list -contains $c)) { [void]$list.Add($c) }
    if ($kind -eq 'write') { $rl = $script:SkGrants['read']; if (-not ($rl -contains $c)) { [void]$rl.Add($c) } }      # quien puede escribir una carpeta tambien puede leerla (la lista negra sigue aplicando)
    $c
}
# Concesion interactiva: el dueno escribe un codigo (como al abrir programas).
function Request-Grant([string]$path, [string]$kind = 'read') {
    Assert-Console
    $c = Get-CanonPath $path
    if (-not $c) { Write-Host '  Esa ruta no es valida o no esta permitida (UNC, flujos, nombres reservados...).' -ForegroundColor Red; return $null }
    if (-not (Test-Path -LiteralPath $c -PathType Container)) { Write-Host ('  La carpeta no existe: ' + $c) -ForegroundColor Red; return $null }
    $existing = Get-GrantFor $c $kind
    if ($existing) { return $c }                                                     # ya cubierto por una concesion: se trabaja sobre la carpeta pedida, no sobre la raiz concedida
    $what = if ($kind -eq 'write') { 'ESCRITURA (podra crear/modificar archivos, siempre con respaldo y confirmacion)' } else { 'solo LECTURA' }
    if (-not (Confirm-Action ('Dar acceso de ' + $what + ' a la carpeta ' + $c + ' durante esta sesion'))) { Write-Host '  No se concedio acceso.' -ForegroundColor DarkGray; return $null }
    $g = Add-SessionGrant $c $kind
    if (-not $g) { Write-Host '  Esa carpeta no se puede conceder (es demasiado amplia, de sistema o sensible). Elige una subcarpeta del proyecto.' -ForegroundColor Red; return $null }
    Write-Audit 'archivos' ('conceder ' + $kind + ' ' + $g) 'confirmada' 'ok' 'consola'
    $g
}
# Raiz concedida que contiene la ruta (sesion, permanentes de skills.json, y para escritura el taller), o $null.
function Get-GrantFor([string]$full, [string]$kind = 'read') {
    $roots = New-Object System.Collections.ArrayList
    foreach ($g in $script:SkGrants[$kind]) { [void]$roots.Add($g) }
    if ($kind -eq 'read') {
        foreach ($r in @($script:SkCfg.read_roots)) { $rc = Get-CanonPath ([string]$r); if ($rc) { [void]$roots.Add($rc) } }
        $ws = Get-WorkspaceRoot; if ($ws) { [void]$roots.Add($ws) }                  # el taller siempre se puede leer
    } else {
        $ws = Get-WorkspaceRoot; if ($ws) { [void]$roots.Add($ws) }
    }
    $best = $null
    foreach ($r in $roots) { if (Test-UnderRoot $full $r) { if (-not $best -or $r.Length -gt $best.Length) { $best = $r } } }
    $best
}
# Valida de punta a punta una ruta para leer/escribir. Devuelve @{ ok; path; root; reason; verdict }.
function Resolve-SafePath([string]$path, [string]$kind = 'read') {
    Assert-Console
    $full = Get-CanonPath $path
    if (-not $full) { return @{ ok = $false; reason = 'ruta invalida o no permitida' } }
    $root = Get-GrantFor $full $kind
    if (-not $root) { return @{ ok = $false; path = $full; reason = 'fuera de las carpetas concedidas' } }
    if (-not (Test-NoReparse $root $full)) { return @{ ok = $false; path = $full; root = $root; reason = 'pasa por un enlace/junction (no se siguen)' } }
    if ($full.TrimEnd('\') -ne $root.TrimEnd('\')) {
        $v = Get-FullPathVerdict $root $full
        if ($v.action -ne 'allow') { return @{ ok = $false; path = $full; root = $root; reason = $v.reason; verdict = $v.action } }
    }
    @{ ok = $true; path = $full; root = $root; reason = '' }
}

# ------------------------------------------------------------------ lectura segura
function Get-Language([string]$name) {
    $n = $name.ToLowerInvariant()
    if ($n -eq 'dockerfile' -or $n.StartsWith('dockerfile.')) { return 'docker' }
    $ext = [IO.Path]::GetExtension($n).TrimStart('.')
    if ($ext -and $script:SkLang.ContainsKey($ext)) { return $script:SkLang[$ext] }
    ''
}
function Test-BinaryBytes([byte[]]$b, [int]$n) {
    $lim = [math]::Min($n, 8000)
    if ($lim -le 0) { return $false }
    [Array]::IndexOf($b, [byte]0, 0, $lim) -ge 0
}
# Lee un archivo de TEXTO ya validado (la ruta salio de la enumeracion de una carpeta concedida). Sin comprobar rutas: uso interno.
function Read-FileCore([string]$full, [int]$maxKB) {
    $ext = [IO.Path]::GetExtension($full).TrimStart('.').ToLowerInvariant()
    if ($script:SkBinExt.ContainsKey($ext)) { return @{ ok = $false; reason = 'archivo binario (no se lee)'; path = $full } }
    $limit = [long]$maxKB * 1024
    $fs = $null
    try {
        $fs = New-Object IO.FileStream($full, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $len = $fs.Length
        $take = [int][math]::Min($len, $limit)
        $buf = New-Object byte[] $take
        $got = 0
        while ($got -lt $take) { $k = $fs.Read($buf, $got, $take - $got); if ($k -le 0) { break }; $got += $k }
    } catch { return @{ ok = $false; reason = ('no se pudo leer: ' + $_.Exception.Message); path = $full } }
    finally { if ($fs) { $fs.Dispose() } }
    $utf16 = $null
    if ($got -ge 2 -and $buf[0] -eq 0xFF -and $buf[1] -eq 0xFE) { $utf16 = [Text.Encoding]::Unicode }                # PowerShell 5.1 escribe UTF-16 con ">" y Out-File
    elseif ($got -ge 2 -and $buf[0] -eq 0xFE -and $buf[1] -eq 0xFF) { $utf16 = [Text.Encoding]::BigEndianUnicode }
    if (-not $utf16 -and (Test-BinaryBytes $buf $got)) { return @{ ok = $false; reason = 'contenido binario (no se lee)'; path = $full } }
    if ($utf16) { $text = $utf16.GetString($buf, 2, $got - 2) }
    else {
        $off = 0
        if ($got -ge 3 -and $buf[0] -eq 0xEF -and $buf[1] -eq 0xBB -and $buf[2] -eq 0xBF) { $off = 3 }
        try { $text = $script:SkUtf8Strict.GetString($buf, $off, $got - $off) } catch { $text = [Text.Encoding]::GetEncoding(28591).GetString($buf, $off, $got - $off) }
    }
    @{ ok = $true; text = $text; truncated = ($len -gt $limit); bytes = $got; path = $full; size = $len }
}
# Lee un archivo de TEXTO concedido. Devuelve @{ ok; text; truncated; bytes; reason }.
function Read-FileSafe([string]$path, [int]$maxKB = 0) {
    Assert-Console
    if ($maxKB -le 0) { $maxKB = [int]$script:SkCfg.limits.max_file_kb }
    $r = Resolve-SafePath $path 'read'
    if (-not $r.ok) { return @{ ok = $false; reason = $r.reason; path = $r.path } }
    if (-not (Test-Path -LiteralPath $r.path -PathType Leaf)) { return @{ ok = $false; reason = 'no es un archivo existente'; path = $r.path } }
    Read-FileCore $r.path $maxKB
}

# ------------------------------------------------------------------ inventario
# Recorre la carpeta concedida con limites. Devuelve archivos (rutas relativas), secretos detectados por NOMBRE (sin leerlos) y contadores.
function Get-FolderInventory([string]$path, [hashtable]$opts = @{}) {
    Assert-Console
    $r = Resolve-SafePath $path 'read'
    if (-not $r.ok) { return @{ ok = $false; reason = $r.reason } }
    if (-not (Test-Path -LiteralPath $r.path -PathType Container)) { return @{ ok = $false; reason = 'no es una carpeta' } }
    $lim = $script:SkCfg.limits
    $maxFiles = if ($opts.max_files) { [int]$opts.max_files } else { [int]$lim.max_files }
    $maxDepth = if ($opts.max_depth) { [math]::Min([int]$opts.max_depth, [int]$lim.max_depth) } else { [int]$lim.max_depth }
    $noiseNames = @{}
    $maxBytes = [long]$lim.max_total_mb * 1MB
    $budget = if ($opts.time_budget_sec) { [int]$opts.time_budget_sec } else { [int]$lim.time_budget_sec }
    $maxFileBytes = [long]$lim.max_file_kb * 1024
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $files = New-Object System.Collections.ArrayList
    $sens = New-Object System.Collections.ArrayList
    $cnt = @{ dirs = 0; skipped_noise = 0; skipped_links = 0; skipped_binary = 0; skipped_big = 0; skipped_error = 0; sensitive_dirs = 0 }
    $total = [long]0; $truncated = $false; $why = ''
    $rootLen = $r.path.TrimEnd('\').Length
    $stack = New-Object System.Collections.Stack
    $stack.Push(@($r.path, 0))
    while ($stack.Count -gt 0) {
        if ($sw.Elapsed.TotalSeconds -gt $budget) { $truncated = $true; $why = 'tiempo'; break }
        $item = $stack.Pop(); $dir = [string]$item[0]; $depth = [int]$item[1]
        $cnt.dirs++
        try { $entries = (New-Object IO.DirectoryInfo($dir)).EnumerateFileSystemInfos() } catch { $cnt.skipped_error++; continue }
        try {
            foreach ($e in $entries) {
                if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { $cnt.skipped_links++; continue }              # no se siguen enlaces
                $isDir = [bool]($e.Attributes -band [IO.FileAttributes]::Directory)
                $v = Get-PathVerdict $e.FullName $isDir
                if ($v.action -eq 'noise') { $cnt.skipped_noise++; if ($isDir -and $noiseNames.Count -lt 30) { $noiseNames[$e.Name.ToLowerInvariant()] = $true }; continue }
                if ($v.action -eq 'sensitive') {
                    if ($isDir) { $cnt.sensitive_dirs++ }
                    [void]$sens.Add(@{ rel = $e.FullName.Substring($rootLen).TrimStart('\'); reason = $v.reason; dir = $isDir }); continue
                }
                if ($isDir) { if ($depth -lt $maxDepth) { $stack.Push(@($e.FullName, ($depth + 1))) } else { $truncated = $true; $why = 'profundidad' }; continue }
                $ext = $e.Extension.TrimStart('.').ToLowerInvariant()
                if ($script:SkBinExt.ContainsKey($ext)) { $cnt.skipped_binary++; continue }
                if ($e.Length -gt $maxFileBytes) { $cnt.skipped_big++; continue }
                if ($files.Count -ge $maxFiles) { $truncated = $true; $why = 'cantidad de archivos'; break }
                $total += $e.Length
                if ($total -gt $maxBytes) { $truncated = $true; $why = 'tamano total'; break }
                [void]$files.Add(@{ rel = $e.FullName.Substring($rootLen).TrimStart('\'); full = $e.FullName; size = [long]$e.Length; ext = $ext; lang = (Get-Language $e.Name) })
            }
        } catch { $cnt.skipped_error++ }
        if ($truncated -and $why -ne 'profundidad') { break }
    }
    $sw.Stop()
    @{ ok = $true; root = $r.path; files = @($files.ToArray()); sensitive = @($sens.ToArray()); counts = $cnt; noise_names = @($noiseNames.Keys); truncated = $truncated; truncated_by = $why; bytes = $total; elapsed_ms = [int]$sw.ElapsedMilliseconds }
}
