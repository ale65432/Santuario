// Santuario.exe - lanzador portable con boveda cifrada.
//  - Los scripts, la configuracion y los datos de Santuario viven cifrados en Santuario.vault (AES-256-CBC + HMAC-SHA256, clave por PBKDF2-HMAC-SHA256).
//  - Al ejecutar, pide la clave, descifra en su sitio (la USB), lanza Santuario.bat y, al salir, vuelve a cifrar y borra los archivos en claro.
//  - Los modelos (models\) y los binarios de Ollama (app\ollama\) NO se cifran: son publicos, pesan decenas de GB y Ollama firma sus binarios.
// Compilar: csc /target:exe /out:Santuario.exe /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll Santuario.cs
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

static class Program
{
    const string Magic = "SANTVLT1";
    const int Iter = 250000;
    static string Root;
    static string VaultPath, TmpPath, PrevPath, MarkerPath, EnvBat;
    static byte[] EncKey, MacKey, Salt;
    static bool Resealed;
    static readonly object Lock = new object();

    delegate bool HandlerRoutine(uint ctrlType);
    [DllImport("kernel32.dll")] static extern bool SetConsoleCtrlHandler(HandlerRoutine h, bool add);
    static HandlerRoutine keep;

    static int Main(string[] args)
    {
        Console.OutputEncoding = Encoding.UTF8;
        Root = Path.GetDirectoryName(Path.GetFullPath(System.Reflection.Assembly.GetExecutingAssembly().Location)).TrimEnd('\\');
        VaultPath = Path.Combine(Root, "Santuario.vault");
        TmpPath = VaultPath + ".tmp";
        PrevPath = VaultPath + ".prev";
        MarkerPath = Path.Combine(Root, ".abierto");
        EnvBat = Path.Combine(Root, "app", "env.bat");
        string cmd = args.Length > 0 ? args[0].ToLowerInvariant() : "";
        try
        {
            switch (cmd)
            {
                case "--sellar": return Seal();
                case "--abrir": return OpenPermanently();
                case "--cambiar-clave": return ChangePassword();
                case "--estado": return Status();
                case "--ayuda": case "-h": case "/?": Help(); return 0;
                case "": return Run();
                default: Console.WriteLine("Opcion desconocida: " + cmd); Help(); return 2;
            }
        }
        catch (Exception ex)
        {
            Console.ForegroundColor = ConsoleColor.Red;
            Console.WriteLine("  ERROR: " + ex.Message);
            Console.ResetColor();
            return 1;
        }
    }

    static void Help()
    {
        Console.WriteLine("  Santuario.exe                 abre Santuario (pide la clave si esta cifrado)");
        Console.WriteLine("  Santuario.exe --sellar        cifra los archivos de esta carpeta y deja solo el ejecutable");
        Console.WriteLine("  Santuario.exe --abrir         descifra de forma permanente (para actualizar o reparar)");
        Console.WriteLine("  Santuario.exe --cambiar-clave cambia la clave");
        Console.WriteLine("  Santuario.exe --estado        muestra si esta cifrado");
    }

    static bool IsSealed() { return File.Exists(VaultPath) && !File.Exists(EnvBat); }
    static bool IsPlain() { return !File.Exists(VaultPath) && File.Exists(EnvBat); }
    static bool IsDirty() { return File.Exists(VaultPath) && File.Exists(EnvBat); }

    static int Status()
    {
        Console.WriteLine("  Carpeta: " + Root);
        Console.WriteLine("  Estado:  " + (IsSealed() ? "CIFRADO (solo el ejecutable y la boveda estan a la vista)" : IsDirty() ? "ABIERTO (hay archivos en claro y una boveda; se vuelve a cifrar al salir)" : IsPlain() ? "SIN CIFRAR" : "vacio/desconocido"));
        return 0;
    }

    // ------------------------------------------------------------------ entrada de clave
    static string ReadPassword(string prompt)
    {
        string envPw = Environment.GetEnvironmentVariable("SANTUARIO_PASSWORD");
        if (!string.IsNullOrEmpty(envPw) && Environment.GetEnvironmentVariable("SANTUARIO_TEST") == "1") return envPw;     // solo para las pruebas
        Console.Write("  " + prompt);
        if (Console.IsInputRedirected) { string l = Console.ReadLine(); Console.WriteLine(); return l ?? ""; }
        var sb = new StringBuilder();
        while (true)
        {
            ConsoleKeyInfo k = Console.ReadKey(true);
            if (k.Key == ConsoleKey.Enter) break;
            if (k.Key == ConsoleKey.Backspace) { if (sb.Length > 0) sb.Length--; continue; }
            if (k.KeyChar != '\0' && !char.IsControl(k.KeyChar)) sb.Append(k.KeyChar);
        }
        Console.WriteLine();
        return sb.ToString();
    }

    // ------------------------------------------------------------------ criptografia
    static byte[] Pbkdf2(byte[] password, byte[] salt, int iterations, int length)
    {
        using (var h = new HMACSHA256(password))
        {
            var output = new byte[length];
            int blocks = (length + 31) / 32;
            for (int b = 1; b <= blocks; b++)
            {
                byte[] s = new byte[salt.Length + 4];
                Buffer.BlockCopy(salt, 0, s, 0, salt.Length);
                s[salt.Length] = (byte)(b >> 24); s[salt.Length + 1] = (byte)(b >> 16); s[salt.Length + 2] = (byte)(b >> 8); s[salt.Length + 3] = (byte)b;
                byte[] u = h.ComputeHash(s);
                byte[] t = (byte[])u.Clone();
                for (int i = 1; i < iterations; i++)
                {
                    u = h.ComputeHash(u);
                    for (int j = 0; j < t.Length; j++) t[j] ^= u[j];
                }
                int off = (b - 1) * 32;
                Buffer.BlockCopy(t, 0, output, off, Math.Min(32, length - off));
            }
            return output;
        }
    }
    static void DeriveKeys(string password, byte[] salt, int iterations)
    {
        byte[] k = Pbkdf2(Encoding.UTF8.GetBytes(password), salt, iterations, 64);
        EncKey = new byte[32]; MacKey = new byte[32];
        Buffer.BlockCopy(k, 0, EncKey, 0, 32); Buffer.BlockCopy(k, 32, MacKey, 0, 32);
        Salt = salt;
        Array.Clear(k, 0, k.Length);
    }
    static bool ConstEq(byte[] a, byte[] b)
    {
        if (a.Length != b.Length) return false;
        int d = 0; for (int i = 0; i < a.Length; i++) d |= a[i] ^ b[i];
        return d == 0;
    }
    static byte[] Encrypt(byte[] plain)
    {
        using (var aes = Aes.Create())
        {
            aes.Mode = CipherMode.CBC; aes.Padding = PaddingMode.PKCS7; aes.KeySize = 256; aes.Key = EncKey; aes.GenerateIV();
            using (var ms = new MemoryStream())
            {
                var hdr = new List<byte>();
                hdr.AddRange(Encoding.ASCII.GetBytes(Magic));
                hdr.AddRange(BitConverter.GetBytes(Iter));
                hdr.AddRange(Salt);
                hdr.AddRange(aes.IV);
                ms.Write(hdr.ToArray(), 0, hdr.Count);
                using (var enc = aes.CreateEncryptor()) { byte[] c = enc.TransformFinalBlock(plain, 0, plain.Length); ms.Write(c, 0, c.Length); }
                byte[] body = ms.ToArray();
                byte[] mac;
                using (var h = new HMACSHA256(MacKey)) mac = h.ComputeHash(body);
                byte[] all = new byte[body.Length + mac.Length];
                Buffer.BlockCopy(body, 0, all, 0, body.Length); Buffer.BlockCopy(mac, 0, all, body.Length, mac.Length);
                return all;
            }
        }
    }
    // Devuelve el zip en claro, o null si la clave es incorrecta / el archivo fue alterado.
    static byte[] Decrypt(byte[] file, string password, out string error)
    {
        error = null;
        int hdrLen = 8 + 4 + 16 + 16;
        if (file.Length < hdrLen + 32 + 16 || Encoding.ASCII.GetString(file, 0, 8) != Magic) { error = "no es una boveda de Santuario valida"; return null; }
        int iter = BitConverter.ToInt32(file, 8);
        if (iter < 10000 || iter > 5000000) { error = "boveda danada"; return null; }
        byte[] salt = new byte[16]; Buffer.BlockCopy(file, 12, salt, 0, 16);
        byte[] iv = new byte[16]; Buffer.BlockCopy(file, 28, iv, 0, 16);
        DeriveKeys(password, salt, iter);
        byte[] mac = new byte[32]; Buffer.BlockCopy(file, file.Length - 32, mac, 0, 32);
        byte[] calc;
        using (var h = new HMACSHA256(MacKey)) calc = h.ComputeHash(file, 0, file.Length - 32);
        if (!ConstEq(mac, calc)) { error = "clave incorrecta (o la boveda fue modificada)"; return null; }
        using (var aes = Aes.Create())
        {
            aes.Mode = CipherMode.CBC; aes.Padding = PaddingMode.PKCS7; aes.KeySize = 256; aes.Key = EncKey; aes.IV = iv;
            using (var dec = aes.CreateDecryptor())
                return dec.TransformFinalBlock(file, hdrLen, file.Length - 32 - hdrLen);
        }
    }

    // ------------------------------------------------------------------ que se cifra
    static bool Excluded(string rel)
    {
        string r = rel.Replace('/', '\\').TrimStart('\\');
        string top = r.Split('\\')[0];
        if (r.Equals("models", StringComparison.OrdinalIgnoreCase) || r.StartsWith("models\\", StringComparison.OrdinalIgnoreCase)) return true;
        if (r.Equals("app\\ollama", StringComparison.OrdinalIgnoreCase) || r.StartsWith("app\\ollama\\", StringComparison.OrdinalIgnoreCase)) return true;
        if (r.StartsWith("app\\", StringComparison.OrdinalIgnoreCase) && r.EndsWith(".zip", StringComparison.OrdinalIgnoreCase) && r.IndexOf('\\', 4) < 0) return true;
        string[] skip = { "Santuario.exe", "Santuario.vault", "Santuario.vault.tmp", "Santuario.vault.prev", ".abierto", "System Volume Information", "$RECYCLE.BIN" };
        foreach (string s in skip) if (top.Equals(s, StringComparison.OrdinalIgnoreCase)) return true;
        return false;
    }
    static List<string> ListFiles()
    {
        var res = new List<string>();
        var stack = new Stack<string>(); stack.Push(Root);
        while (stack.Count > 0)
        {
            string d = stack.Pop();
            foreach (string e in Directory.GetFileSystemEntries(d))
            {
                string rel = e.Substring(Root.Length).TrimStart('\\');
                if (Excluded(rel)) continue;
                FileAttributes a = File.GetAttributes(e);
                if ((a & FileAttributes.ReparsePoint) != 0) continue;
                if ((a & FileAttributes.Directory) != 0) stack.Push(e); else res.Add(e);
            }
        }
        return res;
    }
    static byte[] BuildZip(List<string> files)
    {
        using (var ms = new MemoryStream())
        {
            using (var zip = new ZipArchive(ms, ZipArchiveMode.Create, true))
            {
                foreach (string f in files)
                {
                    string rel = f.Substring(Root.Length).TrimStart('\\').Replace('\\', '/');
                    var entry = zip.CreateEntry(rel, CompressionLevel.Optimal);
                    entry.LastWriteTime = File.GetLastWriteTime(f);
                    using (var src = new FileStream(f, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                    using (var dst = entry.Open()) src.CopyTo(dst);
                }
            }
            return ms.ToArray();
        }
    }
    static int ExtractZip(byte[] zipBytes)
    {
        int n = 0;
        using (var ms = new MemoryStream(zipBytes))
        using (var zip = new ZipArchive(ms, ZipArchiveMode.Read))
        {
            foreach (var e in zip.Entries)                       // primero se valida TODO: si algo es sospechoso no se escribe nada
            {
                if (string.IsNullOrEmpty(e.Name)) continue;
                string f0 = Path.GetFullPath(Path.Combine(Root, e.FullName.Replace('/', '\\')));
                if (!f0.StartsWith(Root + "\\", StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("entrada sospechosa en la boveda: " + e.FullName);
                if (Excluded(f0.Substring(Root.Length))) throw new InvalidDataException("entrada no permitida en la boveda: " + e.FullName);
            }
            foreach (var e in zip.Entries)
            {
                if (string.IsNullOrEmpty(e.Name)) continue;
                string full = Path.GetFullPath(Path.Combine(Root, e.FullName.Replace('/', '\\')));
                if (!full.StartsWith(Root + "\\", StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("entrada sospechosa en la boveda: " + e.FullName);
                if (Excluded(full.Substring(Root.Length))) throw new InvalidDataException("entrada no permitida en la boveda: " + e.FullName);
                Directory.CreateDirectory(Path.GetDirectoryName(full));
                using (var src = e.Open())
                using (var dst = new FileStream(full, FileMode.Create, FileAccess.Write, FileShare.None)) src.CopyTo(dst);
                try { File.SetLastWriteTime(full, e.LastWriteTime.LocalDateTime); } catch { }
                n++;
            }
        }
        return n;
    }
    static int CountZip(byte[] zipBytes)
    {
        int n = 0;
        using (var ms = new MemoryStream(zipBytes)) using (var zip = new ZipArchive(ms, ZipArchiveMode.Read)) foreach (var e in zip.Entries) if (!string.IsNullOrEmpty(e.Name)) n++;
        return n;
    }
    static void WriteVault(byte[] zipBytes)
    {
        byte[] enc = Encrypt(zipBytes);
        File.WriteAllBytes(TmpPath, enc);
        string err;
        byte[] back = Decrypt(File.ReadAllBytes(TmpPath), null2(), out err);     // verificacion de ida y vuelta con las claves en memoria
        if (back == null || back.Length != zipBytes.Length) { File.Delete(TmpPath); throw new IOException("la verificacion de la boveda fallo; no se toco nada"); }
        if (File.Exists(VaultPath)) { if (File.Exists(PrevPath)) File.Delete(PrevPath); File.Move(VaultPath, PrevPath); }
        File.Move(TmpPath, VaultPath);
        if (File.Exists(PrevPath)) { try { File.Delete(PrevPath); } catch { } }
    }
    static string pwCache;
    static string null2() { return pwCache; }

    static void DeletePlain(List<string> files)
    {
        var dirs = new HashSet<string>();
        foreach (string f in files)
        {
            try { File.SetAttributes(f, FileAttributes.Normal); File.Delete(f); } catch { }
            string d = Path.GetDirectoryName(f);
            while (d != null && d.Length > Root.Length) { dirs.Add(d); d = Path.GetDirectoryName(d); }
        }
        var sorted = new List<string>(dirs); sorted.Sort((a, b) => b.Length.CompareTo(a.Length));
        foreach (string d in sorted) { try { if (Directory.GetFileSystemEntries(d).Length == 0) Directory.Delete(d); } catch { } }
    }
    static void HideFolders()
    {
        foreach (string rel in new[] { "models", "app\\ollama" })
        {
            string p = Path.Combine(Root, rel);
            if (Directory.Exists(p)) { try { File.SetAttributes(p, File.GetAttributes(p) | FileAttributes.Hidden); } catch { } }
        }
    }
    static void UnhideFolders()
    {
        foreach (string rel in new[] { "models", "app\\ollama" })
        {
            string p = Path.Combine(Root, rel);
            if (Directory.Exists(p)) { try { File.SetAttributes(p, File.GetAttributes(p) & ~FileAttributes.Hidden); } catch { } }
        }
    }

    // ------------------------------------------------------------------ operaciones
    static int Seal()
    {
        if (IsSealed() || IsDirty()) { Console.WriteLine("  Ya esta cifrado (o abierto). Usa Santuario.exe normalmente, o --abrir para descifrar."); return 2; }
        if (!IsPlain()) { Console.WriteLine("  No encuentro los archivos de Santuario en esta carpeta."); return 2; }
        Console.WriteLine();
        Console.WriteLine("  CIFRAR SANTUARIO");
        Console.WriteLine("  Se cifraran los scripts, la configuracion y los datos de esta carpeta y quedara visible solo Santuario.exe.");
        Console.WriteLine("  Los modelos y Ollama no se cifran (son publicos y pesan decenas de GB); se ocultan.");
        Console.WriteLine("  IMPORTANTE: si olvidas la clave NO hay forma de recuperar los datos cifrados.");
        Console.WriteLine();
        string p1 = ReadPassword("Elige una clave (minimo 10 caracteres): ");
        if (p1.Length < 10) { Console.WriteLine("  La clave es demasiado corta."); return 2; }
        string p2 = ReadPassword("Repite la clave: ");
        if (p1 != p2) { Console.WriteLine("  Las claves no coinciden. No se cifro nada."); return 2; }
        Console.WriteLine("  Cifrando...");
        var salt = new byte[16]; using (var rng = RandomNumberGenerator.Create()) rng.GetBytes(salt);
        DeriveKeys(p1, salt, Iter); pwCache = p1;
        var files = ListFiles();
        byte[] zip = BuildZip(files);
        WriteVault(zip);
        // verificacion final contra el disco antes de borrar nada
        string err; byte[] again = Decrypt(File.ReadAllBytes(VaultPath), p1, out err);
        if (again == null || CountZip(again) != files.Count) throw new IOException("la boveda no coincide con los archivos; no se borro nada");
        DeletePlain(files);
        HideFolders();
        Console.ForegroundColor = ConsoleColor.Green;
        Console.WriteLine("  Listo: " + files.Count + " archivos cifrados. Ahora solo se ve Santuario.exe (y la boveda). Ejecutalo para usar Santuario.");
        Console.ResetColor();
        return 0;
    }
    static byte[] ReadVaultWithPassword(out string password)
    {
        password = null;
        byte[] file = File.ReadAllBytes(VaultPath);
        for (int attempt = 1; attempt <= 5; attempt++)
        {
            string pw = ReadPassword("Clave: ");
            string err; byte[] zip = Decrypt(file, pw, out err);
            if (zip != null) { password = pw; pwCache = pw; return zip; }
            Console.ForegroundColor = ConsoleColor.Red; Console.WriteLine("  " + err + " (intento " + attempt + "/5)"); Console.ResetColor();
            if (Environment.GetEnvironmentVariable("SANTUARIO_TEST") == "1") return null;
            Thread.Sleep(1000 * attempt);
        }
        return null;
    }
    static int OpenPermanently()
    {
        if (IsPlain()) { Console.WriteLine("  Ya esta sin cifrar."); return 0; }
        string pw; byte[] zip = ReadVaultWithPassword(out pw);
        if (zip == null) return 3;
        int n = ExtractZip(zip);
        UnhideFolders();
        File.Delete(VaultPath);
        if (File.Exists(MarkerPath)) File.Delete(MarkerPath);
        Console.WriteLine("  Descifrado: " + n + " archivos. Usa Santuario.exe --sellar para volver a cifrar.");
        return 0;
    }
    static int ChangePassword()
    {
        if (!IsSealed()) { Console.WriteLine("  Solo se puede cambiar la clave cuando esta cifrado."); return 2; }
        string pw; byte[] zip = ReadVaultWithPassword(out pw);
        if (zip == null) return 3;
        string n1 = ReadPassword("Clave nueva (minimo 10 caracteres): ");
        if (n1.Length < 10) { Console.WriteLine("  Demasiado corta."); return 2; }
        if (n1 != ReadPassword("Repite la clave nueva: ")) { Console.WriteLine("  No coinciden."); return 2; }
        var salt = new byte[16]; using (var rng = RandomNumberGenerator.Create()) rng.GetBytes(salt);
        DeriveKeys(n1, salt, Iter); pwCache = n1;
        WriteVault(zip);
        Console.WriteLine("  Clave cambiada.");
        return 0;
    }
    static void Reseal()
    {
        lock (Lock)
        {
            if (Resealed) return;
            try
            {
                var files = ListFiles();
                byte[] zip = BuildZip(files);
                WriteVault(zip);
                DeletePlain(files);
                HideFolders();
                if (File.Exists(MarkerPath)) File.Delete(MarkerPath);
                Resealed = true;
            }
            catch (Exception ex) { Console.WriteLine("  AVISO: no se pudo volver a cifrar (" + ex.Message + "). Los archivos quedan en claro; se cifraran en el proximo cierre."); }
        }
    }
    static bool CtrlHandler(uint type)
    {
        if (type == 2 || type == 5 || type == 6) Reseal();            // cierre de ventana / cierre de sesion / apagado
        return false;
    }

    static int Run()
    {
        bool sealedNow = IsSealed(), dirty = IsDirty();
        if (!sealedNow && !dirty && !IsPlain()) { Console.WriteLine("  No encuentro Santuario en esta carpeta (falta app\\env.bat y la boveda)."); return 2; }
        if (sealedNow || dirty)
        {
            if (dirty) { Console.ForegroundColor = ConsoleColor.Yellow; Console.WriteLine("  La sesion anterior no se cerro bien: hay archivos en claro. Se volveran a cifrar al salir."); Console.ResetColor(); }
            string pw; byte[] zip = ReadVaultWithPassword(out pw);
            if (zip == null) return 3;
            if (sealedNow)
            {
                Console.WriteLine("  Descifrando...");
                ExtractZip(zip);
                UnhideFolders();
                File.WriteAllText(MarkerPath, DateTime.Now.ToString("s"));
                try { File.SetAttributes(MarkerPath, FileAttributes.Hidden); } catch { }
            }
            keep = new HandlerRoutine(CtrlHandler);
            SetConsoleCtrlHandler(keep, true);
        }
        Console.CancelKeyPress += (s, e) => { e.Cancel = true; };         // Ctrl+C lo atiende Santuario, no el lanzador
        int rc = 0;
        try
        {
            var psi = new ProcessStartInfo(Path.Combine(Environment.GetEnvironmentVariable("SystemRoot") ?? "C:\\Windows", "System32", "cmd.exe"), "/c \"\"" + Path.Combine(Root, "Santuario.bat") + "\"\"");
            psi.UseShellExecute = false; psi.WorkingDirectory = Root;
            using (var p = Process.Start(psi)) { p.WaitForExit(); rc = p.ExitCode; }
        }
        finally
        {
            if (sealedNow || dirty) { Console.WriteLine("  Cifrando de nuevo..."); Reseal(); if (Resealed) Console.WriteLine("  Santuario cifrado."); }
        }
        return rc;
    }
}
