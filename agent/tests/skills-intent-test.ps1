# Pruebas de reconocimiento de frases y de aislamiento (el demonio/Telegram no pueden usar las habilidades). ASCII.
# Uso (dentro de app\env.bat): powershell -File skills-intent-test.ps1
$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$App = Join-Path $Root 'app'; $Ag = Join-Path $Root 'agent'
. (Join-Path $App 'lib.ps1')
. (Join-Path $Ag 'hands.ps1')
. (Join-Path $Ag 'skills\skills.ps1')
$pass = 0; $fail = 0
function Check([string]$name, $got, $want) { if ("$got" -eq "$want") { $script:pass++ } else { $script:fail++; "FALLA: $name -> obtuve '$got', esperaba '$want'" } }
function Intent([string]$q) { $i = Parse-SkillIntent $q; if ($i) { $i.skill } else { 'ninguna' } }

# ---- positivos
Check 'analiza carpeta' (Intent 'analiza el codigo de la carpeta C:\proyectos\tienda') 'analizar'
Check 'analizame proyecto' (Intent 'analizame el proyecto que esta en C:\dev\api') 'analizar'
Check 'revisa codigo' (Intent 'revisa el codigo de C:\Users\Usuario\app') 'analizar'
Check 'escanea el codigo' (Intent 'escanea el codigo de la carpeta "C:\mi proyecto"') 'analizar'
Check 'ruta con acentos y mayusculas' (Intent ('Analiza el c' + [char]0xF3 + 'digo de la carpeta C:\Proyectos\Cafeter' + [char]0xED + 'a')) 'analizar'
Check 'seguridad de mi pc' (Intent 'revisa la seguridad de mi pc') 'escanear'
Check 'escaneo de seguridad' (Intent 'haz un escaneo de seguridad de mi computadora') 'escanear'
Check 'escaneo corto' (Intent 'escaneo de seguridad') 'escanear'
Check 'esta seguro mi pc' (Intent 'esta seguro mi pc?') 'escanear'
Check 'audita mi equipo' (Intent 'audita la seguridad de mi equipo') 'escanear'
Check 'crea pagina web' (Intent 'crea una pagina web para mi cafeteria con menu y horarios') 'web'
Check 'crear archivo' (Intent 'crea un archivo notas.txt con el texto comprar leche') 'crear'
Check 'crear carpeta' (Intent 'crea una carpeta Proyectos') 'crear'
Check 'crear script' (Intent 'hazme un script de powershell que liste mis descargas') 'crear'
Check 'escribeme un documento' (Intent 'escribeme un documento sobre mis metas del ano') 'crear'
Check 'crear nota' (Intent 'redactame una nota para el equipo') 'crear'
Check 'crear no secuestra codigo pegado' (Intent "crea un script`nfunction a() { return 1; }") 'ninguna'
Check 'hazme sitio web' (Intent 'hazme un sitio web de mi taller mecanico') 'web'
Check 'genera landing' (Intent 'genera una landing page para mi curso de guitarra') 'web'
Check 'quiero una pagina' (Intent 'quiero una pagina web sobre mi portafolio de fotografia') 'web'
Check 'mejora codigo' (Intent 'mejora el codigo de C:\proyectos\app.js') 'mejorar'
Check 'arregla script' (Intent 'arregla el script C:\scripts\backup.ps1') 'mejorar'
Check 'lee archivo' (Intent 'lee el archivo C:\notas\ideas.txt') 'leer'
Check 'muestrame documento' (Intent 'muestrame el documento C:\notas\ideas.txt') 'leer'
# ---- argumentos
Check 'arg: ruta' (Parse-SkillIntent 'analiza el codigo de la carpeta C:\proyectos\tienda').arg 'C:\proyectos\tienda'
Check 'arg: ruta con espacios entre comillas' (Parse-SkillIntent 'analiza el codigo de la carpeta "C:\mi proyecto\src"').arg 'C:\mi proyecto\src'
Check 'arg: punto final' (Parse-SkillIntent 'analiza el codigo de C:\dev\api.').arg 'C:\dev\api'
Check 'arg: sin ruta' (Parse-SkillIntent 'analiza el codigo de mi proyecto').arg ''
Check 'arg: escritorio' ((Parse-SkillIntent 'analiza el codigo de mi escritorio').arg -like '*Desktop') $true
Check 'arg: descargas' ((Parse-SkillIntent 'analiza los archivos de descargas').arg -like '*Downloads') $true
Check 'explicar detectado' ([bool](Parse-SkillIntent 'analiza el codigo de C:\dev y explicame los hallazgos').explain) $true
Check 'web: arg es la peticion' (Parse-SkillIntent 'crea una pagina web para mi cafeteria').arg 'crea una pagina web para mi cafeteria'
# ---- negativos: no deben secuestrar otras ordenes
Check 'abre youtube' (Intent 'abre youtube') 'ninguna'
Check 'abre una pagina web' (Intent 'abre una pagina web de recetas') 'ninguna'
Check 'quiero ver una pagina' (Intent 'quiero ver una pagina web de gatos') 'ninguna'
Check 'busca pagina' (Intent 'busca una pagina para comprar zapatos') 'ninguna'
Check 'pregunta general' (Intent 'que es la seguridad informatica') 'ninguna'
Check 'saludo' (Intent 'hola como estas') 'ninguna'
Check 'recordatorio' (Intent 'recuerdame manana a las 9 revisar el codigo') 'ninguna'
Check 'texto largo' (Intent ('analiza el codigo ' + ('x' * 700))) 'ninguna'
Check 'vacio' (Intent '') 'ninguna'
Check 'codigo pegado' (Intent 'function a(){ return 1 }') 'ninguna'
Check 'explica este codigo' (Intent 'explicame este codigo: for(i=0;i<3;i++){}') 'ninguna'
Check 'seguridad sin pc' (Intent 'revisa la seguridad de mi sitio web') 'ninguna'
Check 'haz un resumen de una pagina' (Intent 'haz un resumen de la pagina web de la biblioteca') 'ninguna'
Check 'explica la pagina' (Intent 'explicame como funciona una pagina web de comercio') 'ninguna'
Check 'codigo pegado multilinea' (Intent ("mejora este codigo`nfunction a() { return 1; }")) 'ninguna'
Check 'codigo pegado una linea' (Intent 'mejora el codigo: for (i=0;i<3;i++){ x=1; }') 'ninguna'
Check 'quiero ver (no crear)' (Intent 'quiero una respuesta sobre la pagina web de google') 'ninguna'

# ---- comandos con barra: no atiende lo que no es suyo
Check 'comando ajeno' (Handle-SkillCommand '/tareas' '/tareas') $false
Check 'comando ajeno 2' (Handle-SkillCommand '/manos' '/manos') $false
Check 'prefijo parecido' (Handle-SkillCommand '/webcam' '/webcam') $false

# ---- aislamiento: el demonio, Telegram y las tareas no cargan ni nombran las habilidades
foreach ($f in 'daemon.ps1', 'telegram.ps1', 'tasks.ps1') {
    $txt = [IO.File]::ReadAllText((Join-Path $Ag $f))
    Check ("aislamiento: $f no carga skills") ($txt -match 'skills[\\/]') $false
    Check ("aislamiento: $f no llama a funciones del taller") ($txt -match 'Invoke-CodeScan|Invoke-PcScan|Apply-ChangeSet|Invoke-WebBuild|Read-FileSafe|Request-Grant') $false
}
$dm = [IO.File]::ReadAllText((Join-Path $Ag 'daemon.ps1'))
Check 'el demonio fija origen remoto/tarea' ($dm -match "Origin\s*=\s*'(remoto|tarea)'") $true
# todas las funciones publicas del taller exigen consola
foreach ($fn in 'Resolve-SafePath', 'Read-FileSafe', 'Get-FolderInventory', 'Invoke-CodeScan', 'Invoke-PcScan', 'Apply-ChangeSet', 'Undo-LastChange', 'Invoke-WebBuild', 'New-Site', 'Add-SessionGrant', 'Request-Grant', 'Save-ScanReport') {
    $body = (Get-Command $fn).ScriptBlock.ToString()
    Check ("exige consola: $fn") ($body -match 'Assert-Console') $true
}
$script:Origin = 'tarea'
foreach ($fn in 'Invoke-PcScan', 'Undo-LastChange', 'Get-WorkspaceRoot') {
    $thr = $false; try { & $fn | Out-Null } catch { $thr = $true }
    if ($fn -ne 'Get-WorkspaceRoot') { Check ("origen tarea bloqueado: $fn") $thr $true }
}
$script:Origin = 'consola'
"RESULTADO: $pass pasaron, $fail fallaron"
