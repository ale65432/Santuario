# Fase "Habilidades del taller" — plan y estado

Objetivo: que Santuario, desde la consola local del dueño, pueda (1) leer archivos del PC y analizar el código de una carpeta, (2) mejorar código con
cambios revisables, (3) hacer escaneos de seguridad DEFENSIVOS (de una carpeta y de la postura del propio PC), (4) crear páginas web a partir de
especificaciones, y que todo tenga pruebas y mediciones de rendimiento.

## Principios
- El código detecta, valida y escribe; el modelo local solo explica, propone y traduce peticiones a JSON validado.
- Solo origen "consola". Nunca desde Telegram ni tareas programadas.
- Lectura/escritura solo dentro de carpetas concedidas por el dueño (confirmación escrita). Lista negra de secretos: su presencia se informa, su contenido NO se lee.
- Nunca se sigue un enlace/junction fuera de la raíz. Límites de tamaño, número de archivos, profundidad y tiempo.
- Cambios a archivos: diff + confirmación + respaldo + validación; nunca sobrescribir sin respaldo.
- Escaneos solo del propio equipo (nada de escanear otras máquinas: eso es ofensivo y queda fuera).

## Piezas
| Pieza | Archivo | Estado |
|---|---|---|
| Sandbox de rutas, concesiones, inventario, lectura segura | `agent/skills/files.ps1` | hecho |
| Análisis de código + secretos (enmascarados) + métricas + informes | `agent/skills/codescan.ps1` | hecho |
| Postura de seguridad del PC (solo lectura) | `agent/skills/pcscan.ps1` | hecho |
| Generador de páginas web (especificación → HTML/CSS) + validador | `agent/skills/webgen.ps1` | hecho |
| Mejora de código (propuesta, diff, aplicar con respaldo) | `agent/skills/improve.ps1` | hecho |
| Registro de habilidades, comandos y rutas de la consola | `agent/skills/skills.ps1`, `skills.json` | hecho |
| Paquetes de instrucciones (prompts) para el modelo | `agent/skills/prompts/` | hecho |
| Pruebas + fixtures con fallos plantados | `agent/tests/skills-*.ps1`, `fixtures/` | hecho |
| Medición de rendimiento y optimización | `agent/tests/bench.ps1` | hecho |
| Revisión de código y accesibilidad por agentes | — | hecho |

## Agentes desplegados
- Investigación: patrones de secretos, reglas por lenguaje, postura de Windows, límites de los LLM pequeños.
- Seguridad: modelo de amenazas del acceso a archivos, escritura segura, generación web, recursos.
- Diseño: sistema de diseño accesible para los sitios generados.
- Al final: revisión de código y de accesibilidad.

## Resultado (2026-10-10)
- Pruebas: skills-unit 126, skills-web 97, skills-improve 89, skills-intent 67 (todas correctas) + regresión de fases previas: tareas 104, demonio 72, autoarranque 5, manos 151 + 26 E2E. Prueba real con la app (SendKeys) y el modelo local: /taller, análisis, /leer (secretos tapados, .env negado), revisión del PC y creación de una web.
- Rendimiento (300 archivos / 780 KB, `bench.ps1`): análisis 23,3 s -> 3,5-5,8 s (~135-220 KB/s); inventario 1,3 -> 0,6 s; web 0,1-0,2 s. Causas halladas: regex genérico con `[\w.-]*` inicial (4,8 ms/archivo), recorrido línea a línea en PowerShell, lectura con validación por archivo; arreglo: regex compiladas guiadas por coincidencias, helper C# (`native.cs`, con respaldo en PowerShell), lectura directa.
- Revisión de código independiente: 6 altos + varios medios corregidos (fragmento vacío al modelo, timeouts de regex abortando el análisis, enmascarado que fallaba abierto, fragmentos truncados antes de tapar, UTF-16 omitido, `santuario:ignore` silenciando secretos, diff con secretos, etc.).
- Auditoría de accesibilidad: reflow 320px, idiomas, títulos por defecto, foco de `main`, forced-colors y pares de contraste derivados corregidos.
- Límites conocidos: sin escaneo de otras máquinas; TOCTOU/hard links entre validar y leer (requiere atacante local); autofixes de Python/JS sin validación sintáctica; `lang="es"` fijo en el autofix HTML; la vista previa deja un perfil temporal de Edge en %TEMP%.

## Auditoría de seguridad completa (2026-10-10) — qué se corrigió
Corregido: verificador de integridad con aprobación del dueño + firmas de Ollama (`app\integrity.ps1`, `verify.bat`, 25 pruebas); `.bat` con rutas absolutas y `NoDefaultCurrentDirectoryInExePath`; comprobación del dueño del puerto de Ollama; manifiesto de `/deshacer` firmado con la clave del PC; concesiones sin unidades completas ni padres con enlaces; gancho de pruebas de confirmación solo con variable de entorno; lista de llamadas sensibles ampliada; `Redact-Secrets` con claves/tokens/contraseñas; enmascarado conservador (también baja entropía); nombres sensibles ampliados; informes con `Strip-Terminal`; origen de modelos acotado y Modelfile sin inyección (`setup.ps1`); tareas del demonio detenidas si la política cambió; etiquetas anti-inyección con RNG criptográfico; retención 30 días de registros.
Pendiente / aceptado (documentado en README): cifrado de la USB (BitLocker To Go), CDP de Edge sin autenticación, cadena de auditoría sin clave, firma de `estado` de tareas, dominios por sufijo (se verifica el host tras cargar), `taskkill /im ollama.exe` mata cualquier Ollama del PC, perfiles temporales de la vista previa.
