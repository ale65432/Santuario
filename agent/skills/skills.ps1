# Santuario - capa de consola de las habilidades del taller: comandos (/taller, /leer, /analizar, /escanear, /mejorar, /deshacer, /web, /skills)
# y frases en lenguaje natural. Todo SOLO desde la consola local. PowerShell 5.1, ASCII.
# Carga (en santuario.ps1): despues de lib.ps1, hands.ps1 y console-agent.ps1.

$script:SkillsDir = $PSScriptRoot
. (Join-Path $PSScriptRoot 'files.ps1')
. (Join-Path $PSScriptRoot 'codescan.ps1')
. (Join-Path $PSScriptRoot 'pcscan.ps1')
. (Join-Path $PSScriptRoot 'webgen.ps1')
. (Join-Path $PSScriptRoot 'improve.ps1')
. (Join-Path $PSScriptRoot 'creator.ps1')

$script:SkillList = @(
    @{ name = 'leer'; cmd = '/leer <ruta>'; desc = 'Muestra un archivo de texto de tu PC (con secretos tapados). Pide permiso para la carpeta.' }
    @{ name = 'analizar'; cmd = '/analizar <carpeta> [explicar]'; desc = 'Revisa el codigo de una carpeta: secretos, patrones peligrosos, errores, metricas. Informe en pantalla y opcional en archivo.' }
    @{ name = 'escanear'; cmd = '/escanear'; desc = 'Revisa la seguridad de ESTE PC (solo lectura): antivirus, firewall, RDP, cuentas, inicio, tareas...' }
    @{ name = 'mejorar'; cmd = '/mejorar <archivo>'; desc = 'Arregla problemas del archivo: cambios mostrados como diff, con respaldo y confirmacion escrita.' }
    @{ name = 'deshacer'; cmd = '/deshacer'; desc = 'Restaura el ultimo archivo modificado por /mejorar desde su respaldo.' }
    @{ name = 'crear'; cmd = '/crear <archivo o carpeta>'; desc = 'Crea un archivo (texto tuyo o redactado por el modelo) o una carpeta. Nunca sobrescribe ni ejecuta nada.' }
    @{ name = 'web'; cmd = '/web <lo que quieres>'; desc = 'Crea una pagina web con tus especificaciones (HTML+CSS accesibles, sin scripts ni recursos externos).' }
)

function Show-SkillsHelp {
    Write-Host ''
    Write-Host '  Habilidades del taller (solo en esta consola; piden permiso para cada carpeta):' -ForegroundColor Cyan
    foreach ($s in $script:SkillList) { Write-Host ('  {0,-34} {1}' -f $s.cmd, $s.desc) -ForegroundColor Gray }
    Write-Host '  Tambien en lenguaje natural: "analiza el codigo de la carpeta C:\proyecto", "revisa la seguridad de mi pc",' -ForegroundColor DarkGray
    Write-Host '  "mejora el codigo de C:\proyecto\app.js", "crea un archivo notas.txt con el texto ...", "crea una pagina web para mi cafeteria".' -ForegroundColor DarkGray
    Write-Host ('  Taller (informes, sitios, respaldos): ' + (Get-WorkspaceRoot)) -ForegroundColor DarkGray
    Write-Host ''
}

# ------------------------------------------------------------------ rutas dichas por el dueno
function Get-KnownFolder([string]$word) {
    $rf = Get-RealFolders
    switch -Regex ($word) {
        '^(escritorio|desktop)$' { $p = [Environment]::GetFolderPath('Desktop'); if (-not $p -or $p.StartsWith($script:SantRoot, 'OrdinalIgnoreCase')) { $p = Join-Path $rf.UserProfile 'Desktop' }; return $p }
        '^(documentos|documents|mis documentos)$' { $p = [Environment]::GetFolderPath('MyDocuments'); if (-not $p -or $p.StartsWith($script:SantRoot, 'OrdinalIgnoreCase')) { $p = Join-Path $rf.UserProfile 'Documents' }; return $p }
        '^(descargas|downloads)$' { return (Join-Path $rf.UserProfile 'Downloads') }
    }
    $null
}
function Extract-PathArg([string]$q) {
    $m = [regex]::Match($q, '"([^"]+)"')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    $m = [regex]::Match($q, "'([A-Za-z]:[^']+)'")
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    $m = [regex]::Match($q, '[A-Za-z]:[\\/].*$')
    if ($m.Success) { return ($m.Value.Trim().TrimEnd('.', ',', ';', '?', '!')) }
    $n = Normalize $q
    $m = [regex]::Match($n, '\b(escritorio|desktop|documentos|documents|descargas|downloads)\b')
    if ($m.Success) { return (Get-KnownFolder $m.Groups[1].Value) }
    ''
}
function Ask-PathIfMissing([string]$p, [string]$what) {
    if ($p) { return $p }
    $a = Read-Host ('  ' + $what + ' (ruta completa, Enter cancela)')
    if ([string]::IsNullOrWhiteSpace($a)) { return '' }
    $a.Trim().Trim('"')
}

# ------------------------------------------------------------------ reconocimiento de frases
# Devuelve @{ skill; arg } o $null. Solo frases claras: con un verbo de accion y un objeto (codigo/carpeta/pc/pagina).
function Parse-SkillIntent([string]$q) {
    if ([string]::IsNullOrWhiteSpace($q) -or $q.Length -gt 600) { return $null }
    $n = Normalize $q
    if ($n -match '^(abre|abrir|abreme|reproduce|pon |ponme|busca |investiga)') { return $null }
    if ($n -match '^(revisa|escanea|analiza|audita|chequea|checa|verifica|haz|hazme|hacer|ejecuta)\b.{0,40}\b(seguridad|vulnerabilidades|postura)\b.{0,40}\b(pc|computadora|compu|equipo|laptop|sistema|windows|maquina)\b' -or
        $n -match '^(escaneo|revision|auditoria|chequeo) de seguridad( de (mi|este) (pc|computadora|compu|equipo|laptop))?$' -or
        $n -match '^(esta seguro|esta protegido) (mi|este) (pc|computadora|compu|equipo|laptop)') { return @{ skill = 'escanear'; arg = '' } }
    if ($q.Contains("`n") -or $q.Contains("`r") -or ([regex]::Matches($q, '[{};=<>]').Count -ge 3)) { return $null }       # codigo pegado: lo atiende el modelo, no el taller
    if ($n -match '^(crea|crear|creame|genera|generame|escribe|escribeme|haz|hazme|redacta|redactame)\s+(me\s+)?(un|una|el|la)\s+(nuevo\s+|nueva\s+)?(archivo|documento|fichero|script|carpeta|directorio|nota|lista|texto)\b' -and $n -notmatch '\b(pagina web|sitio web|landing)\b') { return @{ skill = 'crear'; arg = $q.Trim() } }
    if ($n -notmatch '\b(resumen|resume|resumeme|explica|explicame|que es|como funciona|opinion|critica|compara)\b' -and
        ($n -match '^(crea|crear|creame|genera|generame|disena|disename|construye|construyeme|armame|haz|hazme)\s+(me\s+)?(una?\s+)?(nueva\s+)?(pagina web|sitio web|pagina|landing page|landing|sitio)\b' -or
         $n -match '^(quiero|necesito)\s+(una?\s+)(nueva\s+)?(pagina web|sitio web|landing page|landing)\b') -and
        $n -match '\b(de|para|con|sobre|que)\b') { return @{ skill = 'web'; arg = $q.Trim() } }
    if ($n -match '^(mejora|mejorame|optimiza|corrige|arregla|refactoriza)\b.{0,40}\b(codigo|archivo|script|programa)\b') { return @{ skill = 'mejorar'; arg = (Extract-PathArg $q) } }
    if ($n -match '^(analiza|analizame|revisa|revisame|escanea|escaneame|audita|checa)\b.{0,40}\b(codigo|proyecto|carpeta|archivos|repositorio|repo|programa)\b') { return @{ skill = 'analizar'; arg = (Extract-PathArg $q); explain = ($n -match '\b(explica|explicame|explicalo)\b') } }
    if ($n -match '^(lee|leeme|muestra|muestrame|ensename)\b.{0,25}\b(archivo|documento|fichero)\b') { return @{ skill = 'leer'; arg = (Extract-PathArg $q) } }
    $null
}
function Test-SkillIntent([string]$q) { [bool](Parse-SkillIntent $q) }

# ------------------------------------------------------------------ acciones
function Do-ReadFile([string]$path) {
    $path = Ask-PathIfMissing $path 'Archivo a leer'
    if (-not $path) { return }
    $c = Get-CanonPath $path
    if (-not $c) { Write-Host '  Ruta no valida o no permitida.' -ForegroundColor Red; return }
    $parent = Split-Path -Parent $c
    $g = Get-GrantFor $c 'read'
    if (-not $g) { $g = Request-Grant $parent 'read'; if (-not $g) { return } }
    $r = Read-FileSafe $c
    if (-not $r.ok) { Write-Host ('  No se puede leer: ' + $r.reason) -ForegroundColor Yellow; Write-Audit 'leer' $c 'bloqueada' $r.reason 'consola'; return }
    Write-Audit 'leer' $c 'auto' ('bytes=' + $r.bytes) 'consola'
    $lines = (Mask-Text $r.text) -split "`r?`n"
    $max = 150; $i = 0
    Write-Host ('  --- ' + $r.path + '  (' + $r.size + ' bytes' + $(if ($r.truncated) { ', truncado' } else { '' }) + ') ---') -ForegroundColor Cyan
    foreach ($l in $lines) { if ($i -ge $max) { Write-Host ('  ... (' + ($lines.Count - $max) + ' lineas mas)') -ForegroundColor DarkGray; break }; $i++; Write-Host ('  {0,4}  {1}' -f $i, (Strip-Terminal $l)) }
    Write-Host '  (los secretos reconocibles se muestran tapados)' -ForegroundColor DarkGray
}
function Explain-Findings($res, [int]$max = 5) {
    $items = @($res.findings | Where-Object { -not $_.secret -and $_.id -notin 'sensitive-file', 'duplicate' } | Select-Object -First $max)
    if ($items.Count -eq 0) { Write-Host '  (no hay hallazgos que explicar)' -ForegroundColor DarkGray; return }
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create(); $rb = New-Object byte[] 12; $rng.GetBytes($rb); $id = ($rb | ForEach-Object { $_.ToString('x2') }) -join ''
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine('<<DATOS ' + $id + '>>')
    $i = 0
    foreach ($f in $items) { $i++; [void]$sb.AppendLine(('{0}. [{1}] {2} (archivo {3}, linea {4}) codigo: {5}' -f $i, $f.id, $f.msg, $f.file, $f.line, ($f.snippet -replace '<<|>>', ''))) }
    [void]$sb.AppendLine('<<FIN ' + $id + '>>')
    $body = ($sb.ToString()).Replace($id + $id, '')
    $sys = [IO.File]::ReadAllText((Join-Path $script:SkillsDir 'prompts\explain-findings.txt'), [Text.Encoding]::UTF8)
    $region = Resolve-Region 'general' $script:loadedRam
    Use-Region $region
    try {
        Write-Host ('  (explicando con ' + $region.base_name + '...)') -ForegroundColor DarkGray
        $ans = Ask-Model $region.alias @(@{ role = 'system'; content = $sys }, @{ role = 'user'; content = $body }) 600 0.2 600
        $ans = Strip-Terminal $ans; if ($ans.Length -gt 2500) { $ans = $ans.Substring(0, 2500) + '...' }
        Write-Host ''; Write-Host '  Explicacion del modelo (orientativa; los hallazgos los detecto el analizador):' -ForegroundColor Cyan
        foreach ($l in ($ans -split "`r?`n")) { Write-Host ('  ' + $l) }
    } catch { Write-Host '  (el modelo no respondio; el informe de arriba sigue siendo valido)' -ForegroundColor DarkYellow }
}
function Do-Analyze([string]$path, [bool]$explain) {
    $path = Ask-PathIfMissing $path 'Carpeta a analizar'
    if (-not $path) { return }
    $g = Request-Grant $path 'read'
    if (-not $g) { return }
    Write-Host '  Analizando (solo lectura)...' -ForegroundColor DarkGray
    $res = Invoke-CodeScan $g
    Write-Audit 'analizar' $g 'auto' ('archivos=' + $res.scanned + ' A=' + $res.counts.A + ' M=' + $res.counts.M + ' B=' + $res.counts.B + ' ms=' + $res.elapsed_ms) 'consola'
    foreach ($l in (Format-ScanReport $res 40)) { $col = if ($l -match '^\[ALTO') { 'Red' } elseif ($l -match '^\[MEDIO') { 'Yellow' } else { 'Gray' }; Write-Host ('  ' + $l) -ForegroundColor $col }
    if ($res.ok -and $res.findings.Count -gt 0) {
        $a = Read-Host '  Guardar el informe completo en el taller? (s/N)'
        if ($a -match '^(s|si|y|yes)$') {
            Write-Host '  Aviso: el informe contiene rutas de tu PC; los secretos NO se guardan, solo su tipo y longitud.' -ForegroundColor DarkYellow
            $f = Save-ScanReport $res; Write-Host ('  Guardado: ' + $f) -ForegroundColor Cyan
        }
    }
    if ($explain -and $res.ok) { Explain-Findings $res }
    elseif ($res.ok -and $res.findings.Count -gt 0) { Write-Host '  Tip: /analizar <carpeta> explicar  -> el modelo explica los primeros hallazgos.' -ForegroundColor DarkGray }
}
function Do-PcScan {
    Write-Host '  Revisando este PC (solo lectura, no se cambia nada)...' -ForegroundColor DarkGray
    $res = Invoke-PcScan
    Write-Audit 'escanear' 'pc' 'auto' ('alto=' + $res.counts.alto + ' aviso=' + $res.counts.aviso + ' ms=' + $res.elapsed_ms) 'consola'
    foreach ($l in (Format-PcReport $res)) { $col = if ($l -match '^\[ALTO') { 'Red' } elseif ($l -match '^\[AVISO') { 'Yellow' } elseif ($l -match '^\[OK') { 'Green' } else { 'Gray' }; Write-Host ('  ' + $l) -ForegroundColor $col }
    Write-Host '  Solo se revisa ESTE equipo. Escanear otras maquinas o redes no esta incluido.' -ForegroundColor DarkGray
}
function Show-ChangeSet($cs) {
    Write-Host ''
    Write-Host ('  Archivo: ' + $cs.path) -ForegroundColor Cyan
    Write-Host ('  Cambio:  ' + $cs.desc) -ForegroundColor Cyan
    foreach ($l in $cs.diff.lines) { $col = if ($l.StartsWith('+')) { 'Green' } elseif ($l.StartsWith('-')) { 'Red' } else { 'DarkGray' }; Write-Host ('  ' + $l) -ForegroundColor $col }
    Write-Host ('  (+' + $cs.diff.added + ' / -' + $cs.diff.removed + ' lineas)') -ForegroundColor DarkGray
}
function Do-Improve([string]$path) {
    $path = Ask-PathIfMissing $path 'Archivo a mejorar'
    if (-not $path) { return }
    $c = Get-CanonPath $path
    if (-not $c -or -not (Test-Path -LiteralPath $c -PathType Leaf)) { Write-Host '  No es un archivo valido.' -ForegroundColor Red; return }
    $nv = Test-NeverOverwrite $c
    if ($nv) { Write-Host ('  No se puede modificar este archivo: ' + $nv) -ForegroundColor Red; return }
    $parent = Split-Path -Parent $c
    $gr = Request-Grant $parent 'read'; if (-not $gr) { return }
    $gw = Request-Grant $parent 'write'; if (-not $gw) { Write-Host '  Sin permiso de escritura solo puedo mostrarte los problemas.' -ForegroundColor DarkYellow }
    $ed = Read-Editable $c
    if (-not $ed.ok) { Write-Host ('  No se puede editar: ' + $ed.reason) -ForegroundColor Yellow; return }
    $lang = Get-Language (Split-Path -Leaf $c)
    $rescan = { param($fp) $e2 = Read-Editable $fp; if (-not $e2.ok) { return @() }; $cx = @{ codeLines = 0; commentLines = 0; todo = 0; longLines = 0; regexTimeouts = 0; dup = @{} }; @(Scan-Text (Split-Path -Leaf $fp) $lang $e2.text $cx) }
    $f = & $rescan $c
    if ($f.Count -eq 0) { Write-Host '  No encontre problemas que mejorar en este archivo.' -ForegroundColor Green; return }
    Write-Host ('  Hallazgos en ' + (Split-Path -Leaf $c) + ':') -ForegroundColor Cyan
    $i = 0; foreach ($x in $f) { $i++; $loc = if ($x.line -gt 0) { 'linea ' + $x.line } else { 'archivo' }; $extra = if ($x.secret) { '  ' + $x.masked } else { '' }; Write-Host ('  {0,2}. [{1}] {2}: {3}{4}' -f $i, $x.sev, $loc, $x.msg, $extra) }
    if (-not $gw) { return }
    $opts = Get-AutoFixOptions $c
    if ($opts.ok -and $opts.options.Count -gt 0) {
        Write-Host '  Arreglos automaticos disponibles:' -ForegroundColor Cyan
        foreach ($o in $opts.options) { Write-Host ('   - ' + $o.desc) }
        $cs = Invoke-AutoFix $c
        if ($cs.ok) {
            Show-ChangeSet $cs; $r = Apply-ChangeSet $cs; Show-ApplyResult $r
            if ($r.ok) {
                $f = & $rescan $c
                if ($f.Count -eq 0) { Write-Host '  Ya no quedan hallazgos.' -ForegroundColor Green; return }
                Write-Host '  Hallazgos que quedan (numeracion nueva):' -ForegroundColor Cyan
                $i = 0; foreach ($x in $f) { $i++; $loc = if ($x.line -gt 0) { 'linea ' + $x.line } else { 'archivo' }; $extra = if ($x.secret) { '  ' + $x.masked } else { '' }; Write-Host ('  {0,2}. [{1}] {2}: {3}{4}' -f $i, $x.sev, $loc, $x.msg, $extra) }
            }
        }
        else { Write-Host ('  No se pudo preparar: ' + ($cs.errors -join '; ')) -ForegroundColor Yellow }
    }
    $a = Read-Host '  Numero de un hallazgo para pedirle al modelo una propuesta (Enter = terminar)'
    if ($a -match '^\d+$' -and [int]$a -ge 1 -and [int]$a -le $f.Count) {
        $x = $f[[int]$a - 1]
        if ($x.secret) { Write-Host '  Los secretos no se mandan al modelo: rotalos y sacalos del codigo a mano.' -ForegroundColor Yellow; return }
        if ($x.line -lt 1) { Write-Host '  Ese hallazgo es del archivo completo; arreglalo a mano o con un arreglo automatico.' -ForegroundColor Yellow; return }
        $cs = Invoke-LlmFix $c $x.line $x.id
        if (-not $cs.ok) { Write-Host ('  La propuesta no es valida: ' + ($cs.errors -join '; ')) -ForegroundColor Yellow; return }
        Show-ChangeSet $cs; $r = Apply-ChangeSet $cs; Show-ApplyResult $r
    }
}
function Show-ApplyResult($r) {
    if ($r.ok) { Write-Host ('  Listo. Respaldo: ' + $r.backup) -ForegroundColor Green; Write-Host '  Para volver atras: /deshacer' -ForegroundColor DarkGray }
    elseif ($r.declined) { Write-Host '  No se aprobo: el archivo sigue igual.' -ForegroundColor DarkGray }
    else { Write-Host ('  No se aplico: ' + $r.reason) -ForegroundColor Yellow }
}
function Do-Create([string]$q) {
    if ([string]::IsNullOrWhiteSpace($q)) { $q = Read-Host '  Que quieres crear? (ej: un archivo notas.txt con el texto hola | un script de powershell que liste mis descargas | carpeta Proyectos)'; if ([string]::IsNullOrWhiteSpace($q)) { return } }
    $plan = New-CreatePlan $q
    if (-not $plan.ok -and $plan.check -and $plan.check.need_grant) {
        $g = Request-Grant $plan.check.parent 'write'
        if (-not $g) { return }
        $plan = New-CreatePlan $q
    }
    if (-not $plan.ok) { Write-Host ('  No se puede crear: ' + $plan.reason) -ForegroundColor Yellow; return }
    if ($plan.req.kind -eq 'file' -and $null -eq $plan.content) {
        $ext = [IO.Path]::GetExtension($plan.target).TrimStart('.').ToLowerInvariant()
        $plan.content = Invoke-ContentModel $plan.req.desc $ext
        if ($null -eq $plan.content) { Write-Host '  El modelo no respondio. Puedes darme el texto tu mismo: /crear nombre.txt con el texto ...' -ForegroundColor Yellow; return }
    }
    $prev = {
        param($pl, $v)
        Write-Host ('  Archivo: ' + $pl.target) -ForegroundColor Cyan
        $i = 0
        foreach ($l in ((Mask-Text $pl.content) -split "`n")) { if ($i -ge 40) { Write-Host '  ... (el resto no se muestra)' -ForegroundColor DarkGray; break }; $i++; Write-Host ('  {0,3}  {1}' -f $i, (Show-Safe $l)) }
        foreach ($f in @($v.findings | Where-Object { $_.sev -in 'M' } | Select-Object -First 5)) { Write-Host ('  aviso: ' + $f.msg + ' (linea ' + $f.line + ')') -ForegroundColor Yellow }
    }
    $res = Invoke-CreatePlan $plan $prev
    if ($res.ok) { Write-Host ('  Creado: ' + $res.path) -ForegroundColor Green; Write-Host '  (Santuario nunca ejecuta lo que crea.)' -ForegroundColor DarkGray }
    elseif ($res.declined) { Write-Host '  No se aprobo: no se creo nada.' -ForegroundColor DarkGray }
    else { Write-Host ('  No se creo: ' + $res.reason) -ForegroundColor Yellow }
}
function Do-Web([string]$request, [bool]$confirm = $false) {
    if ($confirm) {
        $a0 = Read-Host ('  Crear una pagina web con esto? (el modelo local propone la estructura; se guarda en el taller)  [s/N]')
        if ($a0 -notmatch '^(s|si|y|yes)$') { Write-Host '  Entendido, no la creo. Si era otra cosa, vuelve a escribirlo.' -ForegroundColor DarkGray; return }
    }
    if ([string]::IsNullOrWhiteSpace($request)) { $request = Read-Host '  Describe la pagina (tipo, nombre, secciones, colores, textos...)'; if ([string]::IsNullOrWhiteSpace($request)) { return } }
    Write-Host '  Disenando (el modelo solo propone la estructura; el HTML/CSS lo genera el codigo)...' -ForegroundColor DarkGray
    $res = Invoke-WebBuild $request
    if (-not $res.ok) { Write-Host ('  No se pudo crear: ' + $res.reason) -ForegroundColor Red; foreach ($e in @($res.errors)) { Write-Host ('   - ' + $e) -ForegroundColor Yellow }; return }
    Write-Audit 'web' $res.dir 'auto' ('origen=' + $res.source + ' bytes=' + $res.bytes) 'consola'
    Write-Host ('  Listo (' + $res.source + '): ' + $res.dir) -ForegroundColor Green
    Write-Host ('  Archivos: ' + ($res.files -join ', ') + '   Tipo: ' + $res.spec.tipo_sitio + '   Paleta: ' + $res.spec.paleta + '   Secciones: ' + $res.spec.secciones.Count) -ForegroundColor Gray
    foreach ($w in @($res.warnings)) { Write-Host ('  aviso: ' + $w) -ForegroundColor DarkYellow }
    Write-Host '  Sin scripts, sin recursos externos, contraste AA, modo claro/oscuro. Para cambiar algo, vuelve a pedirlo con mas detalle.' -ForegroundColor DarkGray
    $a = Read-Host '  Abrir la vista previa en Edge? (s/N)'
    if ($a -match '^(s|si|y|yes)$') { [void](Open-SitePreview $res.dir) }
}

# ------------------------------------------------------------------ despacho
# Comandos con barra. Devuelve $true si lo atendio.
function Handle-SkillCommand([string]$t, [string]$q) {
    if ($t -notmatch '^/(taller|skills|habilidades|leer|analizar|escanear|mejorar|deshacer|web|crear)(\s|$)') { return $false }
    if ($script:Origin -ne 'consola') { return $false }          # fuera de la consola local estas habilidades no existen
    $cmd = $Matches[1]
    $arg = ($q.Trim() -replace '^/\S+\s*', '').Trim()
    switch ($cmd) {
        { $_ -in 'taller', 'skills', 'habilidades' } { Show-SkillsHelp }
        'leer' { Do-ReadFile (Extract-PathArg ('x ' + $arg)) }
        'analizar' { $ex = ($arg -match '(?i)\s+explicar\s*$'); $a2 = ($arg -replace '(?i)\s+explicar\s*$', ''); Do-Analyze ($(if ($a2) { Extract-PathArg ('x ' + $a2) } else { '' })) $ex }
        'escanear' { Do-PcScan }
        'mejorar' { Do-Improve ($(if ($arg) { Extract-PathArg ('x ' + $arg) } else { '' })) }
        'deshacer' { $r = Undo-LastChange; if ($r.ok) { Write-Host ('  Restaurado: ' + $r.path) -ForegroundColor Green } elseif ($r.declined) { Write-Host '  No se aprobo.' -ForegroundColor DarkGray } else { Write-Host ('  ' + $r.reason) -ForegroundColor Yellow } }
        'web' { Do-Web $arg }
        'crear' { Do-Create $arg }
    }
    $true
}
function Handle-SkillIntent([string]$q) {
    $i = Parse-SkillIntent $q
    if (-not $i) { return $false }
    if ($script:Origin -ne 'consola') { return $false }
    switch ($i.skill) {
        'escanear' { Do-PcScan }
        'web' { Do-Web $i.arg $true }
        'crear' { Do-Create $i.arg }
        'mejorar' { Do-Improve $i.arg }
        'analizar' { Do-Analyze $i.arg ([bool]$i.explain) }
        'leer' { Do-ReadFile $i.arg }
    }
    $true
}
