# Santuario - habilidad "crear paginas web": peticion -> especificacion JSON (modelo, esquema cerrado) -> validacion/saneado (codigo)
# -> generador DETERMINISTA (plantilla + base.css) -> validador del resultado -> carpeta del taller. El modelo nunca escribe HTML/CSS/JS.
# PowerShell 5.1, ASCII. Carga: despues de files.ps1 y codescan.ps1. Solo consola.

$script:WgDesign = Join-Path $PSScriptRoot 'design'
$script:WgCache = @{}
function Get-DesignJson([string]$name) {
    if (-not $script:WgCache.ContainsKey($name)) {
        $script:WgCache[$name] = [IO.File]::ReadAllText((Join-Path $script:WgDesign $name), [Text.Encoding]::UTF8) | ConvertFrom-Json
    }
    $script:WgCache[$name]
}
$script:WgAllowed = @{
    landing = @('hero', 'caracteristicas', 'tarjetas', 'precios', 'testimonios', 'contacto', 'texto')
    portafolio = @('hero', 'texto', 'tarjetas', 'caracteristicas', 'testimonios', 'contacto')
    menu = @('hero', 'precios', 'texto', 'horarios', 'contacto')
    evento = @('hero', 'texto', 'horarios', 'tarjetas', 'precios', 'contacto')
    negocio = @('hero', 'caracteristicas', 'precios', 'horarios', 'testimonios', 'contacto')
    articulo = @('hero', 'texto')
    proximamente = @('hero', 'contacto')
}
$script:WgLangs = @('es', 'en', 'fr', 'pt', 'de', 'it')
# Etiquetas fijas por idioma (con entidades HTML para no depender de la codificacion del archivo del generador)
$script:WgLabels = @{
    es = @{ skip = 'Saltar al contenido'; nav = 'Principal'; phone = 'Tel&eacute;fono'; addr = 'Direcci&oacute;n'; email = 'Correo' }
    en = @{ skip = 'Skip to content'; nav = 'Main'; phone = 'Phone'; addr = 'Address'; email = 'Email' }
    fr = @{ skip = 'Aller au contenu'; nav = 'Principal'; phone = 'T&eacute;l&eacute;phone'; addr = 'Adresse'; email = 'E-mail' }
    pt = @{ skip = 'Saltar para o conte&uacute;do'; nav = 'Principal'; phone = 'Telefone'; addr = 'Endere&ccedil;o'; email = 'E-mail' }
    de = @{ skip = 'Zum Inhalt springen'; nav = 'Hauptmen&uuml;'; phone = 'Telefon'; addr = 'Adresse'; email = 'E-Mail' }
    it = @{ skip = 'Vai al contenuto'; nav = 'Principale'; phone = 'Telefono'; addr = 'Indirizzo'; email = 'E-mail' }
}
$script:WgDefaultTitle = @{
    es = @{ caracteristicas = 'Servicios'; tarjetas = 'Destacados'; precios = 'Precios'; testimonios = 'Opiniones'; horarios = 'Horario'; contacto = 'Contacto'; texto = 'Informaci' + [char]0xF3 + 'n' }
    en = @{ caracteristicas = 'Features'; tarjetas = 'Highlights'; precios = 'Prices'; testimonios = 'Reviews'; horarios = 'Hours'; contacto = 'Contact'; texto = 'About' }
}

# ------------------------------------------------------------------ saneado de especificacion
function Clean-Text($s, [int]$max, [bool]$multiline = $false) {
    if ($null -eq $s) { return '' }
    $t = Strip-Terminal ([string]$s)
    if ($multiline) { $t = $t -replace "`r`n", "`n" -replace "`r", "`n" } else { $t = ($t -replace '\s+', ' ') }
    $t = $t.Trim()
    if ($t.Length -gt $max) { $t = $t.Substring(0, $max).TrimEnd() }
    $t
}
function Clean-Link($s, [hashtable]$ids) {
    $u = Clean-Text $s 200
    if (-not $u) { return '' }
    if ($u -match '^#([a-z0-9-]+)$') { if ($ids.ContainsKey($Matches[1])) { return $u } else { return '' } }
    if ($u -match '^mailto:[^\s"''<>@]+@[^\s"''<>@]+\.[^\s"''<>@]+$') { return $u }
    if ($u -match '^tel:\+?[0-9]{6,15}$') { return $u }
    if ($u -match '^https://[^\s"''<>]+$') {
        $uri = $null
        if ([Uri]::TryCreate($u, [UriKind]::Absolute, [ref]$uri) -and $uri.Scheme -eq 'https' -and -not $uri.UserInfo -and $uri.Host.Contains('.')) { return $u }
    }
    ''
}
function Get-SafeSlug([string]$title) {
    $n = (Normalize $title) -replace '[^a-z0-9]+', '-'
    $n = $n.Trim('-')
    if ($n.Length -gt 40) { $n = $n.Substring(0, 40).Trim('-') }
    if ($n.Length -lt 2 -or $n -match '^(con|prn|aux|nul|com[0-9]|lpt[0-9])$') { $n = 'sitio' }
    $n
}
# Convierte lo que devolvio el modelo (o el dueno) en una especificacion segura y completa. Nunca lanza: devuelve avisos.
function Test-SiteSpec($raw) {
    $warn = New-Object System.Collections.ArrayList
    if ($null -eq $raw -or $raw -isnot [System.Management.Automation.PSCustomObject]) { return @{ ok = $false; errors = @('la especificacion no es un objeto'); warnings = @() } }
    $tipo = [string]$raw.tipo_sitio
    if (-not $script:WgAllowed.ContainsKey($tipo)) { [void]$warn.Add('tipo_sitio invalido: se usa landing'); $tipo = 'landing' }
    $lang = [string]$raw.idioma; if ($script:WgLangs -notcontains $lang) { [void]$warn.Add('idioma invalido: se usa es'); $lang = 'es' }
    $pal = Get-DesignJson 'palettes.json'; $fon = Get-DesignJson 'fonts.json'
    $paleta = [string]$raw.paleta; if (-not $pal.paletas.PSObject.Properties[$paleta]) { [void]$warn.Add('paleta invalida: se usa oceano'); $paleta = 'oceano' }
    $tipo2 = [string]$raw.tipografia; if (-not $fon.tipografias.PSObject.Properties[$tipo2]) { [void]$warn.Add('tipografia invalida: se usa humanista'); $tipo2 = 'humanista' }
    $titulo = Clean-Text $raw.titulo 60
    if ($titulo.Length -lt 3) { return @{ ok = $false; errors = @('falta un titulo de sitio (3 a 60 caracteres)'); warnings = @() } }
    $desc = Clean-Text $raw.descripcion 160
    if ($desc.Length -lt 20) { $desc = Clean-Text ($titulo + ' - sitio web') 160; if ($desc.Length -lt 20) { $desc = $desc + ' (sitio web oficial)' } }
    $allowed = $script:WgAllowed[$tipo]
    $secs = New-Object System.Collections.ArrayList
    foreach ($s in @($raw.secciones)) {
        if ($null -eq $s) { continue }
        if ($secs.Count -ge 8) { [void]$warn.Add('mas de 8 secciones: se descartan las sobrantes'); break }
        $st = [string]$s.tipo
        if ($allowed -notcontains $st) { [void]$warn.Add(('seccion "' + $st + '" no permitida en ' + $tipo + ': descartada')); continue }
        $items = New-Object System.Collections.ArrayList
        foreach ($it in @($s.items)) {
            if ($null -eq $it) { continue }
            if ($items.Count -ge 12) { break }
            $ti = Clean-Text $it.titulo 60
            if (-not $ti) { continue }
            [void]$items.Add(@{ titulo = $ti; texto = (Clean-Text $it.texto 240); detalle = (Clean-Text $it.detalle 40) })
        }
        $dt = $script:WgDefaultTitle[$(if ($script:WgDefaultTitle.ContainsKey($lang)) { $lang } else { 'en' })][$st]
        $sec = @{ tipo = $st; titulo = (Clean-Text $s.titulo 60); texto = (Clean-Text $s.texto 1500 $true); detalle = (Clean-Text $s.detalle 60); boton_texto = (Clean-Text $s.boton_texto 30); boton_enlace = [string]$s.boton_enlace; items = @($items.ToArray()) }
        $hasContent = $sec.titulo -or $sec.texto -or $items.Count -gt 0
        if ($hasContent -and -not $sec.titulo -and $st -ne 'hero' -and $dt) { $sec.titulo = $dt }          # sin titulo, los h3 quedarian bajo el h1 (salto de nivel)
        if ($st -eq 'contacto') { $hasContent = $true }
        if (-not $hasContent) { [void]$warn.Add(('seccion "' + $st + '" vacia: descartada')); continue }
        [void]$secs.Add($sec)
    }
    # exactamente un hero y primero
    $heroes = @($secs | Where-Object { $_.tipo -eq 'hero' })
    $rest = @($secs | Where-Object { $_.tipo -ne 'hero' })
    if ($heroes.Count -eq 0) { [void]$warn.Add('sin hero: se crea uno'); $hero = @{ tipo = 'hero'; titulo = $titulo; texto = $desc; detalle = ''; boton_texto = ''; boton_enlace = ''; items = @() } }
    else { $hero = $heroes[0]; if ($heroes.Count -gt 1) { [void]$warn.Add('varios hero: se conserva el primero') } }
    if (-not $hero.titulo) { $hero.titulo = $titulo }
    $final = New-Object System.Collections.ArrayList
    [void]$final.Add($hero); foreach ($r in $rest) { [void]$final.Add($r) }
    $ids = @{}; for ($i = 1; $i -le $final.Count; $i++) { $ids['s' + $i] = $true }
    $badBtn = 0
    foreach ($s in $final) {
        $lk = Clean-Link $s.boton_enlace $ids
        if (-not $lk -or -not $s.boton_texto) { if ($s.boton_texto -and $s.boton_enlace) { $badBtn++ }; $s.boton_texto = ''; $s.boton_enlace = '' } else { $s.boton_enlace = $lk }
    }
    if ($badBtn -gt 0) { [void]$warn.Add(($badBtn.ToString() + ' boton(es) descartado(s): el enlace no era valido (solo https, #seccion, mailto: o tel:)')) }
    $c = $raw.contacto
    $email = Clean-Text $c.email 80; if ($email -and $email -notmatch '^[^\s"''<>@]+@[^\s"''<>@]+\.[^\s"''<>@]+$') { [void]$warn.Add('email invalido: omitido'); $email = '' }
    $tel = Clean-Text $c.telefono 30; $telDigits = ($tel -replace '[^0-9+]', ''); if ($tel -and ($telDigits -notmatch '^\+?[0-9]{6,15}$')) { [void]$warn.Add('telefono invalido: omitido'); $tel = ''; $telDigits = '' }
    $contacto = @{ email = $email; telefono = $tel; tel_digits = $telDigits; direccion = (Clean-Text $c.direccion 120); como_llegar = (Clean-Text $c.como_llegar 200) }
    $redes = New-Object System.Collections.ArrayList
    foreach ($r in @($raw.redes)) {
        if ($redes.Count -ge 6) { break }
        $nm = Clean-Text $r.nombre 30; $u = Clean-Link $r.url @{}
        if ($nm -and $u -and $u.StartsWith('https://')) { [void]$redes.Add(@{ nombre = $nm; url = $u }) } elseif ($nm -or $r.url) { [void]$warn.Add('red social descartada (solo https)') }
    }
    $spec = @{ tipo_sitio = $tipo; idioma = $lang; titulo = $titulo; descripcion = $desc; paleta = $paleta; tipografia = $tipo2; secciones = @($final.ToArray()); contacto = $contacto; redes = @($redes.ToArray()); pie = (Clean-Text $raw.pie 160) }
    @{ ok = $true; spec = $spec; warnings = @($warn.ToArray()); errors = @() }
}

# ------------------------------------------------------------------ contraste (WCAG)
function Get-Luminance([string]$hex) {
    $h = $hex.TrimStart('#')
    $v = @(0, 2, 4) | ForEach-Object { $c = [Convert]::ToInt32($h.Substring($_, 2), 16) / 255.0; if ($c -le 0.03928) { $c / 12.92 } else { [math]::Pow(($c + 0.055) / 1.055, 2.4) } }
    0.2126 * $v[0] + 0.7152 * $v[1] + 0.0722 * $v[2]
}
function Get-Contrast([string]$a, [string]$b) {
    $la = Get-Luminance $a; $lb = Get-Luminance $b
    $hi = [math]::Max($la, $lb); $lo = [math]::Min($la, $lb)
    [math]::Round(($hi + 0.05) / ($lo + 0.05), 2)
}
# color-mix(in srgb, A pctA%, B) calculado a mano (el CSS usa estas mezclas para texto atenuado y fondos suaves)
function Mix-Hex([string]$a, [string]$b, [double]$pctA) {
    $ha = $a.TrimStart('#'); $hb = $b.TrimStart('#'); $o = '#'
    foreach ($i in 0, 2, 4) { $x = [Convert]::ToInt32($ha.Substring($i, 2), 16); $y = [Convert]::ToInt32($hb.Substring($i, 2), 16); $o += ([int][math]::Round($x * $pctA + $y * (1 - $pctA))).ToString('x2') }
    $o
}
function Test-PaletteContrast([string]$name) {
    $pal = (Get-DesignJson 'palettes.json').paletas.$name
    $bad = New-Object System.Collections.ArrayList
    foreach ($mode in 'claro', 'oscuro') {
        $p = $pal.$mode
        # pares derivados que usa base.css
        $muted = Mix-Hex $p.text $p.bg 0.78; $soft = Mix-Hex $p.accent $p.bg 0.12
        foreach ($d in @(@('texto atenuado', $muted, $p.bg), @('texto atenuado', $muted, $p.surface), @('texto', $p.text, $soft), @('acento', $p.accent, $soft))) {
            $r = Get-Contrast $d[1] $d[2]; if ($r -lt 4.5) { [void]$bad.Add(($name + '/' + $mode + ' ' + $d[0] + ' ' + $d[1] + ' sobre ' + $d[2] + ' = ' + $r)) }
        }
        $pairs = @(@('text', 'bg'), @('text', 'surface'), @('accent', 'bg'), @('accent', 'surface'), @('on-accent', 'accent'))
        foreach ($pr in $pairs) { $r = Get-Contrast $p.($pr[0]) $p.($pr[1]); if ($r -lt 4.5) { [void]$bad.Add(($name + '/' + $mode + ' ' + $pr[0] + ' sobre ' + $pr[1] + ' = ' + $r)) } }
    }
    @($bad.ToArray())
}

# ------------------------------------------------------------------ generador
function HE([string]$s) { [System.Net.WebUtility]::HtmlEncode($s) }
function New-LinkTag([string]$href, [string]$cls, [string]$text) {
    $rel = if ($href.StartsWith('https://')) { ' rel="noopener noreferrer"' } else { '' }
    '<a' + $(if ($cls) { ' class="' + $cls + '"' } else { '' }) + ' href="' + (HE $href) + '"' + $rel + '>' + (HE $text) + '</a>'
}
function Build-SiteCss($spec) {
    $css = [IO.File]::ReadAllText((Join-Path $script:WgDesign 'base.css'), [Text.Encoding]::UTF8)
    $pal = (Get-DesignJson 'palettes.json').paletas.($spec.paleta)
    $fon = (Get-DesignJson 'fonts.json').tipografias.($spec.tipografia)
    function V($p) { '--bg:' + $p.bg + ';--surface:' + $p.surface + ';--text:' + $p.text + ';--accent:' + $p.accent + ';--on-accent:' + $p.'on-accent' + ';' }
    $pblock = ':root{' + (V $pal.claro) + '}' + "`n" + '@media (prefers-color-scheme: dark){:root{' + (V $pal.oscuro) + '}}'
    $fblock = ':root{--font-head:' + $fon.'font-head' + ';--font-body:' + $fon.'font-body' + ';--head-weight:' + $fon.'head-weight' + ';}'
    $mk = [regex]::Match($css, '(?m)^/\* @@PALETTE@@ \*/\r?$')       # la cabecera documental de base.css tambien nombra los marcadores: se descarta
    if (-not $mk.Success) { throw 'base.css sin marcador de paleta' }
    $css = '/* Santuario - hoja de estilos generada */' + "`n" + $css.Substring($mk.Index)
    $css = $css.Replace('/* @@PALETTE@@ */', $pblock).Replace('/* @@FONTS@@ */', $fblock)
    ($css -replace "`r`n", "`n")
}
function Build-SiteHtml($spec) {
    $sb = New-Object Text.StringBuilder
    $n = $spec.secciones.Count
    $L = $script:WgLabels[$spec.idioma]
    $csp = "default-src 'none'; style-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'"
    [void]$sb.Append("<!doctype html>`n<html lang=`"" + $spec.idioma + "`">`n<head>`n<meta charset=`"utf-8`">`n")
    [void]$sb.Append('<meta name="viewport" content="width=device-width, initial-scale=1">' + "`n")
    [void]$sb.Append('<title>' + (HE $spec.titulo) + "</title>`n")
    [void]$sb.Append('<meta name="description" content="' + (HE $spec.descripcion) + '">' + "`n")
    [void]$sb.Append('<meta http-equiv="Content-Security-Policy" content="' + (HE $csp) + '">' + "`n")
    [void]$sb.Append('<meta name="referrer" content="no-referrer">' + "`n" + '<meta name="color-scheme" content="light dark">' + "`n")
    [void]$sb.Append('<link rel="stylesheet" href="style.css">' + "`n</head>`n")
    [void]$sb.Append('<body class="site-' + $spec.tipo_sitio + '">' + "`n" + '<a class="skip" href="#main">' + $L.skip + "</a>`n")
    [void]$sb.Append('<header class="site-header"><div class="container"><a class="brand" href="#s1">' + (HE $spec.titulo) + '</a>')
    $navItems = @(); for ($i = 1; $i -lt $n; $i++) { $s = $spec.secciones[$i]; if ($s.titulo -and $navItems.Count -lt 6) { $t = $s.titulo; $lab = ''; if ($t.Length -gt 24) { $cut = $t.Substring(0, 24); $sp = $cut.LastIndexOf(' '); if ($sp -ge 8) { $cut = $cut.Substring(0, $sp) }; $lab = ' aria-label="' + (HE $t) + '"'; $t = $cut.TrimEnd() }; $navItems += ('<li><a href="#s' + ($i + 1) + '"' + $lab + '>' + (HE $t) + '</a></li>') } }
    if ($navItems.Count -gt 0) { [void]$sb.Append('<nav class="nav" aria-label="' + $L.nav + '"><ul>' + ($navItems -join '') + '</ul></nav>') }
    [void]$sb.Append("</div></header>`n<main id=`"main`" tabindex=`"-1`">`n")
    for ($i = 0; $i -lt $n; $i++) {
        $s = $spec.secciones[$i]; $id = 's' + ($i + 1)
        $btn = if ($s.boton_texto -and $s.boton_enlace) { New-LinkTag $s.boton_enlace 'btn' $s.boton_texto } else { '' }
        if ($s.tipo -eq 'hero') {
            [void]$sb.Append('<section class="section hero" id="' + $id + '"><div class="container"><div>')
            if ($s.detalle) { [void]$sb.Append('<p class="eyebrow">' + (HE $s.detalle) + '</p>') }
            [void]$sb.Append('<h1>' + (HE $s.titulo) + '</h1>')
            if ($s.texto) { [void]$sb.Append('<p class="hero__lead">' + (HE $s.texto) + '</p>') }
            if ($btn) { [void]$sb.Append('<p>' + $btn + '</p>') }
            [void]$sb.Append('</div><div class="hero__art" aria-hidden="true"></div></div></section>' + "`n")
            continue
        }
        [void]$sb.Append('<section class="section" id="' + $id + '"><div class="container">')
        if ($s.titulo -or ($s.texto -and $s.tipo -ne 'texto')) {
            [void]$sb.Append('<div class="section-head">')
            if ($s.titulo) { [void]$sb.Append('<h2>' + (HE $s.titulo) + '</h2>') }
            if ($s.texto -and $s.tipo -ne 'texto') { [void]$sb.Append('<p>' + (HE $s.texto) + '</p>') }
            [void]$sb.Append('</div>')
        }
        switch ($s.tipo) {
            'caracteristicas' { [void]$sb.Append('<ul class="features">'); foreach ($it in $s.items) { [void]$sb.Append('<li><h3>' + (HE $it.titulo) + '</h3>' + $(if ($it.texto) { '<p>' + (HE $it.texto) + '</p>' } else { '' }) + '</li>') }; [void]$sb.Append('</ul>') }
            'tarjetas' { [void]$sb.Append('<ul class="cards">'); foreach ($it in $s.items) { [void]$sb.Append('<li class="card">' + $(if ($it.detalle) { '<span class="tag">' + (HE $it.detalle) + '</span>' } else { '' }) + '<h3>' + (HE $it.titulo) + '</h3>' + $(if ($it.texto) { '<p>' + (HE $it.texto) + '</p>' } else { '' }) + '</li>') }; [void]$sb.Append('</ul>') }
            'precios' {
                if ($spec.tipo_sitio -eq 'menu') {
                    [void]$sb.Append('<ul class="menu">'); foreach ($it in $s.items) { [void]$sb.Append('<li><div class="menu__row"><h3 class="menu__name">' + (HE $it.titulo) + '</h3>' + $(if ($it.detalle) { '<span class="menu__price">' + (HE $it.detalle) + '</span>' } else { '' }) + '</div>' + $(if ($it.texto) { '<p class="menu__desc">' + (HE $it.texto) + '</p>' } else { '' }) + '</li>') }; [void]$sb.Append('</ul>')
                } else {
                    [void]$sb.Append('<ul class="prices">'); foreach ($it in $s.items) { [void]$sb.Append('<li class="price"><h3>' + (HE $it.titulo) + '</h3>' + $(if ($it.detalle) { '<p class="price__amount">' + (HE $it.detalle) + '</p>' } else { '' }) + $(if ($it.texto) { '<p>' + (HE $it.texto) + '</p>' } else { '' }) + '</li>') }; [void]$sb.Append('</ul>')
                }
            }
            'testimonios' { [void]$sb.Append('<ul class="quotes">'); foreach ($it in $s.items) { [void]$sb.Append('<li><figure class="quote"><blockquote><p>' + (HE $it.titulo) + '</p></blockquote>' + $(if ($it.detalle) { '<figcaption>' + (HE $it.detalle) + '</figcaption>' } else { '' }) + '</figure></li>') }; [void]$sb.Append('</ul>') }
            'horarios' { [void]$sb.Append('<dl class="hours">'); foreach ($it in $s.items) { [void]$sb.Append('<div><dt>' + (HE $it.titulo) + '</dt><dd>' + (HE $it.detalle) + '</dd></div>') }; [void]$sb.Append('</dl>') }
            'texto' { [void]$sb.Append('<div class="prose">'); foreach ($p in ($s.texto -split "`n\s*`n")) { if ($p.Trim()) { [void]$sb.Append('<p>' + (HE ($p.Trim() -replace "`n", ' ')) + '</p>') } }; [void]$sb.Append('</div>') }
            'contacto' {
                $c = $spec.contacto
                [void]$sb.Append('<address class="contact">')
                if ($c.email) { [void]$sb.Append('<p><span class="label">' + $L.email + '</span>' + (New-LinkTag ('mailto:' + $c.email) '' $c.email) + '</p>') }
                if ($c.telefono) { [void]$sb.Append('<p><span class="label">' + $L.phone + '</span>' + (New-LinkTag ('tel:' + $c.tel_digits) '' $c.telefono) + '</p>') }
                if ($c.direccion) { [void]$sb.Append('<p><span class="label">' + $L.addr + '</span>' + (HE $c.direccion) + '</p>') }
                if ($c.como_llegar) { [void]$sb.Append('<p>' + (HE $c.como_llegar) + '</p>') }
                [void]$sb.Append('</address>')
            }
        }
        if ($btn) { [void]$sb.Append('<p>' + $btn + '</p>') }
        [void]$sb.Append('</div></section>' + "`n")
    }
    [void]$sb.Append('</main>' + "`n" + '<footer class="site-footer"><div class="container"><p class="small">' + (HE $(if ($spec.pie) { $spec.pie } else { $spec.titulo })) + '</p>')
    if ($spec.redes.Count -gt 0) { [void]$sb.Append('<ul class="social">'); foreach ($r in $spec.redes) { [void]$sb.Append('<li>' + (New-LinkTag $r.url '' $r.nombre) + '</li>') }; [void]$sb.Append('</ul>') }
    [void]$sb.Append("</div></footer>`n</body>`n</html>`n")
    $sb.ToString()
}

# ------------------------------------------------------------------ validador del resultado (no es el modelo)
function Test-GeneratedSite([string]$html, [string]$css, $spec) {
    $e = New-Object System.Collections.ArrayList
    function Bad([string]$m) { [void]$e.Add($m) }
    if ($html -notmatch ('<html lang="' + $spec.idioma + '">')) { Bad 'lang no coincide con el idioma' }
    if ($html -notmatch '<!doctype html>') { Bad 'falta doctype' }
    if ($html -notmatch '<meta name="viewport" content="width=device-width, initial-scale=1">') { Bad 'viewport incorrecto' }
    if ([regex]::Matches($html, '<h1[ >]').Count -ne 1) { Bad 'debe haber exactamente un h1' }
    $prev = 0
    foreach ($m in [regex]::Matches($html, '<h([1-6])[ >]')) { $l = [int]$m.Groups[1].Value; if ($prev -gt 0 -and $l -gt $prev + 1) { Bad ('salto de encabezados h' + $prev + ' a h' + $l) }; $prev = $l }
    foreach ($tag in '<main id="main" tabindex="-1">', '<header ', '<nav ', '<footer ') { if ($tag -eq '<nav ') { continue }; if ([regex]::Matches($html, [regex]::Escape($tag)).Count -ne 1) { Bad ('landmark: ' + $tag) } }
    if ($html -notmatch 'class="skip" href="#main"') { Bad 'falta el enlace de salto' }
    if ($html -notmatch [regex]::Escape((HE "default-src 'none'; style-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'"))) { Bad 'CSP ausente o distinta' }
    $css = [regex]::Replace($css, '(?s)/\*.*?\*/', '')
    foreach ($tm in [regex]::Matches($html, '<[a-zA-Z][^>]*>')) {      # atributos reales: se vacian los valores entre comillas antes de buscar nombres
        $bare = [regex]::Replace($tm.Value, '"[^"]*"', '""')
        if ($bare -match '(?i)\s(?:style|srcdoc)\s*=' -or $bare -match '(?i)\son[a-z]+\s*=') { Bad ('atributo prohibido en: ' + $tm.Value.Substring(0, [math]::Min(60, $tm.Value.Length))) }
    }
    foreach ($pat in '<style', '<script', '<iframe', '<object', '<embed', '<form', '<base\b', 'http-equiv="refresh"', '(?:href|src)="\s*(?:javascript|vbscript|data):', '=\s*["'']http://', '=\s*["'']//') {
        if ($html -match ('(?i)' + $pat)) { Bad ('patron prohibido en el HTML: ' + $pat) }
    }
    foreach ($m in [regex]::Matches($html, '<(?:link|img|source)\b[^>]*(?:src|href)="([^"]+)"')) { if ($m.Groups[1].Value -ne 'style.css' -and -not $m.Groups[1].Value.StartsWith('data:image/')) { Bad ('recurso externo: ' + $m.Groups[1].Value) } }
    $ids = @{}; foreach ($m in [regex]::Matches($html, '\sid="([^"]+)"')) { if ($ids.ContainsKey($m.Groups[1].Value)) { Bad ('id duplicado ' + $m.Groups[1].Value) } else { $ids[$m.Groups[1].Value] = 1 } }
    foreach ($m in [regex]::Matches($html, 'href="#([^"]+)"')) { if (-not $ids.ContainsKey($m.Groups[1].Value)) { Bad ('ancla rota #' + $m.Groups[1].Value) } }
    foreach ($m in [regex]::Matches($html, '<a\b([^>]*)>(.*?)</a>')) {
        if (-not ($m.Groups[2].Value -replace '<[^>]+>', '').Trim()) { Bad 'enlace sin texto' }
        if ($m.Groups[1].Value -match 'href="https://' -and $m.Groups[1].Value -notmatch 'rel="noopener noreferrer"') { Bad 'enlace externo sin rel' }
    }
    foreach ($m in [regex]::Matches($html, '<img\b[^>]*>')) { if ($m.Value -notmatch '\salt=') { Bad 'img sin alt' } }
    if ($css -match '@import' -or $css -match 'url\(\s*["'']?(?!data:)') { Bad 'CSS con @import o url() externo' }
    if ($css -notmatch ':focus-visible') { Bad 'CSS sin :focus-visible' }
    if ($css -notmatch 'prefers-reduced-motion') { Bad 'CSS sin prefers-reduced-motion' }
    if ($css -notmatch '--tap:\s*2\.75rem') { Bad 'CSS sin tamano tactil' }
    if ($css -notmatch 'prefers-color-scheme: dark') { Bad 'CSS sin modo oscuro' }
    if ($css -match '@@') { Bad 'marcador sin sustituir en CSS' }
    foreach ($b in (Test-PaletteContrast $spec.paleta)) { Bad ('contraste insuficiente: ' + $b) }
    @($e.ToArray())
}

# ------------------------------------------------------------------ escritura en el taller
function Write-SiteFiles($spec, [string]$html, [string]$css) {
    $sites = Join-Path (Get-WorkspaceRoot) 'sitios'
    if (-not (Test-Path -LiteralPath $sites)) { New-Item -ItemType Directory -Force $sites | Out-Null }
    $slug = Get-SafeSlug $spec.titulo
    $dir = Join-Path $sites $slug; $k = 2
    while ((Test-Path -LiteralPath $dir) -and -not (Test-Path -LiteralPath (Join-Path $dir '.santuario-site.json')) -and @(Get-ChildItem -LiteralPath $dir -Force).Count -gt 0) { $dir = Join-Path $sites ($slug + '-' + $k); $k++ }
    $chk = Resolve-SafePath $dir 'write'
    if (-not $chk.ok) { return @{ ok = $false; reason = 'destino no permitido: ' + $chk.reason } }
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    $enc = New-Object Text.UTF8Encoding($false)
    $files = @{ 'index.html' = $html; 'style.css' = $css }
    $manifest = @{}
    foreach ($name in $files.Keys) {
        $target = Join-Path $dir $name
        $a = Get-AttrSafe $target; if ($null -ne $a -and ($a -band [IO.FileAttributes]::ReparsePoint)) { return @{ ok = $false; reason = 'el destino es un enlace' } }
        [IO.File]::WriteAllText($target, $files[$name], $enc)
        $manifest[$name] = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
    }
    [IO.File]::WriteAllText((Join-Path $dir '.santuario-site.json'), ($manifest | ConvertTo-Json), $enc)
    @{ ok = $true; dir = $dir; files = @($files.Keys); hashes = $manifest }
}
function New-Site($spec) {
    Assert-Console
    $html = Build-SiteHtml $spec
    $css = Build-SiteCss $spec
    $errs = Test-GeneratedSite $html $css $spec
    if ($errs.Count -gt 0) { return @{ ok = $false; reason = 'el sitio generado no paso la validacion'; errors = $errs } }
    $w = Write-SiteFiles $spec $html $css
    if (-not $w.ok) { return $w }
    $w.bytes = $html.Length + $css.Length
    $w
}

# ------------------------------------------------------------------ especificacion desde la peticion (modelo)
function ConvertTo-PlainSchema($o) {
    if ($o -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($p in $o.PSObject.Properties) { if ($p.Name -eq 'pattern' -or $p.Name -eq '$schema' -or $p.Name -like 'x-*') { continue }; $h[$p.Name] = ConvertTo-PlainSchema $p.Value }
        return $h
    }
    if ($o -is [System.Array]) { return @($o | ForEach-Object { ConvertTo-PlainSchema $_ }) }
    $o
}
function Get-FallbackSpec([string]$request) {
    $n = Normalize $request
    $tipo = 'landing'
    if ($n -match 'menu|carta|cafeteria|restaurante|cafe |taqueria') { $tipo = 'menu' } elseif ($n -match 'portafolio|portfolio') { $tipo = 'portafolio' } elseif ($n -match 'evento|boda|fiesta|concierto') { $tipo = 'evento' } elseif ($n -match 'proximamente|pronto|coming soon') { $tipo = 'proximamente' } elseif ($n -match 'articulo|blog|nota') { $tipo = 'articulo' } elseif ($n -match 'negocio|tienda|local|taller') { $tipo = 'negocio' }
    $title = (Clean-Text $request 50) -replace '^(?i)(crea|haz|hazme|genera|quiero)\s+(una?\s+)?(pagina\s+web|sitio\s+web|pagina|sitio|web)\s+(de|para|sobre)?\s*', ''
    if ($title.Length -lt 3) { $title = 'Mi sitio' }
    $title = (Get-Culture).TextInfo.ToTitleCase($title.ToLowerInvariant())
    $secs = @(
        [pscustomobject]@{ tipo = 'hero'; titulo = $title; texto = (Clean-Text $request 200); detalle = ''; boton_texto = ''; boton_enlace = ''; items = @() },
        [pscustomobject]@{ tipo = 'texto'; titulo = 'Acerca de'; texto = (Clean-Text $request 1000); detalle = ''; boton_texto = ''; boton_enlace = ''; items = @() }
    )
    if ($script:WgAllowed[$tipo] -contains 'contacto') { $secs += [pscustomobject]@{ tipo = 'contacto'; titulo = 'Contacto'; texto = ''; detalle = ''; boton_texto = ''; boton_enlace = ''; items = @() } }
    if ($tipo -eq 'proximamente') { $secs = @($secs[0], $secs[2]) }
    if ($tipo -eq 'menu') { $secs = @($secs[0], $secs[1]) }
    [pscustomobject]@{ tipo_sitio = $tipo; idioma = 'es'; titulo = $title; descripcion = (Clean-Text ('Sitio web de ' + $title + '. ' + $request) 160); paleta = 'oceano'; tipografia = 'humanista'; secciones = $secs; contacto = [pscustomobject]@{ email = ''; telefono = ''; direccion = ''; como_llegar = '' }; redes = @(); pie = $title }
}
# Pide al modelo local la especificacion JSON (esquema forzado, sin herramientas, sin historial). Devuelve objeto o $null.
function Invoke-SpecModel([string]$request) {
    $schema = ConvertTo-PlainSchema (Get-DesignJson 'site-spec.schema.json')
    $ex = ((Get-DesignJson 'examples.json').landing | ConvertTo-Json -Depth 12 -Compress)
    $sys = 'Eres un disenador web. Conviertes la peticion del usuario en una especificacion JSON de un sitio. Responde SOLO el JSON del esquema; todos los campos son obligatorios (usa "" o [] si no aplica). ' +
           'Escribe en el idioma de la peticion, con ortografia completa (tildes y signos). Una sola seccion hero y primero. Maximo 6 secciones. No inventes telefonos, correos ni enlaces: dejalos vacios si el usuario no los dio. ' +
           'tipo_sitio: landing, portafolio, menu, evento, negocio, articulo o proximamente. Ejemplo de formato (otro tema): ' + $ex
    $region = Resolve-Region 'general' $script:loadedRam
    if (Get-Command Use-Region -ErrorAction SilentlyContinue) { Use-Region $region }
    $body = @{ model = $region.alias; stream = $false; think = $false; format = $schema; options = @{ temperature = 0.3; num_predict = 1800; num_ctx = 4096 }; messages = @(@{ role = 'system'; content = $sys }, @{ role = 'user'; content = $request }) } | ConvertTo-Json -Depth 20
    try {
        Write-Host ('  (disenando con ' + $region.base_name + '...)') -ForegroundColor DarkGray
        $x = Invoke-RestMethod "$Base/api/chat" -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 600
        return ([string]$x.message.content | ConvertFrom-Json)
    } catch { return $null }
}
# Flujo completo desde texto. $specObj permite saltarse el modelo (pruebas o especificacion escrita a mano).
function Invoke-WebBuild([string]$request, $specObj = $null) {
    Assert-Console
    $raw = $specObj; $used = 'dada'
    if ($null -eq $raw) { $raw = Invoke-SpecModel $request; $used = 'modelo' }
    $chk = if ($raw) { Test-SiteSpec $raw } else { @{ ok = $false } }
    if (-not $chk.ok) { $raw = Get-FallbackSpec $request; $chk = Test-SiteSpec $raw; $used = 'plantilla basica (el modelo no dio una especificacion valida)' }
    if (-not $chk.ok) { return @{ ok = $false; reason = 'no se pudo construir una especificacion'; errors = $chk.errors } }
    $res = New-Site $chk.spec
    $res.spec = $chk.spec; $res.warnings = $chk.warnings; $res.source = $used
    $res
}

function Open-SitePreview([string]$dir) {
    Assert-Console
    $chk = Resolve-SafePath (Join-Path $dir 'index.html') 'read'
    if (-not $chk.ok) { Write-Host ('  No se puede abrir: ' + $chk.reason) -ForegroundColor Red; return $false }
    $edge = Get-EdgePath
    if (-not $edge) { Write-Host '  No encuentro Microsoft Edge.' -ForegroundColor Red; return $false }
    if (-not (Confirm-Action ('Abrir la vista previa de ' + $chk.path + ' en Edge (perfil temporal, sin extensiones)'))) { return $false }
    $prof = Join-Path ([IO.Path]::GetTempPath()) ('santuario-preview-' + $PID)
    $uri = (New-Object Uri($chk.path)).AbsoluteUri
    Start-Process -FilePath $edge -ArgumentList @('--user-data-dir="' + $prof + '"', '--disable-extensions', '--no-first-run', '--no-default-browser-check', $uri) | Out-Null
    $true
}
