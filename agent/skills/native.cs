using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
namespace Win {
    public static class SkFs {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        public static extern uint GetLongPathNameW(string s, StringBuilder b, uint n);
    }
    public static class SkScan {
        // Una sola pasada por el texto: [lineas con contenido, lineas de comentario, TODO/FIXME en comentarios, lineas largas > 160].
        public static int[] Metrics(string text, string[] tokens) {
            int nb = 0, com = 0, todo = 0, lng = 0;
            int n = text.Length, pos = 0;
            while (pos <= n) {
                int end = text.IndexOf('\n', pos);
                if (end < 0) end = n;
                int len = end - pos;
                if (len > 160) lng++;
                int s = pos;
                while (s < end && (text[s] == ' ' || text[s] == '\t' || text[s] == '\r')) s++;
                if (s < end) {
                    nb++;
                    bool isCom = false;
                    if (tokens != null) {
                        for (int t = 0; t < tokens.Length && !isCom; t++) {
                            string tk = tokens[t];
                            if (string.Compare(text, s, tk, 0, tk.Length, StringComparison.OrdinalIgnoreCase) == 0 && s + tk.Length <= end) {
                                if (char.IsLetter(tk[tk.Length - 1]) && s + tk.Length < end && (char.IsLetterOrDigit(text[s + tk.Length]) || text[s + tk.Length] == '_')) continue;
                                isCom = true;
                            }
                        }
                    }
                    if (isCom) {
                        com++;
                        string line = text.Substring(s, end - s);
                        if (HasMarker(line)) todo++;
                    }
                }
                pos = end + 1;
            }
            return new int[] { nb, com, todo, lng };
        }
        static readonly string[] marks = { "TODO", "FIXME", "HACK", "XXX" };
        static bool HasMarker(string line) {
            foreach (var m in marks) {
                int i = 0;
                while ((i = line.IndexOf(m, i, StringComparison.OrdinalIgnoreCase)) >= 0) {
                    bool l = i == 0 || !(char.IsLetterOrDigit(line[i - 1]) || line[i - 1] == '_');
                    int e = i + m.Length;
                    bool r = e >= line.Length || !(char.IsLetterOrDigit(line[e]) || line[e] == '_');
                    if (l && r) return true;
                    i = e;
                }
            }
            return false;
        }
        public static int[] LineStarts(string[] lines) {
            var s = new int[lines.Length];
            int pos = 0;
            for (int i = 0; i < lines.Length; i++) { s[i] = pos; pos += lines[i].Length + 1; }
            return s;
        }
        // Ventanas de 5 lineas normalizadas; muestreo por contenido (1 de cada 3) para ahorrar tiempo y memoria.
        public static void AddDup(string[] lines, Dictionary<string, int> dup, Dictionary<string, string> dupFile, string rel, int cap) {
            var hl = new List<int>(lines.Length);
            foreach (var l in lines) {
                if (l.Length < 15) continue;
                var n = l.Trim();
                if (n.Length >= 15 && n != "}") hl.Add(n.ToLowerInvariant().GetHashCode());
            }
            for (int k = 0; k + 5 <= hl.Count; k++) {
                if (hl[k] % 3 != 0) continue;
                string key = hl[k] + "," + hl[k + 1] + "," + hl[k + 2] + "," + hl[k + 3] + "," + hl[k + 4];
                int c;
                if (dup.TryGetValue(key, out c)) { c++; dup[key] = c; if (c == 2) dupFile[key] = rel; }
                else if (dup.Count < cap) dup[key] = 1;
            }
        }
    }
}
