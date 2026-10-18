# Santuario - habilidad "analizar codigo": reglas deterministas (secretos, patrones peligrosos, metricas) + informe. PowerShell 5.1, ASCII.
# Carga: despues de files.ps1. El MODELO NO detecta nada: el codigo encuentra, el modelo (opcional) solo explica.
# Reglas inspiradas en gitleaks (MIT) y detect-secrets (Apache-2.0); ver agent\skills\SOURCE.md.

$script:CsRx = @{}
function New-Rx([string]$pat, [string]$opts = 'None') {
    $key = $opts + '|' + $pat
    if (-not $script:CsRx.ContainsKey($key)) {
        $script:CsRx[$key] = New-Object Text.RegularExpressions.Regex($pat, [Text.RegularExpressions.RegexOptions]$opts, [TimeSpan]::FromMilliseconds(250))
    }
    $script:CsRx[$key]
}

# Quita secuencias de control/ANSI y caracteres bidi/invisibles antes de imprimir texto que vino de archivos o del modelo.
function Strip-Terminal([string]$s) {
    if ($null -eq $s) { return '' }
    $s = [regex]::Replace($s, '\x1B\[[0-9;?]*[ -/]*[@-~]', '')
    $s = [regex]::Replace($s, '\x1B\][^\x07\x1B]*(\x07|\x1B\\)?', '')
    [regex]::Replace($s, '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F\u200B-\u200F\u202A-\u202E\u2060-\u2069\uFEFF]', '')
}

function Get-Entropy([string]$s) {
    if (-not $s -or $s.Length -eq 0) { return 0.0 }
    $f = @{}
    foreach ($c in $s.ToCharArray()) { if ($f.ContainsKey($c)) { $f[$c]++ } else { $f[$c] = 1 } }
    $h = 0.0; $n = [double]$s.Length
    foreach ($v in $f.Values) { $p = $v / $n; $h -= $p * [math]::Log($p, 2) }
    $h
}

# ------------------------------------------------------------------ reglas
# id ;; lenguajes (* = todos) ;; sev (A/M/B) ;; regex ;; mensaje ;; correccion ;; flags (i=sin mayusculas, c=tambien comentarios, s=secreto)
$script:CsRulesText = @'
aws-key ;; * ;; A ;; \b((?:A3T[A-Z0-9]|AKIA|ASIA|ABIA|ACCA)[A-Z2-7]{16})\b ;; Clave de acceso de AWS en el codigo ;; Rotala en AWS y leela de una variable de entorno ;; cs
github-token ;; * ;; A ;; \b(gh[pousr]_[0-9a-zA-Z]{36})\b ;; Token de GitHub en el codigo ;; Revocalo en GitHub y usa una variable de entorno ;; cs
github-pat ;; * ;; A ;; \b(github_pat_\w{82})\b ;; Token fino de GitHub en el codigo ;; Revocalo y usa una variable de entorno ;; cs
slack-token ;; * ;; A ;; \b(xox[abprs]-[0-9A-Za-z-]{10,})\b ;; Token de Slack en el codigo ;; Revocalo y usa una variable de entorno ;; cs
slack-webhook ;; * ;; A ;; (hooks\.slack\.com/services/T[A-Z0-9]{8,}/B[A-Z0-9]{8,}/[A-Za-z0-9]{24}) ;; URL de webhook de Slack ;; Tratala como secreto: rotala y guardala fuera del codigo ;; cs
stripe-live ;; * ;; A ;; \b((?:sk|rk)_(?:live|prod)_[a-zA-Z0-9]{10,99})\b ;; Clave secreta de Stripe (produccion) ;; Rotala en Stripe y usa una variable de entorno ;; cs
google-key ;; * ;; M ;; \b(AIza[\w-]{35})\b ;; Clave de API de Google ;; Restringela por origen/API y sacala del codigo ;; cs
jwt ;; * ;; M ;; \b(ey[a-zA-Z0-9]{17,}\.ey[a-zA-Z0-9/\\_-]{17,}\.[a-zA-Z0-9/\\_-]{10,})\b ;; Token JWT en el codigo ;; No guardes tokens en el codigo ;; cs
private-key ;; * ;; A ;; (-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED |PGP )?PRIVATE KEY(?: BLOCK)?-----) ;; Clave privada en el archivo ;; Sacala del repositorio, regenerala y guardala fuera del proyecto ;; cs
telegram-token ;; * ;; A ;; \b(\d{8,10}:[A-Za-z0-9_-]{35})\b ;; Token de bot de Telegram ;; Revocalo con @BotFather y guardalo cifrado ;; cs
conn-string ;; * ;; A ;; \b(?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis|amqps?|mssql)://[^\s:/@'"]+:([^\s@'"]{3,})@ ;; Cadena de conexion con contrasena ;; Pasa la contrasena por variable de entorno ;; cs
azure-key ;; * ;; A ;; AccountKey=([A-Za-z0-9+/]{86}==) ;; Clave de cuenta de Azure Storage ;; Rotala y usa identidad administrada o variable de entorno ;; cs
sql-pass ;; * ;; M ;; \b(?:Password|Pwd)\s*=\s*([^;'"\s]{4,})\s*; ;; Contrasena en cadena de conexion ;; Sacala del codigo ;; ics
generic-secret ;; * ;; M ;; (?:api_?key|auth_?key|secret|passw(?:or)?d|pwd|contrase.a|private_?key|client_?secret|access_?token)[\w.-]*["']?\s*[:=]{1,3}\s*["']([^"'\r\n]{8,})["'] ;; Posible secreto asignado en el codigo ;; Leelo de una variable de entorno o de un almacen cifrado ;; ics
ps-iex ;; powershell ;; A ;; \b(?:Invoke-Expression|iex)\b(?!\s*=) ;; Invoke-Expression ejecuta texto como codigo ;; Usa llamadas directas (&), parametros o splatting ;; i
ps-dl-exec ;; powershell,batch ;; A ;; \b(?:DownloadString|iwr|irm|Invoke-WebRequest|Invoke-RestMethod)\b.*\|\s*(?:iex|Invoke-Expression) ;; Descarga y ejecuta codigo sin revisarlo ;; Descargalo, verifica el hash, revisalo y solo entonces ejecutalo ;; i
ps-bypass ;; powershell,batch ;; M ;; -Exec(?:utionPolicy)?\s+Bypass ;; Salta la politica de ejecucion ;; Firma los scripts o usa RemoteSigned ;; i
ps-encoded ;; powershell,batch ;; A ;; \s-(?:enc|EncodedCommand)\b ;; Comando codificado: oculta lo que se ejecuta ;; Usa el script en claro ;; i
ps-plaintext-pass ;; powershell ;; A ;; ConvertTo-SecureString\s+.*-AsPlainText ;; Contrasena en texto plano ;; Usa Get-Credential o DPAPI (ConvertFrom-SecureString sin clave) ;; i
ps-nocert ;; powershell ;; M ;; ServerCertificateValidationCallback\s*=|-SkipCertificateCheck ;; Desactiva la validacion de certificados ;; Valida siempre el certificado ;; i
ps-defender ;; powershell ;; M ;; (?:Set-MpPreference\s+.*-Disable\w+\s+\$true|Add-MpPreference\s+.*-ExclusionPath) ;; Modifica Windows Defender ;; Confirma que es intencional ;; i
ps-hidden ;; powershell,batch ;; B ;; -WindowStyle\s+Hidden ;; Ejecucion oculta ;; Justificala o quitala ;; i
ps-runas ;; powershell ;; B ;; Start-Process\b.*-Verb\s+RunAs ;; Eleva privilegios ;; Confirma que es necesario ;; i
js-eval ;; javascript,typescript ;; A ;; \beval\s*\( ;; eval ejecuta texto como codigo ;; Usa JSON.parse u otra alternativa ;;
js-newfunction ;; javascript,typescript ;; A ;; \bnew\s+Function\s*\( ;; new Function equivale a eval ;; Evitalo ;;
js-innerhtml ;; javascript,typescript,html ;; M ;; \.(?:innerHTML|outerHTML)\s*=(?!=) ;; Riesgo de XSS con innerHTML ;; Usa textContent o sanea el HTML ;;
js-docwrite ;; javascript,typescript,html ;; M ;; \bdocument\.write(?:ln)?\s*\( ;; document.write es inseguro y lento ;; Usa metodos del DOM ;;
js-exec-concat ;; javascript,typescript ;; A ;; \bexec(?:Sync)?\s*\([^)]*\+ ;; Comando del sistema armado con concatenacion ;; Usa execFile con lista de argumentos ;;
js-dangerous-html ;; javascript,typescript ;; M ;; dangerouslySetInnerHTML ;; HTML sin sanear en React ;; Solo con HTML saneado ;;
js-weakhash ;; javascript,typescript ;; M ;; createHash\(\s*["'](?:md5|sha1)["']\s*\) ;; Hash debil ;; Usa SHA-256 o superior (contrasenas: bcrypt/argon2) ;;
js-notls ;; javascript,typescript ;; M ;; rejectUnauthorized\s*:\s*false|NODE_TLS_REJECT_UNAUTHORIZED\s*=\s*["']?0 ;; Desactiva la verificacion TLS ;; No la desactives ;;
js-settimeout-str ;; javascript,typescript ;; M ;; set(?:Timeout|Interval)\(\s*["'] ;; Pasar texto a setTimeout equivale a eval ;; Pasa una funcion ;;
py-eval ;; python ;; A ;; (?<![\w.])(?:eval|exec)\s*\( ;; eval/exec ejecutan texto como codigo ;; Usa ast.literal_eval para datos ;;
py-pickle ;; python ;; A ;; \b(?:c?[pP]ickle|marshal)\.loads?\s*\( ;; pickle ejecuta codigo al cargar ;; Usa JSON ;;
py-shell ;; python ;; A ;; \bsubprocess\.\w+\(.*shell\s*=\s*True ;; shell=True permite inyeccion de comandos ;; Pasa lista de argumentos y shell=False ;;
py-yaml ;; python ;; A ;; \byaml\.load\s*\((?![^)]*Loader\s*=\s*(?:yaml\.)?(?:Safe|CSafe)Loader) ;; yaml.load sin cargador seguro ;; Usa yaml.safe_load ;;
py-sql ;; python ;; M ;; \.execute\(\s*(?:f["']|["'][^"']*["']\s*(?:%|\+)|["'][^"']*["']\.format) ;; Consulta SQL armada con texto ;; Usa consultas parametrizadas ;; i
py-weakhash ;; python ;; M ;; hashlib\.(?:md5|sha1)\( ;; Hash debil ;; Usa SHA-256 o superior ;;
py-noverify ;; python ;; M ;; verify\s*=\s*False ;; Desactiva la verificacion TLS ;; No la desactives ;;
py-ossystem ;; python ;; M ;; \bos\.system\( ;; os.system ejecuta por el shell ;; Usa subprocess.run con lista ;;
html-inline-handler ;; html ;; B ;; \son(?:click|load|error|mouseover|submit)\s*=\s*["'] ;; Manejador en linea (rompe CSP) ;; Muevelo a un archivo JS ;; i
html-mixed ;; html ;; M ;; <(?:script|link|iframe)\b[^>]*(?:src|href)\s*=\s*["']http:// ;; Recurso cargado por HTTP (contenido mixto) ;; Usa HTTPS ;; i
html-blank ;; html ;; M ;; <a\b(?=[^>]*target\s*=\s*["']_blank["'])(?![^>]*rel\s*=\s*["'][^"']*noopener)[^>]*> ;; target=_blank sin rel=noopener ;; Agrega rel="noopener noreferrer" ;; i
html-form-http ;; html ;; M ;; <form\b[^>]*action\s*=\s*["']http:// ;; Formulario enviado por HTTP ;; Usa HTTPS ;; i
html-img-alt ;; html ;; B ;; <img\b(?![^>]*\balt\s*=)[^>]*> ;; Imagen sin texto alternativo ;; Agrega alt (accesibilidad) ;; i
sql-xpcmd ;; sql ;; A ;; \bxp_cmdshell\b ;; Ejecuta comandos del sistema desde SQL ;; Desactivalo ;; i
sql-exec-concat ;; sql ;; A ;; \bEXEC(?:UTE)?\s*\(\s*@?\w+\s*\+ ;; SQL dinamico concatenado ;; Parametriza ;; i
sql-grant ;; sql ;; M ;; \bGRANT\s+ALL\b|\bTO\s+PUBLIC\b ;; Permisos excesivos ;; Minimo privilegio ;; i
bat-encoded ;; batch ;; A ;; powershell(?:\.exe)?\s.*-(?:enc|EncodedCommand)\b ;; Comando PowerShell codificado ;; Usa el script en claro ;; i
bat-download ;; batch ;; M ;; \b(?:bitsadmin|certutil)\b.*(?:-urlcache|/transfer|http://) ;; Descarga sin verificar ;; Verifica el hash de lo descargado ;; i
bat-persist ;; batch ;; M ;; \breg\s+add\s+.*\\(?:Run|RunOnce)\b ;; Persistencia en el registro ;; Confirma que es intencional ;; i
bat-adduser ;; batch ;; M ;; \bnet\s+user\s+\S+\s+\S+\s*/add ;; Crea un usuario con contrasena en claro ;; Evitalo ;; i
bat-secret ;; batch ;; M ;; \bset\s+"?\w*(?:pass|pwd|secret|token)\w*\s*=\s*\S+ ;; Secreto en variable de script ;; Pidelo al usuario o leelo de un almacen cifrado ;; i
docker-pipe-sh ;; docker,shell ;; A ;; \b(?:curl|wget)\b[^|\n]*\|\s*(?:sudo\s+)?(?:ba)?sh\b ;; Ejecuta un script descargado sin verificar ;; Descargalo, verifica el hash y luego ejecutalo ;; i
docker-secret ;; docker ;; A ;; ^\s*(?:ENV|ARG)\s+\w*(?:PASS|SECRET|TOKEN|KEY)\w*[= ]\s*\S+ ;; Secreto dentro de la imagen ;; Usa secretos de build ;; i
docker-chmod ;; docker,shell ;; M ;; \bchmod\s+(?:-R\s+)?777\b ;; Permisos 777 ;; Usa permisos minimos ;; i
cfg-notls ;; json,yaml,ini,toml ;; M ;; ["']?(?:ssl|tls|verify\w*)["']?\s*[:=]\s*false ;; Verificacion TLS desactivada ;; Activala ;; i
cfg-bindall ;; json,yaml,ini,toml ;; M ;; ["']?(?:host|bind|listen\w*)["']?\s*[:=]\s*["']0\.0\.0\.0["'] ;; Escucha en todas las interfaces ;; Escucha solo en 127.0.0.1 si no hace falta exponerlo ;; i
cfg-cors ;; json,yaml ;; M ;; ["']?(?:allowed_?origins?|cors\w*)["']?\s*[:=]\s*\[?\s*["']\*["'] ;; CORS abierto a todos ;; Lista los origenes permitidos ;; i
cfg-privileged ;; yaml ;; A ;; privileged\s*:\s*true ;; Contenedor privilegiado ;; Quita privileged ;; i
inj-prompt ;; * ;; M ;; (?:ignore (?:all |the )?(?:previous|above) instructions|ignora (?:todas )?las instrucciones|<\|im_start\|>|disregard (?:your|the) system prompt) ;; Texto dirigido a un asistente de IA dentro del archivo ;; Tratalo como no confiable: no lo obedezcas ;; ic
'@
$script:CsRules = $null
function Get-CsRules {
    if ($script:CsRules) { return $script:CsRules }
    $list = New-Object System.Collections.ArrayList
    foreach ($ln in ($script:CsRulesText -split "`r?`n")) {
        if (-not $ln.Trim()) { continue }
        $p = ($ln.TrimEnd() + ' ') -split ' ;; '
        if ($p.Count -lt 7) { continue }
        $fl = $p[6].Trim()
        $opt = if ($fl.Contains('i')) { 'IgnoreCase' } else { 'None' }
        $langs = @($p[1].Trim().Split(',') | ForEach-Object { $_.Trim() })
        [void]$list.Add(@{ id = $p[0].Trim(); all = ($langs -contains '*'); langs = $langs; sev = $p[2].Trim(); rx = (New-Rx $p[3].Trim() $opt); rxm = $null; pat = $p[3].Trim(); opt = $opt; msg = $p[4].Trim(); fix = $p[5].Trim(); comments = $fl.Contains('c'); secret = $fl.Contains('s') })
    }
    $script:CsRules = @($list.ToArray())
    $script:CsRules
}
$script:CsPlaceholderRx = New-Object Text.RegularExpressions.Regex('(?i)(example|sample|dummy|changeme|change_me|your[_-]|<[^>]*>|xxxx|placeholder|fake|todo|redacted|insert|replace|^\*+$|^\.+$|^\$|^\$\{|^%|^\{\{|^@.*@$|%s|%d|\{0\}|\bnull\b|^(true|false)$|password123456|abcdefgh)', 'None', [TimeSpan]::FromMilliseconds(250))
$script:CsCommentPrefix = @{
    powershell = '^[ \t]*#'; python = '^[ \t]*#'; shell = '^[ \t]*#'; yaml = '^[ \t]*#'; ini = '^[ \t]*[#;]'; toml = '^[ \t]*#'; ruby = '^[ \t]*#'; docker = '^[ \t]*#'
    javascript = '^[ \t]*(//|/\*|\*)'; typescript = '^[ \t]*(//|/\*|\*)'; java = '^[ \t]*(//|/\*|\*)'; csharp = '^[ \t]*(//|/\*|\*)'; go = '^[ \t]*(//|/\*|\*)'; rust = '^[ \t]*(//|/\*|\*)'; c = '^[ \t]*(//|/\*|\*)'; cpp = '^[ \t]*(//|/\*|\*)'; php = '^[ \t]*(//|/\*|\*|#)'
    sql = '^[ \t]*--'; batch = '^[ \t]*(rem\b|::)'
}

# ------------------------------------------------------------------ analisis de un archivo
$script:CsByLang = @{}
$script:CsCommentTokens = @{
    powershell = @('#'); python = @('#'); shell = @('#'); yaml = @('#'); ini = @('#', ';'); toml = @('#'); ruby = @('#'); docker = @('#')
    javascript = @('//', '/*', '*'); typescript = @('//', '/*', '*'); java = @('//', '/*', '*'); csharp = @('//', '/*', '*'); go = @('//', '/*', '*'); rust = @('//', '/*', '*'); c = @('//', '/*', '*'); cpp = @('//', '/*', '*'); php = @('//', '/*', '*', '#')
    sql = @('--'); batch = @('rem', '::')
}
$script:CsRxNonBlank = New-Rx '^[ \t]*\S' 'Multiline'
$script:CsRxLong = New-Rx '^[^\n]{161,}$' 'Multiline'
$script:CsPkBlock = New-Object Text.RegularExpressions.Regex('-----BEGIN [A-Z ]*PRIVATE KEY(?: BLOCK)?-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY(?: BLOCK)?-----|\z)', 'None', [TimeSpan]::FromMilliseconds(500))
$script:CsKeywordLine = New-Object Text.RegularExpressions.Regex('(?i)(?:pass(?:word|wd)?|pwd|secret|token|api_?key|auth|credential|contrase.a|private_?key)\w*["'']?\s*[:=]', 'None', [TimeSpan]::FromMilliseconds(250))
function Mask-Value([string]$v, [string]$kind) {
    '[' + $kind + ' longitud=' + $v.Length + ']'
}
# Sustituye cualquier secreto reconocible dentro de un texto por [tipo]. Se usa antes de mostrar fragmentos o enviarlos al modelo.
function Mask-Text([string]$text) {
    if (-not $text) { return $text }
    # claves privadas: se tapa TODO el bloque (cabecera, cuerpo y pie; si no hay pie, hasta el final del texto)
    try { $text = $script:CsPkBlock.Replace($text, '[private-key]') } catch { return '[contenido no enmascarable: se omite]' }
    foreach ($rule in (Get-CsRules | Where-Object { $_.secret -and $_.id -ne 'private-key' })) {
        $id = $rule.id
        $generic = ($id -eq 'generic-secret' -or $id -eq 'sql-pass')
        try {
            $text = $rule.rx.Replace($text, [Text.RegularExpressions.MatchEvaluator]{
                param($m)
                $val = if ($m.Groups.Count -gt 1 -and $m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Value }
                if ($generic -and $script:CsPlaceholderRx.IsMatch($val)) { return $m.Value }      # al MOSTRAR se tapa aunque la entropia sea baja (hunter2)
                if ($val -match 'EXAMPLE$') { return $m.Value }
                $m.Value.Replace($val, '[' + $id + ']')
            })
        } catch { return '[contenido no enmascarable: se omite]' }          # si una regla no termina, NO se muestra el texto (falla cerrada)
    }
    $text
}
function Test-LowSeverityPath([string]$rel) {
    $r = $rel.ToLowerInvariant()
    ($r -match '(^|\\)(tests?|fixtures?|examples?|samples?|docs?)(\\|$)') -or ($r -match '\.(md|txt|example|sample|template)$')
}
# Evalua UNA regla sobre UNA linea ya localizada. Devuelve el hallazgo o $null. $st lleva el estado compartido de la pasada.
function Test-RuleOnLine($rule, [string]$ln, [int]$i, [string]$rel, [bool]$isComment, [bool]$low, [hashtable]$st) {
    if ($ln.Length -gt 2000 -and -not $rule.secret) { return $null }          # minificado: solo las reglas de secretos se aplican (se evalua la linea completa)
    if ($ln.Contains('santuario:ignore') -and -not $rule.secret -and $rule.sev -ne 'A') { return $null }    # el archivo analizado no puede silenciar secretos ni hallazgos graves
    if ($isComment -and -not $rule.comments) { return $null }
    try { $m = $rule.rx.Match($ln) } catch { $st.timeouts++; return $null }
    if (-not $m.Success) { return $null }
    $sev = $rule.sev
    if ($rule.secret) {
        $val = if ($m.Groups.Count -gt 1 -and $m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Value }
        if ($rule.id -eq 'generic-secret' -or $rule.id -eq 'sql-pass') {
            if ($st.secretLines.ContainsKey($i)) { return $null }          # ya hay un hallazgo especifico en la linea
            if ($script:CsPlaceholderRx.IsMatch($val)) { return $null }
            if ((Get-Entropy $val) -lt 2.8) { return $null }
        } else {
            if ($val.EndsWith('EXAMPLE')) { return $null }
            if ($rule.id -ne 'private-key' -and $script:CsPlaceholderRx.IsMatch($val)) { return $null }
            if ($rule.id -ne 'private-key' -and (Get-Entropy $val) -lt 2.5) { return $null }
        }
        $st.secretLines[$i] = $true
        if ($low -and $sev -eq 'A') { $sev = 'M' }
        return @{ id = $rule.id; sev = $sev; file = $rel; line = ($i + 1); msg = $rule.msg; fix = $rule.fix; masked = (Mask-Value $val $rule.id); secret = $true }
    }
    if ($low -and $sev -eq 'A') { $sev = 'M' }
    # fragmento: se tapa la linea COMPLETA y despues se corta; en lineas con secretos (reconocidos o por palabra clave) no se muestra nada
    $snippet = ''
    if (-not $st.secretLines.ContainsKey($i) -and $ln.Length -le 2000 -and -not $script:CsKeywordLine.IsMatch($ln)) {
        $snippet = Mask-Text (Strip-Terminal $ln.Trim())
        if ($snippet.Length -gt 110) { $snippet = $snippet.Substring(0, 110) + '...' }
    }
    @{ id = $rule.id; sev = $sev; file = $rel; line = ($i + 1); msg = $rule.msg; fix = $rule.fix; snippet = $snippet; secret = $false }
}
function Scan-Text([string]$rel, [string]$lang, [string]$text, [hashtable]$ctx) {
    $findings = New-Object System.Collections.ArrayList
    if (-not $script:CsByLang.ContainsKey($lang)) {
        $script:CsByLang[$lang] = @{ rules = @(Get-CsRules | Where-Object { $_.all -or ($_.langs -contains $lang) }); cpfx = $script:CsCommentPrefix[$lang]; tokens = [string[]]@($script:CsCommentTokens[$lang] | Where-Object { $_ }) }
        $cp = $script:CsByLang[$lang].cpfx
        if ($cp) {
            $script:CsByLang[$lang].cRx = New-Rx $cp 'IgnoreCase'
            $script:CsByLang[$lang].cRxm = New-Rx $cp 'IgnoreCase, Multiline'
            $script:CsByLang[$lang].todoRxm = New-Rx ($cp + '[^\n]*\b(?:TODO|FIXME|HACK|XXX)\b') 'IgnoreCase, Multiline'
        }
    }
    $cache = $script:CsByLang[$lang]
    $applicable = $cache.rules
    $cpfx = $cache.cpfx
    $cRx = $cache.cRx
    $low = Test-LowSeverityPath $rel
    if ($text.IndexOf("`r") -ge 0) { $text = $text.Replace("`r`n", "`n") }
    $lines = $text.Split([char]10)
    # metricas con expresiones sobre el texto completo (todo en .NET, sin recorrer linea por linea en PowerShell)
    if ($script:SkNative) {
        $mt = [Win.SkScan]::Metrics($text, [string[]]$cache.tokens)
        $nonBlank = $mt[0]; $commentLines = $mt[1]; $todo = $mt[2]; $long = $mt[3]
    } else {
        $nonBlank = $script:CsRxNonBlank.Matches($text).Count
        $commentLines = 0; $todo = 0
        if ($cpfx) {
            $commentLines = $cache.cRxm.Matches($text).Count
            $todo = $cache.todoRxm.Matches($text).Count
        }
        $long = $script:CsRxLong.Matches($text).Count
    }
    $codeLines = $nonBlank - $commentLines
    $st = @{ secretLines = @{}; timeouts = 0 }
    $starts = $null
    foreach ($rule in $applicable) {
        if (-not $rule.rxm) { $rule.rxm = New-Rx $rule.pat ($rule.opt + ', Multiline, Compiled') }       # se compila al primer uso (solo las reglas del lenguaje en curso)
        try {                                                              # un archivo hostil no puede abortar el analisis: el tiempo agotado se cuenta y se informa
        $ms = $rule.rxm.Matches($text)
        if ($ms.Count -eq 0) { continue }
        $seen = @{}; $verifyFailed = $false; $n = 0; $got = 0
        if ($null -eq $starts) {                                          # inicio de cada linea (una vez por archivo, solo si hace falta)
            if ($script:SkNative) { $starts = [Win.SkScan]::LineStarts($lines) }
            else { $starts = New-Object 'int[]' $lines.Length; $pos = 0; for ($q = 0; $q -lt $lines.Length; $q++) { $starts[$q] = $pos; $pos += $lines[$q].Length + 1 } }
        }
        foreach ($mm in $ms) {
            if ($n -ge 20000 -or $got -ge 400) { $st.capped = $true; break }; $n++     # el tope cuenta HALLAZGOS (no coincidencias descartadas)
            $i = [Array]::BinarySearch($starts, $mm.Index); if ($i -lt 0) { $i = (-$i) - 2 }
            if ($i -lt 0) { $i = 0 }
            if ($seen.ContainsKey($i)) { continue }; $seen[$i] = $true
            $ln = $lines[$i]
            $isC = ($cRx -and $cRx.IsMatch($ln))
            $f = Test-RuleOnLine $rule $ln $i $rel $isC $low $st
            if ($f) { [void]$findings.Add($f); $got++ } elseif (-not $rule.rx.IsMatch($ln)) { $verifyFailed = $true }
        }
        if ($verifyFailed) {                                               # una coincidencia de varias lineas pudo ocultar otra: se repasa esta regla linea por linea
            for ($i = 0; $i -lt $lines.Length; $i++) {
                if ($seen.ContainsKey($i)) { continue }
                $ln = $lines[$i]; if ($ln.Length -eq 0) { continue }
                if (-not $rule.rx.IsMatch($ln)) { continue }
                $isC = ($cRx -and $cRx.IsMatch($ln))
                $f = Test-RuleOnLine $rule $ln $i $rel $isC $low $st
                if ($f) { [void]$findings.Add($f) }
            }
        }
        } catch { $st.timeouts++; $st.files = $true }
    }
    if ($st.capped) { [void]$findings.Add(@{ id = 'rule-capped'; sev = 'B'; file = $rel; line = 0; msg = 'Demasiadas coincidencias en este archivo: el informe esta recortado'; fix = 'Revisa el archivo a mano'; snippet = ''; secret = $false }) }
    if ($st.timeouts -gt 0) { [void]$findings.Add(@{ id = 'scan-incomplete'; sev = 'M'; file = $rel; line = 0; msg = 'El analisis de este archivo no termino (patron costoso): puede haber hallazgos sin ver'; fix = 'Revisalo a mano'; snippet = ''; secret = $false }) }
    $ctx.regexTimeouts += $st.timeouts
    # HTML: reglas de archivo completo
    if ($lang -eq 'html') {
        if (-not (New-Rx '<html\b[^>]*\blang=' 'IgnoreCase').IsMatch($text)) { [void]$findings.Add(@{ id = 'html-lang'; sev = 'B'; file = $rel; line = 1; msg = 'Falta el atributo lang en <html>'; fix = 'Agrega lang="es"'; snippet = ''; secret = $false }) }
        if (-not (New-Rx '<meta\s+name\s*=\s*["'']viewport["'']' 'IgnoreCase').IsMatch($text)) { [void]$findings.Add(@{ id = 'html-viewport'; sev = 'B'; file = $rel; line = 1; msg = 'Falta la etiqueta viewport (no es responsive)'; fix = 'Agrega <meta name="viewport" content="width=device-width, initial-scale=1">'; snippet = ''; secret = $false }) }
    }
    # Docker: sin USER y con :latest
    if ($lang -eq 'docker') {
        if (-not (New-Rx '^\s*USER\s+(?!root\b)\S+' 'IgnoreCase, Multiline').IsMatch($text)) { [void]$findings.Add(@{ id = 'docker-root'; sev = 'M'; file = $rel; line = 1; msg = 'El contenedor corre como root'; fix = 'Agrega una linea USER con un usuario sin privilegios'; snippet = ''; secret = $false }) }
        $ml = (New-Rx '^\s*FROM\s+\S+:latest\b' 'IgnoreCase, Multiline').Match($text)
        if ($ml.Success) { [void]$findings.Add(@{ id = 'docker-latest'; sev = 'M'; file = $rel; line = 1; msg = 'Imagen base con :latest'; fix = 'Fija una version o digest'; snippet = ''; secret = $false }) }
    }
    $ctx.codeLines += $codeLines; $ctx.commentLines += $commentLines; $ctx.todo += $todo; $ctx.longLines += $long
    # PowerShell: sintaxis y funciones largas con el analizador real (no ejecuta nada)
    if ($lang -eq 'powershell' -and $text.Length -lt 600000) {
        $tok = $null; $err = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tok, [ref]$err)
        foreach ($e in @($err | Select-Object -First 3)) {
            [void]$findings.Add(@{ id = 'ps-syntax'; sev = 'A'; file = $rel; line = [int]$e.Extent.StartLineNumber; msg = ('Error de sintaxis: ' + (Strip-Terminal $e.Message)); fix = 'Corrige la sintaxis'; snippet = ''; secret = $false })
        }
        if ($ast) {
            $fns = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
            foreach ($f in $fns) {
                $len = $f.Extent.EndLineNumber - $f.Extent.StartLineNumber + 1
                if ($len -gt 100) { [void]$findings.Add(@{ id = 'long-function'; sev = 'M'; file = $rel; line = [int]$f.Extent.StartLineNumber; msg = ('Funcion ' + $f.Name + ' muy larga (' + $len + ' lineas)'); fix = 'Dividela en funciones mas pequenas'; snippet = ''; secret = $false }) }
                elseif ($len -gt 50) { [void]$findings.Add(@{ id = 'long-function'; sev = 'B'; file = $rel; line = [int]$f.Extent.StartLineNumber; msg = ('Funcion ' + $f.Name + ' larga (' + $len + ' lineas)'); fix = 'Considera dividirla'; snippet = ''; secret = $false }) }
            }
        }
    }
    if ($lines.Length -gt 500) { [void]$findings.Add(@{ id = 'big-file'; sev = 'B'; file = $rel; line = 1; msg = ('Archivo muy grande (' + $lines.Length + ' lineas)'); fix = 'Dividelo por responsabilidades'; snippet = ''; secret = $false }) }
    # duplicados: ventanas de 5 lineas normalizadas
    if ($lines.Length -le 4000 -and $cpfx) {                              # solo lenguajes de programacion (en JSON/texto seria ruido)
        if (-not $ctx.dupFile) { $ctx.dupFile = @{} }
        if ($script:SkNative -and $ctx.dup -is [System.Collections.Generic.Dictionary[string, int]] -and $ctx.dupFile -is [System.Collections.Generic.Dictionary[string, string]]) {
            [Win.SkScan]::AddDup($lines, $ctx.dup, $ctx.dupFile, $rel, 300000)
        } else {
        $hl = New-Object 'System.Collections.Generic.List[int]'
        foreach ($l in $lines) { if ($l.Length -ge 15) { $n = $l.Trim(); if ($n.Length -ge 15 -and $n -ne '}') { $hl.Add($n.ToLowerInvariant().GetHashCode()) } } }
        $dup = $ctx.dup; $cnt = $hl.Count
        for ($k = 0; $k + 5 -le $cnt; $k++) {
            $key = [string]$hl[$k] + ',' + $hl[$k + 1] + ',' + $hl[$k + 2] + ',' + $hl[$k + 3] + ',' + $hl[$k + 4]
            if ($dup.ContainsKey($key)) { $c = $dup[$key] + 1; $dup[$key] = $c; if ($c -eq 2) { $ctx.dupFile[$key] = $rel } }
            elseif ($dup.Count -lt 300000) { $dup[$key] = 1 }          # tope de memoria en proyectos enormes
        }
        }
    }
    @($findings.ToArray())
}

# ------------------------------------------------------------------ escaneo de carpeta
function Invoke-CodeScan([string]$path, [hashtable]$opts = @{}) {
    Assert-Console
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $inv = Get-FolderInventory $path $opts
    if (-not $inv.ok) { return @{ ok = $false; reason = $inv.reason } }
    $ctx = @{ codeLines = 0; commentLines = 0; todo = 0; longLines = 0; regexTimeouts = 0; dup = (New-Object 'System.Collections.Generic.Dictionary[string,int]'); dupFile = (New-Object 'System.Collections.Generic.Dictionary[string,string]') }
    $all = New-Object System.Collections.ArrayList
    $byLang = @{}; $scanned = 0; $unread = 0
    $budget = if ($opts.time_budget_sec) { [int]$opts.time_budget_sec } else { [int]$script:SkCfg.limits.time_budget_sec }
    $scanTrunc = $false
    foreach ($f in $inv.files) {
        if ($sw.Elapsed.TotalSeconds -gt $budget) { $scanTrunc = $true; break }
        if (($scanned % 25) -eq 24 -and (Test-StopFlag)) { $scanTrunc = $true; break }       # agent\STOP detiene tambien el analisis
        if ($f.size -eq 0) { continue }
        $lang = if ($f.lang) { $f.lang } else { 'text' }
        $rd = Read-FileCore $f.full ([int]$script:SkCfg.limits.max_file_kb)
        if (-not $rd.ok) { $unread++; continue }
        $scanned++
        if ($byLang.ContainsKey($lang)) { $byLang[$lang]++ } else { $byLang[$lang] = 1 }
        $fr = Scan-Text $f.rel $lang $rd.text $ctx
        foreach ($x in $fr) { [void]$all.Add($x) }
    }
    # archivos sensibles por nombre: solo presencia
    foreach ($s in $inv.sensitive) {
        if (-not $s.dir) { [void]$all.Add(@{ id = 'sensitive-file'; sev = 'M'; file = $s.rel; line = 0; msg = ('Archivo sensible presente (no leido): ' + $s.reason); fix = 'Confirma que esta en .gitignore y no se comparte'; snippet = ''; secret = $false }) }
    }
    # duplicados
    $dupGroups = @($ctx.dup.GetEnumerator() | Where-Object { $_.Value -ge 3 } | Sort-Object { $_.Value } -Descending | Select-Object -First 5)
    foreach ($g in $dupGroups) { [void]$all.Add(@{ id = 'duplicate'; sev = 'B'; file = $ctx.dupFile[$g.Key]; line = 0; msg = ('Bloque de 5 lineas repetido ' + $g.Value + ' veces'); fix = 'Extraelo a una funcion comun'; snippet = ''; secret = $false }) }
    $sw.Stop()
    $order = @{ A = 0; M = 1; B = 2 }
    $sorted = @($all.ToArray() | Sort-Object @{ e = { $order[$_.sev] } }, @{ e = { $_.file } }, @{ e = { $_.line } })
    $c = @{ A = 0; M = 0; B = 0 }; foreach ($x in $sorted) { $c[$x.sev]++ }
    $ratio = if ($ctx.codeLines + $ctx.commentLines -gt 0) { [math]::Round(100.0 * $ctx.commentLines / ($ctx.codeLines + $ctx.commentLines), 1) } else { 0 }
    @{ ok = $true; root = $inv.root; findings = $sorted; counts = $c; scanned = $scanned; unread = $unread; byLang = $byLang
       metrics = @{ code_lines = $ctx.codeLines; comment_lines = $ctx.commentLines; comment_pct = $ratio; todo = $ctx.todo; long_lines = $ctx.longLines; regex_timeouts = $ctx.regexTimeouts }
       noise_names = $inv.noise_names; sensitive_dirs = @($inv.sensitive | Where-Object { $_.dir } | ForEach-Object { $_.rel } | Select-Object -First 15)
       inventory = $inv.counts; truncated = ($inv.truncated -or $scanTrunc); truncated_by = $(if ($scanTrunc) { 'tiempo o STOP' } else { $inv.truncated_by }); elapsed_ms = [int]$sw.ElapsedMilliseconds }
}

# ------------------------------------------------------------------ informe
function Format-ScanReport($res, [int]$maxLines = 60) {
    $o = New-Object System.Collections.ArrayList
    if (-not $res.ok) { return @('No se pudo analizar: ' + $res.reason) }
    [void]$o.Add(('Carpeta: ' + $res.root))
    $langs = ($res.byLang.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { $_.Key + ' ' + $_.Value }) -join ', '
    [void]$o.Add(('Archivos analizados: ' + $res.scanned + '  (' + $langs + ')   omitidos binarios/enlaces/ruido: ' + ($res.inventory.skipped_binary + $res.inventory.skipped_links + $res.inventory.skipped_noise)))
    [void]$o.Add(('Lineas de codigo: ' + $res.metrics.code_lines + '   comentarios: ' + $res.metrics.comment_pct + '%   TODO/FIXME: ' + $res.metrics.todo + '   lineas largas: ' + $res.metrics.long_lines))
    [void]$o.Add(('Hallazgos: ' + $res.counts.A + ' altos, ' + $res.counts.M + ' medios, ' + $res.counts.B + ' bajos   (' + $res.elapsed_ms + ' ms)'))
    if ($res.truncated) { [void]$o.Add(('AVISO: resultado parcial, se alcanzo el limite de ' + $res.truncated_by)) }
    # cobertura: lo que NO se miro, para que un informe limpio no parezca mas completo de lo que es
    $inv = $res.inventory; $cov = New-Object System.Collections.ArrayList
    if ($inv.skipped_big -gt 0) { [void]$cov.Add(($inv.skipped_big.ToString() + ' archivos muy grandes (> ' + $script:SkCfg.limits.max_file_kb + ' KB)')) }
    if ($inv.skipped_error -gt 0) { [void]$cov.Add(($inv.skipped_error.ToString() + ' rutas ilegibles (permisos o ruta muy larga)')) }
    if ($res.unread -gt 0) { [void]$cov.Add(($res.unread.ToString() + ' archivos binarios o ilegibles')) }
    if ($inv.skipped_links -gt 0) { [void]$cov.Add(($inv.skipped_links.ToString() + ' enlaces/junctions (no se siguen)')) }
    if ($res.metrics.regex_timeouts -gt 0) { [void]$cov.Add(($res.metrics.regex_timeouts.ToString() + ' patrones que no terminaron')) }
    if ($cov.Count -gt 0) { [void]$o.Add('NO analizado: ' + ($cov -join '; ')) }
    if ($res.noise_names -and @($res.noise_names).Count -gt 0) { [void]$o.Add('Carpetas omitidas por ser dependencias/compilacion: ' + (Strip-Terminal (@($res.noise_names) -join ', ')) + ' (ahi pueden quedar secretos de compilaciones)') }
    if ($res.sensitive_dirs -and @($res.sensitive_dirs).Count -gt 0) { [void]$o.Add('Carpetas omitidas por nombre sensible/de sistema: ' + (Strip-Terminal (@($res.sensitive_dirs) -join ', '))) }
    $sn = 0
    foreach ($x in $res.findings) {
        if ($sn -ge $maxLines) { [void]$o.Add(('... y ' + ($res.findings.Count - $sn) + ' hallazgos mas (ver el informe guardado)')); break }
        $sev = switch ($x.sev) { 'A' { 'ALTO ' } 'M' { 'MEDIO' } default { 'BAJO ' } }
        $fileSafe = Strip-Terminal $x.file
        $loc = if ($x.line -gt 0) { $fileSafe + ':' + $x.line } else { $fileSafe }
        $extra = if ($x.secret) { '  ' + $x.masked } elseif ($x.snippet) { '  > ' + $x.snippet } else { '' }
        [void]$o.Add(('[' + $sev + '] ' + $loc + '  ' + $x.msg + $extra))
        $sn++
    }
    if ($res.counts.A -gt 0 -and @($res.findings | Where-Object { $_.secret }).Count -gt 0) { [void]$o.Add('Si hay secretos: rotalos (cambiarlos) ademas de quitarlos del archivo; el valor nunca se muestra aqui.') }
    @($o.ToArray())
}
function Save-ScanReport($res, [string]$kind = 'codigo') {
    Assert-Console
    $dir = Join-Path (Get-WorkspaceRoot) 'informes'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    $name = 'informe-' + $kind + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt'
    $full = Join-Path $dir $name
    $lines = Format-ScanReport $res 100000
    $enc = New-Object Text.UTF8Encoding($true)
    [IO.File]::WriteAllText($full, ($lines -join "`r`n") + "`r`n", $enc)
    $full
}
