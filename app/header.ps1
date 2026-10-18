# Santuario - encabezado fijo en ANSI art (Zeus + SANTUARIO) que ocupa ~25% de la altura de la terminal.
# El resto de la terminal es una region de scroll para escribir. Se calcula en vivo segun el tamano de la ventana.
# Solo ASCII a proposito.
Add-Type -AssemblyName System.Drawing
Add-Type -Namespace Win -Name Con -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int h); [DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint m); [DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint m);'

$script:HdrOn = $false; $script:HdrRows = 0; $script:HdrW = 0; $script:HdrH = 0
$script:Esc = [char]27

function Enable-VT {
    $h = [Win.Con]::GetStdHandle(-11); $m = [uint32]0
    if ([Win.Con]::GetConsoleMode($h, [ref]$m)) { [void][Win.Con]::SetConsoleMode($h, ($m -bor 4)); return $true }
    return $false
}

# Fuente 5x7 para el rotulo grande
$script:Font = @{
    S = @('.####', '#....', '#....', '.###.', '....#', '....#', '####.')
    A = @('.###.', '#...#', '#...#', '#####', '#...#', '#...#', '#...#')
    N = @('#...#', '##..#', '#.#.#', '#..##', '#...#', '#...#', '#...#')
    T = @('#####', '..#..', '..#..', '..#..', '..#..', '..#..', '..#..')
    U = @('#...#', '#...#', '#...#', '#...#', '#...#', '#...#', '.###.')
    R = @('####.', '#...#', '#...#', '####.', '#.#..', '#..#.', '#...#')
    I = @('#####', '..#..', '..#..', '..#..', '..#..', '..#..', '#####')
    O = @('.###.', '#...#', '#...#', '#...#', '#...#', '#...#', '.###.')
}
$script:TextW = 54   # 9 letras * 5 + 8 espacios + 1 de sombra
$script:TextRows = 4

function Build-TextMatrix {
    $w = $script:TextW; $h = 8
    $m = New-Object 'int[,]' $h, $w
    $word = 'SANTUARIO'
    for ($pass = 1; $pass -le 2; $pass++) {
        for ($i = 0; $i -lt $word.Length; $i++) {
            $rows = $script:Font[[string]$word[$i]]
            for ($gy = 0; $gy -lt 7; $gy++) {
                for ($gx = 0; $gx -lt 5; $gx++) {
                    if ($rows[$gy][$gx] -ne '#') { continue }
                    $x = $i * 6 + $gx
                    if ($pass -eq 1) { $m[$gy, $x] = 1 }
                    elseif ($m[($gy + 1), ($x + 1)] -eq 0) { $m[($gy + 1), ($x + 1)] = 2 }
                }
            }
        }
    }
    , $m
}

function Text-Color([int]$code, [int]$y) {
    if ($code -eq 1) {       # degradado cian
        $t = [math]::Min(1.0, $y / 6.0)
        return ('0;{0};{1}' -f [int](235 - 85 * $t), [int](255 - 45 * $t))
    }
    if ($code -eq 2) { return '0;65;90' }
    return '0;0;0'
}

function Build-Header([int]$W, [int]$R) {
    $esc = $script:Esc; $half = [char]0x2580
    $fh = 2 * $R
    $fw = [int][math]::Round($fh * 512.0 / 232.0)
    $img = [System.Drawing.Image]::FromFile((Join-Path $PSScriptRoot 'splash\zeus.jpg'))
    $bmp = New-Object System.Drawing.Bitmap $fw, $fh
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $dst = New-Object System.Drawing.Rectangle 0, 0, $fw, $fh
    $g.DrawImage($img, $dst, 0, 0, 512, 232, [System.Drawing.GraphicsUnit]::Pixel)   # solo la cara, sin el rotulo
    $g.Dispose(); $img.Dispose()

    $tm = Build-TextMatrix
    $gap = 3
    $used = $fw + $gap + $script:TextW
    $padL = [math]::Max(0, [int][math]::Floor(($W - 1 - $used) / 2))
    $padR = [math]::Max(0, $W - 1 - $padL - $used)
    $ty = [int][math]::Floor(($R - $script:TextRows) / 2) - 1
    if ($ty -lt 0) { $ty = 0 }
    $sub = 'cerebro local y port' + [char]0x00E1 + 'til'
    $black = "$esc[48;2;0;0;0m"
    $rowsOut = New-Object System.Collections.Generic.List[string]

    for ($ri = 0; $ri -lt $R; $ri++) {
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append($black); [void]$sb.Append(' ' * $padL)
        $lf = ''; $lb = ''
        for ($x = 0; $x -lt $fw; $x++) {            # cara de Zeus
            $t = $bmp.GetPixel($x, 2 * $ri); $b = $bmp.GetPixel($x, 2 * $ri + 1)
            $f = '{0};{1};{2}' -f $t.R, $t.G, $t.B; $k = '{0};{1};{2}' -f $b.R, $b.G, $b.B
            if ($f -ne $lf) { [void]$sb.Append("$esc[38;2;${f}m"); $lf = $f }
            if ($k -ne $lb) { [void]$sb.Append("$esc[48;2;${k}m"); $lb = $k }
            [void]$sb.Append($half)
        }
        [void]$sb.Append($black); [void]$sb.Append(' ' * $gap)
        $tr = $ri - $ty
        if ($tr -ge 0 -and $tr -lt $script:TextRows) {      # SANTUARIO en bloques
            $lf = ''; $lb = ''
            for ($x = 0; $x -lt $script:TextW; $x++) {
                $ct = $tm[(2 * $tr), $x]; $cb = $tm[(2 * $tr + 1), $x]
                if ($ct -eq 0 -and $cb -eq 0) {
                    if ($lb -ne '0;0;0') { [void]$sb.Append($black); $lb = '0;0;0' }
                    [void]$sb.Append(' '); continue
                }
                $f = Text-Color $ct (2 * $tr); $k = Text-Color $cb (2 * $tr + 1)
                if ($f -ne $lf) { [void]$sb.Append("$esc[38;2;${f}m"); $lf = $f }
                if ($k -ne $lb) { [void]$sb.Append("$esc[48;2;${k}m"); $lb = $k }
                [void]$sb.Append($half)
            }
            [void]$sb.Append($black)
        } elseif ($tr -eq $script:TextRows + 1) {            # subtitulo
            [void]$sb.Append("$esc[38;2;90;160;175m" + $sub.PadRight($script:TextW))
        } else {
            [void]$sb.Append(' ' * $script:TextW)
        }
        [void]$sb.Append($black); [void]$sb.Append(' ' * $padR); [void]$sb.Append("$esc[0m")
        $rowsOut.Add($sb.ToString())
    }
    $bmp.Dispose()
    , $rowsOut
}

# $Fixed = $false (por defecto): el banner se imprime una vez arriba y la conversacion usa el scroll normal de la terminal.
# $Fixed = $true: el banner queda anclado (region de scroll), pero la terminal NO guarda historial de lo que se desplaza.
function Show-Header([bool]$Fixed = $false) {
    if (-not (Test-Path (Join-Path $PSScriptRoot 'splash\zeus.jpg'))) { return $false }
    if (-not (Enable-VT)) { return $false }
    try { $W = [Console]::WindowWidth; $H = [Console]::WindowHeight } catch { return $false }
    if ($H -lt 24 -or $W -lt 90) { return $false }
    $R = [int][math]::Round($H * 0.25)
    $maxR = [int][math]::Floor(($W - 1 - 3 - $script:TextW) / 4.41)    # la cara + el rotulo tienen que caber a lo ancho
    if ($R -gt $maxR) { $R = $maxR }
    if ($R -lt 7) { return $false }
    $esc = $script:Esc
    $rows = Build-Header $W $R
    if (-not $Fixed) {
        [Console]::Write("$esc[0m$esc[2J$esc[H")
        foreach ($row in $rows) { [Console]::WriteLine($row); Start-Sleep -Milliseconds 35 }
        return $true
    }
    [Console]::Write("$esc[0m$esc[2J$esc[H$esc[?25l")
    for ($i = 0; $i -lt $rows.Count; $i++) {
        [Console]::Write("$esc[$($i + 1);1H" + $rows[$i])
        Start-Sleep -Milliseconds 35
    }
    $script:HdrOn = $true; $script:HdrRows = $R; $script:HdrW = $W; $script:HdrH = $H
    Set-Status 'iniciando...'
    # Region de scroll: todo lo que se escriba queda debajo del encabezado y de la linea de estado
    [Console]::Write("$esc[$($R + 2);${H}r$esc[$($R + 2);1H$esc[?25h")
    return $true
}

function Set-Status([string]$text) {
    if (-not $script:HdrOn) { return }
    $esc = $script:Esc
    $line = ' ' + $text
    if ($line.Length -gt $script:HdrW - 1) { $line = $line.Substring(0, $script:HdrW - 1) }
    $line = $line.PadRight($script:HdrW - 1)
    [Console]::Write("$($esc)7$esc[$($script:HdrRows + 1);1H$esc[48;2;10;28;36m$esc[38;2;120;215;230m$line$esc[0m$($esc)8")
}

function Reset-Header {
    if (-not $script:HdrOn) { return }
    $esc = $script:Esc
    [Console]::Write("$esc[r$esc[$($script:HdrH);1H$esc[0m$esc[?25h")
    $script:HdrOn = $false
}
