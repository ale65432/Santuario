# Medicion de rendimiento de las habilidades del taller con presupuestos. Uso (dentro de app\env.bat): powershell -File bench.ps1
# Genera un proyecto sintetico en NTFS, lo analiza y reporta tiempos, memoria y falsos positivos. ASCII.
param([int]$Files = 300, [int]$LinesPerFile = 120)
$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$App = Join-Path $Root 'app'; $Ag = Join-Path $Root 'agent'
$sw0 = [Diagnostics.Stopwatch]::StartNew()
. (Join-Path $App 'lib.ps1')
. (Join-Path $Ag 'hands.ps1')
. (Join-Path $Ag 'skills\skills.ps1')
$loadMs = $sw0.ElapsedMilliseconds
$script:Origin = 'consola'
$fail = 0
function Budget([string]$name, [double]$val, [double]$max, [string]$unit) {
    $ok = $val -le $max
    if (-not $ok) { $script:fail++ }
    ('{0,-46} {1,10} {2,-4} (presupuesto {3} {2}) {4}' -f $name, $val, $unit, $max, $(if ($ok) { 'OK' } else { 'EXCEDE' }))
}

$T = Join-Path (Get-RealFolders).UserProfile ('santuario-bench-' + $PID)
New-Item -ItemType Directory -Force $T | Out-Null
$rnd = New-Object Random 42
$js = "function handler{0}(req, res) {{`n  const items = req.body.items || [];`n  for (let i = 0; i < items.length; i++) {{`n    if (items[i].price > 100) {{ items[i].flag = true; }}`n  }}`n  // TODO: validar la entrada`n  return res.json({{ ok: true, count: items.length }});`n}}`n"
$ps = "function Get-Thing{0} {{`n  param([string]`$Name, [int]`$Count = 3)`n  `$out = @()`n  foreach (`$i in 1..`$Count) {{ `$out += (`$Name + `$i) }}`n  return `$out`n}}`n"
$py = "def compute_{0}(values):`n    total = 0`n    for v in values:`n        if v % 2 == 0:`n            total += v`n    return total`n"
$planted = 0
for ($f = 0; $f -lt $Files; $f++) {
    $sub = Join-Path $T ('mod' + ($f % 12))
    if (-not (Test-Path -LiteralPath $sub)) { New-Item -ItemType Directory -Force $sub | Out-Null }
    $sb = New-Object Text.StringBuilder
    $kind = $f % 3
    $n = [int]($LinesPerFile / 8)
    for ($k = 0; $k -lt $n; $k++) {
        if ($kind -eq 0) { [void]$sb.Append(($js -f ($f * 100 + $k))) } elseif ($kind -eq 1) { [void]$sb.Append(($ps -f ($f * 100 + $k))) } else { [void]$sb.Append(($py -f ($f * 100 + $k))) }
    }
    $ext = @('js', 'ps1', 'py')[$kind]
    if ($f % 25 -eq 0) { [void]$sb.AppendLine($(if ($kind -eq 0) { 'const r = eval(input);' } elseif ($kind -eq 1) { 'Invoke-Expression $cmd' } else { 'obj = pickle.loads(data)' })); $planted++ }
    [IO.File]::WriteAllText((Join-Path $sub ('file' + $f + '.' + $ext)), $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
}
$totalKB = [int]((Get-ChildItem -LiteralPath $T -Recurse -File | Measure-Object Length -Sum).Sum / 1KB)
"Proyecto sintetico: $Files archivos, ~$totalKB KB, $planted fallos plantados"

$g = Add-SessionGrant $T 'read'
$m0 = [GC]::GetTotalMemory($true)
$sw = [Diagnostics.Stopwatch]::StartNew(); $inv = Get-FolderInventory $g; $invMs = $sw.ElapsedMilliseconds
$sw.Restart(); $res = Invoke-CodeScan $g; $scanMs = $sw.ElapsedMilliseconds
$sw.Restart(); $rep = Format-ScanReport $res 60; $repMs = $sw.ElapsedMilliseconds
$m1 = [GC]::GetTotalMemory($false)
$sw.Restart(); $res2 = Invoke-CodeScan $g; $scan2Ms = $sw.ElapsedMilliseconds
$found = @($res.findings | Where-Object { $_.id -in 'js-eval', 'ps-iex', 'py-pickle' }).Count
$fp = @($res.findings | Where-Object { $_.sev -eq 'A' -and $_.id -notin 'js-eval', 'ps-iex', 'py-pickle' }).Count
$kb = [math]::Max(1, $totalKB)
''
Budget 'carga de las habilidades' $loadMs 4000 'ms'
Budget ('inventario ' + $Files + ' archivos') $invMs 2000 'ms'
Budget ('analisis completo ' + $Files + ' archivos') $scanMs 10000 'ms'
Budget 'analisis repetido (cache tibia)' $scan2Ms 10000 'ms'
Budget 'velocidad de analisis' ([math]::Round($totalKB / [math]::Max(0.001, $scanMs / 1000.0), 1) * -1) -40 'KB/s(neg)'
Budget 'informe' $repMs 500 'ms'
Budget 'memoria extra' ([int](($m1 - $m0) / 1MB)) 150 'MB'
Budget 'fallos plantados NO detectados' ($planted - $found) 0 'n'
Budget 'falsos positivos altos' $fp 0 'n'
$sw.Restart(); $pc = Invoke-PcScan; $pcMs = $sw.ElapsedMilliseconds
Budget 'revision del PC' $pcMs 40000 'ms'
$spec = (Test-SiteSpec (Get-DesignJson 'examples.json').landing).spec
$sw.Restart(); for ($i = 0; $i -lt 5; $i++) { $h = Build-SiteHtml $spec; $c = Build-SiteCss $spec; $e = Test-GeneratedSite $h $c $spec }; $webMs = [int]($sw.ElapsedMilliseconds / 5)
Budget 'generar+validar una pagina' $webMs 1500 'ms'
$sw.Restart(); $x = 0; for ($i = 0; $i -lt 50; $i++) { if (Parse-SkillIntent 'analiza el codigo de la carpeta C:\proyectos\tienda') { $x++ } }; $intMs = [int]($sw.ElapsedMilliseconds / 50)
Budget 'reconocer una frase' $intMs 50 'ms'
Remove-Item -LiteralPath $T -Recurse -Force -ErrorAction SilentlyContinue
''
$script:fail.ToString() + ' presupuestos excedidos'
