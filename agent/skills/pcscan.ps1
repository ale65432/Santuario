# Santuario - habilidad "revisar la seguridad de ESTE PC": postura de Windows en SOLO LECTURA. PowerShell 5.1, ASCII.
# Principios: lista cerrada de comprobaciones; sin elevar; no cambia nada; no escanea otros equipos ni la red; de los secretos solo informa
# si EXISTEN (nunca el valor); lo que viene del sistema (nombres de tareas, programas) se trata como texto no confiable.

function New-Check([string]$id, [string]$titulo, [string]$estado, [string]$detalle, [string]$consejo = '') {
    @{ id = $id; titulo = $titulo; estado = $estado; detalle = (Strip-Terminal $detalle); consejo = $consejo }
}
function Safe-Check([string]$id, [string]$titulo, [scriptblock]$body) {
    try { & $body } catch { New-Check $id $titulo 'nd' 'No se pudo comprobar (puede requerir administrador).' }
}
function Get-RegValue([string]$key, [string]$name) {
    try { $k = Get-Item -LiteralPath $key -ErrorAction Stop; $k.GetValue($name, $null) } catch { $null }
}
function Get-ExeOnly([string]$cmd) {                       # ruta del ejecutable sin argumentos (los argumentos pueden llevar contrasenas)
    if (-not $cmd) { return '' }
    $c = $cmd.Trim()
    if ($c.StartsWith('"')) { $i = $c.IndexOf('"', 1); if ($i -gt 0) { return $c.Substring(1, $i - 1) } }
    $m = [regex]::Match($c, '^[A-Za-z]:\\[^"]*?\.(?:exe|bat|cmd|ps1|vbs|js|com|scr|lnk)', 'IgnoreCase')
    if ($m.Success) { return $m.Value }
    ($c -split '\s+')[0]
}
function Test-RiskyPath([string]$p) { $p -match '(?i)\\(AppData|Temp|Downloads|Users\\Public)\\' }

function Invoke-PcScan {
    Assert-Console
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = New-Object System.Collections.ArrayList
    $add = { param($c) [void]$r.Add($c) }

    & $add (Safe-Check 'defender' 'Antivirus (Microsoft Defender)' {
        $s = Get-MpComputerStatus -ErrorAction Stop
        if (-not $s.AntivirusEnabled -or -not $s.RealTimeProtectionEnabled) { New-Check 'defender' 'Antivirus (Microsoft Defender)' 'alto' ('Proteccion en tiempo real: ' + $s.RealTimeProtectionEnabled + ', antivirus activo: ' + $s.AntivirusEnabled) 'Activa la proteccion en tiempo real en Seguridad de Windows.' }
        else { New-Check 'defender' 'Antivirus (Microsoft Defender)' 'ok' 'Activo con proteccion en tiempo real.' }
    })
    & $add (Safe-Check 'firmas' 'Firmas del antivirus' {
        $s = Get-MpComputerStatus -ErrorAction Stop
        $age = [int]$s.AntivirusSignatureAge
        if ($age -gt 7) { New-Check 'firmas' 'Firmas del antivirus' 'alto' ("Tienen $age dias.") 'Actualiza en Windows Update.' }
        elseif ($age -gt 3) { New-Check 'firmas' 'Firmas del antivirus' 'aviso' ("Tienen $age dias.") 'Actualiza en Windows Update.' }
        else { New-Check 'firmas' 'Firmas del antivirus' 'ok' ("Tienen $age dias.") }
    })
    & $add (Safe-Check 'escaneo' 'Ultimo escaneo rapido' {
        $s = Get-MpComputerStatus -ErrorAction Stop
        $age = [int]$s.QuickScanAge
        if ($age -gt 14 -and $age -lt 65000) { New-Check 'escaneo' 'Ultimo escaneo rapido' 'aviso' ("Hace $age dias.") 'Ejecuta un escaneo rapido.' } else { New-Check 'escaneo' 'Ultimo escaneo rapido' 'ok' ("Hace $age dias.") }
    })
    & $add (Safe-Check 'firewall' 'Firewall de Windows' {
        $off = @(Get-NetFirewallProfile -ErrorAction Stop | Where-Object { -not $_.Enabled } | ForEach-Object { [string]$_.Name })
        if ($off.Count -gt 0) { New-Check 'firewall' 'Firewall de Windows' 'alto' ('Desactivado en: ' + ($off -join ', ')) 'Activa el firewall en todos los perfiles.' } else { New-Check 'firewall' 'Firewall de Windows' 'ok' 'Activo en todos los perfiles.' }
    })
    & $add (Safe-Check 'puertos' 'Servicios escuchando en la red' {
        $sens = @(21, 23, 135, 139, 445, 3389, 5900)
        $l = @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object { $_.LocalAddress -in '0.0.0.0', '::' })
        $hit = @($l | Where-Object { $sens -contains $_.LocalPort } | ForEach-Object { [int]$_.LocalPort } | Sort-Object -Unique)
        if ($hit.Count -gt 0) { New-Check 'puertos' 'Servicios escuchando en la red' 'aviso' ('Puertos sensibles abiertos a toda la red: ' + ($hit -join ', ') + '. Total escuchando: ' + $l.Count) 'Cierra o restringe los servicios que no uses (SMB/RDP...).' }
        else { New-Check 'puertos' 'Servicios escuchando en la red' 'ok' ('Sin puertos sensibles abiertos. Total escuchando en todas las interfaces: ' + $l.Count) }
    })
    & $add (Safe-Check 'rdp' 'Escritorio remoto (RDP)' {
        $v = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' 'fDenyTSConnections'
        if ($null -eq $v) { New-Check 'rdp' 'Escritorio remoto (RDP)' 'nd' 'No se pudo leer.' }
        elseif ([int]$v -eq 0) {
            $nla = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' 'UserAuthentication'
            if ($nla -eq 1) { New-Check 'rdp' 'Escritorio remoto (RDP)' 'aviso' 'Activado (con autenticacion NLA).' 'Desactivalo si no lo usas.' } else { New-Check 'rdp' 'Escritorio remoto (RDP)' 'alto' 'Activado SIN autenticacion NLA.' 'Desactivalo o exige NLA.' }
        } else { New-Check 'rdp' 'Escritorio remoto (RDP)' 'ok' 'Desactivado.' }
    })
    & $add (Safe-Check 'smb1' 'SMB version 1' {
        $v = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' 'SMB1'
        if ($null -ne $v -and [int]$v -eq 1) { New-Check 'smb1' 'SMB version 1' 'alto' 'Activado.' 'Desactiva SMB1 (protocolo obsoleto y vulnerable).' } else { New-Check 'smb1' 'SMB version 1' 'ok' 'No esta activado explicitamente.' }
    })
    & $add (Safe-Check 'uac' 'Control de cuentas de usuario (UAC)' {
        $v = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableLUA'
        if ($null -ne $v -and [int]$v -eq 0) { New-Check 'uac' 'Control de cuentas de usuario (UAC)' 'alto' 'Desactivado.' 'Reactiva UAC.' } else { New-Check 'uac' 'Control de cuentas de usuario (UAC)' 'ok' 'Activo.' }
    })
    & $add (Safe-Check 'invitado' 'Cuenta Invitado' {
        $g = Get-LocalUser -ErrorAction Stop | Where-Object { $_.SID.Value -like '*-501' }
        if ($g -and $g.Enabled) { New-Check 'invitado' 'Cuenta Invitado' 'aviso' 'Habilitada.' 'Deshabilitala.' } else { New-Check 'invitado' 'Cuenta Invitado' 'ok' 'Deshabilitada.' }
    })
    & $add (Safe-Check 'sinpass' 'Cuentas sin contrasena' {
        $u = @(Get-LocalUser -ErrorAction Stop | Where-Object { $_.Enabled -and -not $_.PasswordRequired } | ForEach-Object { [string]$_.Name })
        if ($u.Count -gt 0) { New-Check 'sinpass' 'Cuentas sin contrasena' 'alto' ('Habilitadas sin contrasena obligatoria: ' + ($u -join ', ')) 'Asigna contrasena o deshabilita la cuenta.' } else { New-Check 'sinpass' 'Cuentas sin contrasena' 'ok' 'Todas las cuentas activas exigen contrasena.' }
    })
    & $add (Safe-Check 'admins' 'Administradores locales' {
        $m = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop)
        $d = if ($m.Count -gt 3) { 'aviso' } else { 'ok' }
        New-Check 'admins' 'Administradores locales' $d ('Miembros: ' + $m.Count) 'Usa una cuenta estandar a diario y deja pocos administradores.'
    })
    & $add (Safe-Check 'autologon' 'Inicio de sesion automatico' {
        $k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        $names = @((Get-Item -LiteralPath $k -ErrorAction Stop).Property)           # solo NOMBRES de valores: nunca se lee la contrasena
        $auto = Get-RegValue $k 'AutoAdminLogon'
        if ($names -contains 'DefaultPassword') { New-Check 'autologon' 'Inicio de sesion automatico' 'alto' 'Hay una contrasena guardada en texto claro en el registro (DefaultPassword). No se muestra su valor.' 'Quita el inicio automatico con contrasena.' }
        elseif ("$auto" -eq '1') { New-Check 'autologon' 'Inicio de sesion automatico' 'aviso' 'AutoAdminLogon activado.' 'Revisa si lo necesitas.' }
        else { New-Check 'autologon' 'Inicio de sesion automatico' 'ok' 'No configurado.' }
    })
    & $add (Safe-Check 'inicio' 'Programas de inicio' {
        $paths = New-Object System.Collections.ArrayList
        foreach ($k in 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run') {
            try { $it = Get-Item -LiteralPath $k -ErrorAction Stop; foreach ($n in $it.Property) { [void]$paths.Add((Get-ExeOnly ([string]$it.GetValue($n)))) } } catch {}
        }
        $risky = @($paths | Where-Object { $_ -and (Test-RiskyPath $_) })
        if ($risky.Count -gt 0) { New-Check 'inicio' 'Programas de inicio' 'aviso' ($paths.Count.ToString() + ' entradas; ' + $risky.Count + ' arrancan desde AppData/Temp/Descargas (solo rutas): ' + (($risky | Select-Object -First 3) -join '; ')) 'Revisa que las conozcas (Administrador de tareas > Inicio).' }
        else { New-Check 'inicio' 'Programas de inicio' 'ok' ($paths.Count.ToString() + ' entradas en el registro, ninguna en rutas de usuario sospechosas.') }
    })
    & $add (Safe-Check 'tareas' 'Tareas programadas ajenas a Microsoft' {
        $t = @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskPath -notlike '\Microsoft\*' -and $_.State -ne 'Disabled' })
        $risky = New-Object System.Collections.ArrayList
        foreach ($x in $t) { foreach ($a in @($x.Actions)) { $e = Get-ExeOnly ([string]$a.Execute); if ($e -and (Test-RiskyPath ([Environment]::ExpandEnvironmentVariables($e)))) { [void]$risky.Add([string]$x.TaskName) } } }
        if ($risky.Count -gt 0) { New-Check 'tareas' 'Tareas programadas ajenas a Microsoft' 'aviso' ($t.Count.ToString() + ' tareas activas; ' + $risky.Count + ' ejecutan desde AppData/Temp: ' + (($risky | Select-Object -First 3) -join '; ')) 'Revisa las que no reconozcas.' }
        else { New-Check 'tareas' 'Tareas programadas ajenas a Microsoft' 'ok' ($t.Count.ToString() + ' tareas activas, ninguna ejecuta desde rutas de usuario sospechosas.') }
    })
    & $add (Safe-Check 'parches' 'Ultima actualizacion instalada' {
        $h = Get-HotFix -ErrorAction Stop | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1
        if (-not $h) { New-Check 'parches' 'Ultima actualizacion instalada' 'nd' 'Sin datos (indicativo).' }
        else { $d = [int]((Get-Date) - $h.InstalledOn).TotalDays; if ($d -gt 60) { New-Check 'parches' 'Ultima actualizacion instalada' 'aviso' ("Hace $d dias (dato indicativo)") 'Ejecuta Windows Update.' } else { New-Check 'parches' 'Ultima actualizacion instalada' 'ok' ("Hace $d dias (dato indicativo)") } }
    })
    & $add (Safe-Check 'secureboot' 'Arranque seguro (Secure Boot)' {
        $v = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' 'UEFISecureBootEnabled'
        if ($null -eq $v) { New-Check 'secureboot' 'Arranque seguro (Secure Boot)' 'nd' 'No determinable (BIOS antigua o sin permiso).' }
        elseif ([int]$v -eq 1) { New-Check 'secureboot' 'Arranque seguro (Secure Boot)' 'ok' 'Activo.' } else { New-Check 'secureboot' 'Arranque seguro (Secure Boot)' 'aviso' 'Desactivado.' 'Activalo en la UEFI si tu equipo lo permite.' }
    })
    & $add (Safe-Check 'bitlocker' 'Cifrado de disco' {
        $v = (New-Object -ComObject Shell.Application).NameSpace($env:SystemDrive + '\').Self.ExtendedProperty('System.Volume.BitLockerProtection')
        if ($v -eq 1) { New-Check 'bitlocker' 'Cifrado de disco' 'ok' 'BitLocker activo en la unidad del sistema.' }
        elseif ($null -eq $v) { New-Check 'bitlocker' 'Cifrado de disco' 'nd' 'No determinable sin administrador.' }
        else { New-Check 'bitlocker' 'Cifrado de disco' 'aviso' 'No esta cifrada la unidad del sistema.' 'Considera activar el cifrado si hay datos sensibles o es portatil.' }
    })
    & $add (Safe-Check 'ps-policy' 'Politica de ejecucion de PowerShell' {
        $p = [string](Get-ExecutionPolicy -Scope LocalMachine)
        if ($p -in 'Unrestricted', 'Bypass') { New-Check 'ps-policy' 'Politica de ejecucion de PowerShell' 'aviso' ("LocalMachine = $p") 'RemoteSigned es mas seguro.' } elseif ($p -eq 'Undefined') { New-Check 'ps-policy' 'Politica de ejecucion de PowerShell' 'ok' 'Sin definir en el equipo (se usa la de cada usuario/por defecto).' } else { New-Check 'ps-policy' 'Politica de ejecucion de PowerShell' 'ok' ("LocalMachine = $p") }
    })
    & $add (Safe-Check 'smartscreen' 'SmartScreen' {
        $v = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'SmartScreenEnabled'
        if ("$v" -eq 'Off') { New-Check 'smartscreen' 'SmartScreen' 'aviso' 'Desactivado.' 'Mantenlo en Advertir.' } elseif ($null -eq $v -or "$v" -eq '') { New-Check 'smartscreen' 'SmartScreen' 'nd' 'Sin dato en el registro (se administra en Seguridad de Windows).' } else { New-Check 'smartscreen' 'SmartScreen' 'ok' ('Estado: ' + $v) }
    })
    & $add (Safe-Check 'sistema' 'Sistema' {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        New-Check 'sistema' 'Sistema' 'info' ($os.Caption + ' compilacion ' + $os.BuildNumber + ', encendido hace ' + [int]((Get-Date) - $os.LastBootUpTime).TotalDays + ' dias')
    })
    $sw.Stop()
    $order = @{ alto = 0; aviso = 1; nd = 2; info = 3; ok = 4 }
    $sorted = @($r.ToArray() | Sort-Object @{ e = { $order[$_.estado] } })
    @{ ok = $true; checks = $sorted; counts = @{ alto = @($sorted | Where-Object { $_.estado -eq 'alto' }).Count; aviso = @($sorted | Where-Object { $_.estado -eq 'aviso' }).Count; nd = @($sorted | Where-Object { $_.estado -eq 'nd' }).Count; ok = @($sorted | Where-Object { $_.estado -eq 'ok' }).Count }; elapsed_ms = [int]$sw.ElapsedMilliseconds }
}
function Format-PcReport($res) {
    $o = New-Object System.Collections.ArrayList
    [void]$o.Add(('Revision de seguridad de este PC (solo lectura, no se cambio nada)  - ' + $res.elapsed_ms + ' ms'))
    [void]$o.Add(('Resumen: ' + $res.counts.alto + ' graves, ' + $res.counts.aviso + ' avisos, ' + $res.counts.ok + ' correctas, ' + $res.counts.nd + ' no verificables sin administrador'))
    foreach ($c in $res.checks) {
        $tag = switch ($c.estado) { 'alto' { '[ALTO ]' } 'aviso' { '[AVISO]' } 'ok' { '[OK   ]' } 'nd' { '[ ?   ]' } default { '[INFO ]' } }
        $line = $tag + ' ' + $c.titulo + ': ' + $c.detalle
        if ($c.consejo -and $c.estado -in 'alto', 'aviso') { $line += '  -> ' + $c.consejo }
        [void]$o.Add($line)
    }
    @($o.ToArray())
}
