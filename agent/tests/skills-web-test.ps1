# Pruebas del generador web (sin modelo: se pasan especificaciones). Uso (dentro de app\env.bat): powershell -File skills-web-test.ps1. ASCII.
$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$App = Join-Path $Root 'app'; $Ag = Join-Path $Root 'agent'
. (Join-Path $App 'lib.ps1')
. (Join-Path $Ag 'hands.ps1')
. (Join-Path $Ag 'skills\files.ps1')
. (Join-Path $Ag 'skills\codescan.ps1')
. (Join-Path $Ag 'skills\webgen.ps1')
$script:Origin = 'consola'
$pass = 0; $fail = 0
function Check([string]$name, $got, $want) { if ("$got" -eq "$want") { $script:pass++ } else { $script:fail++; "FALLA: $name -> obtuve '$got', esperaba '$want'" } }
function CheckTrue([string]$name, $cond) { Check $name ([bool]$cond) $true }
$made = New-Object System.Collections.ArrayList

# ---- contraste de las 8 paletas, recalculado
$pal = Get-DesignJson 'palettes.json'
foreach ($p in $pal.paletas.PSObject.Properties) { $bad = @(Test-PaletteContrast $p.Name); Check ('paleta ' + $p.Name + ' contraste AA') $bad.Count 0 }
CheckTrue 'contraste negro/blanco = 21' ((Get-Contrast '#000000' '#ffffff') -eq 21)

# ---- los 3 ejemplos del diseno
$ex = Get-DesignJson 'examples.json'
foreach ($k in 'landing', 'menu', 'negocio') {
    $ch = Test-SiteSpec $ex.$k
    Check ("ejemplo $k valido") $ch.ok $true
    $r = New-Site $ch.spec
    Check ("ejemplo $k genera") $r.ok $true
    if ($r.ok) {
        [void]$made.Add($r.dir)
        CheckTrue "ejemplo $k index.html" (Test-Path -LiteralPath (Join-Path $r.dir 'index.html'))
        CheckTrue "ejemplo $k style.css" (Test-Path -LiteralPath (Join-Path $r.dir 'style.css'))
        $h = [IO.File]::ReadAllText((Join-Path $r.dir 'index.html'))
        CheckTrue "ejemplo $k sin script" ($h -notmatch '<script')
        CheckTrue "ejemplo $k sin http://" ($h -notmatch 'http://')
        CheckTrue "ejemplo $k un h1" ([regex]::Matches($h, '<h1[ >]').Count -eq 1)
        # determinismo
        $r2 = New-Site $ch.spec
        Check "ejemplo $k determinista (index)" $r2.hashes['index.html'] $r.hashes['index.html']
        Check "ejemplo $k determinista (css)" $r2.hashes['style.css'] $r.hashes['style.css']
        # el escaner de codigo no debe encontrar nada alto/medio en el sitio generado
        $null = Add-SessionGrant $r.dir 'read'
        $sc = Invoke-CodeScan $r.dir
        Check "ejemplo $k escaneo A" $sc.counts.A 0
        Check "ejemplo $k escaneo M" $sc.counts.M 0
    }
}

# ---- especificacion hostil
$hostile = [pscustomobject]@{
    tipo_sitio = 'landing'; idioma = 'es'; titulo = '<script>alert(1)</script>Mi "sitio"'; descripcion = 'Descripcion con <img src=x onerror=alert(1)> y comillas " y ''.'
    paleta = 'no-existe'; tipografia = 'inventada'
    secciones = @(
        [pscustomobject]@{ tipo = 'hero'; titulo = '<b onclick=x>Hola</b>'; texto = 'texto {{x}} <script>1</script>'; detalle = ''; boton_texto = 'Ir'; boton_enlace = 'javascript:alert(1)'; items = @() },
        [pscustomobject]@{ tipo = 'tarjetas'; titulo = 'Tarjetas'; texto = ''; detalle = ''; boton_texto = 'Ver'; boton_enlace = 'http://inseguro.example.com'; items = @([pscustomobject]@{ titulo = '"><script>x</script>'; texto = '<iframe src=//evil></iframe>'; detalle = 'a' }) },
        [pscustomobject]@{ tipo = 'ejecutar'; titulo = 'No existe'; texto = 'x'; detalle = ''; boton_texto = ''; boton_enlace = ''; items = @() },
        [pscustomobject]@{ tipo = 'texto'; titulo = ''; texto = ''; detalle = ''; boton_texto = ''; boton_enlace = ''; items = @() },
        [pscustomobject]@{ tipo = 'contacto'; titulo = 'Contacto'; texto = ''; detalle = ''; boton_texto = 'Mail'; boton_enlace = 'mailto:a@b.com'; items = @() }
    )
    contacto = [pscustomobject]@{ email = 'no es correo'; telefono = '+52 55 1234 5678'; direccion = 'Calle <b>1</b>'; como_llegar = '' }
    redes = @([pscustomobject]@{ nombre = 'Mala'; url = 'http://x.example.com' }, [pscustomobject]@{ nombre = 'Buena'; url = 'https://example.com/p' }, [pscustomobject]@{ nombre = 'Cred'; url = 'https://user:pw@example.com/' })
    pie = 'pie'
}
$hc = Test-SiteSpec $hostile
Check 'hostil: se sanea' $hc.ok $true
Check 'hostil: paleta por defecto' $hc.spec.paleta 'oceano'
Check 'hostil: tipografia por defecto' $hc.spec.tipografia 'humanista'
Check 'hostil: boton javascript descartado' $hc.spec.secciones[0].boton_enlace ''
Check 'hostil: boton http descartado' $hc.spec.secciones[1].boton_enlace ''
CheckTrue 'hostil: seccion invalida descartada' (-not (@($hc.spec.secciones | Where-Object { $_.tipo -eq 'ejecutar' }).Count))
CheckTrue 'hostil: seccion vacia descartada' (-not (@($hc.spec.secciones | Where-Object { $_.tipo -eq 'texto' }).Count))
Check 'hostil: email invalido omitido' $hc.spec.contacto.email ''
Check 'hostil: solo 1 red valida' $hc.spec.redes.Count 1
$hr = New-Site $hc.spec
Check 'hostil: genera' $hr.ok $true
if ($hr.ok) {
    [void]$made.Add($hr.dir)
    $hh = [IO.File]::ReadAllText((Join-Path $hr.dir 'index.html'))
    CheckTrue 'hostil: sin <script' ($hh -notmatch '<script')
    CheckTrue 'hostil: sin <iframe' ($hh -notmatch '<iframe')
    $activos = @([regex]::Matches($hh, '<[a-zA-Z][^>]*>') | Where-Object { ([regex]::Replace($_.Value, '"[^"]*"', '""')) -match '\son[a-z]+\s*=' })
    Check 'hostil: sin manejadores on* activos' $activos.Count 0
    CheckTrue 'hostil: sin javascript:' ($hh -notmatch 'javascript:')
    CheckTrue 'hostil: texto escapado presente' ($hh.Contains('&lt;script&gt;'))
    CheckTrue 'hostil: slug seguro' ((Split-Path -Leaf $hr.dir) -match '^[a-z0-9-]+(-\d+)?$')
    CheckTrue 'hostil: dentro del taller' (Test-UnderRoot $hr.dir (Get-WorkspaceRoot))
}

# ---- fallos de entrada
Check 'sin titulo: falla' (Test-SiteSpec ([pscustomobject]@{ tipo_sitio = 'landing'; titulo = '' })).ok $false
Check 'no objeto: falla' (Test-SiteSpec 'hola').ok $false
$fb = Get-FallbackSpec 'hazme una pagina web de mi cafeteria La Esquina con menu'
Check 'plantilla basica: tipo menu' $fb.tipo_sitio 'menu'
$fc = Test-SiteSpec $fb
Check 'plantilla basica valida' $fc.ok $true
$fr = New-Site $fc.spec
Check 'plantilla basica genera' $fr.ok $true
if ($fr.ok) { [void]$made.Add($fr.dir) }
$fb2 = Get-FallbackSpec 'ok'
Check 'plantilla basica titulo minimo' (Test-SiteSpec $fb2).ok $true
# flujo completo con especificacion dada
$full = Invoke-WebBuild 'x' $ex.landing
Check 'Invoke-WebBuild con spec' $full.ok $true
if ($full.ok) { [void]$made.Add($full.dir) }

# ---- slug y nombres reservados
Check 'slug CON' (Get-SafeSlug 'CON') 'sitio'
Check 'slug acentos' (Get-SafeSlug 'Cafe La Esquina!!') 'cafe-la-esquina'
Check 'slug traversal' (Get-SafeSlug '..\..\Windows') 'windows'
Check 'slug largo' ((Get-SafeSlug ('a' * 200)).Length -le 40) $true

# ---- validador del resultado detecta problemas
$spec = (Test-SiteSpec $ex.landing).spec
$html = Build-SiteHtml $spec; $css = Build-SiteCss $spec
Check 'validador: limpio' (Test-GeneratedSite $html $css $spec).Count 0
CheckTrue 'validador: detecta script' ((Test-GeneratedSite ($html.Replace('</body>', '<script>1</script></body>')) $css $spec).Count -gt 0)
CheckTrue 'validador: detecta http' ((Test-GeneratedSite ($html.Replace('href="#s1"', 'href="http://x.com"')) $css $spec).Count -gt 0)
CheckTrue 'validador: detecta style inline' ((Test-GeneratedSite ($html.Replace('<main ', '<main style="x" ')) $css $spec).Count -gt 0)
CheckTrue 'validador: detecta ancla rota' ((Test-GeneratedSite ($html.Replace('href="#s2"', 'href="#nada"')) $css $spec).Count -gt 0)
CheckTrue 'validador: detecta img sin alt' ((Test-GeneratedSite ($html.Replace('</main>', '<img src="data:image/png;base64,AA"></main>')) $css $spec).Count -gt 0)
CheckTrue 'validador: detecta CSS con @import' ((Test-GeneratedSite $html ($css + '@import "x.css";') $spec).Count -gt 0)

# ---- correcciones de la auditoria de accesibilidad
$fr = [pscustomobject]@{ tipo_sitio = 'landing'; idioma = 'fr'; titulo = 'Atelier du Port'; descripcion = 'Atelier de reparation de bateaux au port de la ville, devis gratuit.'; paleta = 'grafito'; tipografia = 'tecnico'
    secciones = @([pscustomobject]@{ tipo = 'hero'; titulo = 'Bienvenue'; texto = 'Texte'; detalle = ''; boton_texto = ''; boton_enlace = ''; items = @() },
                  [pscustomobject]@{ tipo = 'caracteristicas'; titulo = ''; texto = ''; detalle = ''; boton_texto = ''; boton_enlace = ''; items = @([pscustomobject]@{ titulo = 'Reparation'; texto = 'x'; detalle = '' }) },
                  [pscustomobject]@{ tipo = 'contacto'; titulo = 'Una seccion con un titulo larguisimo de verdad'; texto = ''; detalle = ''; boton_texto = ''; boton_enlace = ''; items = @() })
    contacto = [pscustomobject]@{ email = 'a@b.com'; telefono = '+33 1 23 45 67 89'; direccion = '1 quai'; como_llegar = '' }; redes = @(); pie = '' }
$fc = Test-SiteSpec $fr
Check 'fr: valido' $fc.ok $true
$fh = Build-SiteHtml $fc.spec; $fcss = Build-SiteCss $fc.spec
CheckTrue 'fr: etiquetas en frances' ($fh.Contains('Aller au contenu') -and $fh.Contains('T&eacute;l&eacute;phone') -and $fh.Contains('Adresse'))
CheckTrue 'fr: sin etiquetas en ingles' (-not $fh.Contains('Skip to content') -and -not $fh.Contains('>Phone<'))
CheckTrue 'seccion sin titulo recibe uno por defecto (sin salto de encabezados)' ($fc.spec.secciones[1].titulo.Length -gt 0)
Check 'fr: el sitio valida' (Test-GeneratedSite $fh $fcss $fc.spec).Count 0
CheckTrue 'main enfocable (tabindex -1)' ($fh.Contains('<main id="main" tabindex="-1">'))
CheckTrue 'nav truncada: aria-label con el titulo completo' ($fh -match 'aria-label="Una seccion con un titulo larguisimo de verdad"')
CheckTrue 'nav truncada: corta en limite de palabra' ($fh -notmatch '>Una seccion con un titulo l<')
CheckTrue 'css: hero con minmax(0,1fr)' ($fcss -match 'hero \.container \{ display: grid; grid-template-columns: minmax\(0, 1fr\)')
CheckTrue 'css: contador decorativo sin texto alternativo ruidoso' ($fcss.Contains('decimal-leading-zero) / ""'))
CheckTrue 'css: forced-colors cubre nav' ($fcss -match 'forced-colors: active\)[\s\S]*Highlight')
$pal2 = Get-DesignJson 'palettes.json'
foreach ($p in $pal2.paletas.PSObject.Properties) { Check ('paleta ' + $p.Name + ' pares derivados AA') @(Test-PaletteContrast $p.Name).Count 0 }

# ---- origen
$script:Origin = 'remoto'
$thr = $false; try { New-Site $spec | Out-Null } catch { $thr = $true }
Check 'origen remoto no genera' $thr $true
$script:Origin = 'consola'

# ---- limpieza
foreach ($d in $made) { if ($d -and (Test-Path -LiteralPath $d) -and (Test-UnderRoot $d (Join-Path (Get-WorkspaceRoot) 'sitios'))) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue } }
"RESULTADO: $pass pasaron, $fail fallaron"
