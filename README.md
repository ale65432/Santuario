# Santuario

> **Para ejecutarlo paso a paso (clonar, descargar Ollama y modelos, primer arranque) lee [INSTRUCCIONES.md](INSTRUCCIONES.md).**

Asistente de IA local, privado y 100% portable. Corre desde esta carpeta (USB) y no instala nada en el PC.
Su "cerebro" son varios modelos (regiones); un enrutador envía cada solicitud a la región adecuada.
**Los modelos y Ollama nunca usan internet.** Solo si activas las "manos" (`/manos`), el navegador Edge sale a la red.

## Manos (Edge y programas) — opt-in, apagadas por defecto
- `/manos` las activa en esa sesión · `/manos off` las apaga y cierra el Edge de Santuario · `/manos login` abre Edge para que inicies sesión TÚ.
- Qué hace: abrir sitios de la lista (YouTube, Google, redes), **buscar en Google y leer los resultados** para resumirlos con el modelo local, buscar/reproducir en YouTube, abrir programas de la lista (pide teclear un código).
- Ejemplos: `abre youtube` · `busca recetas de pozole en google` · `ponme música de Vivaldi` · `abre la calculadora` · `abre el 2` (abre el resultado 2).
- **Recuerda el contexto** entre mensajes: `abre youtube` → `ahora busca tutoriales de excel` (busca EN ese YouTube, misma pestaña) → `pon el primero`. También `en ese youtube que abriste busca X`. Sin sitio abierto, `busca X` va a Google.
- Texto largo o con pinta de código nunca se envía a internet (pasa al chat local). `/manos borrar-sesion` borra las sesiones guardadas del perfil de Edge de Santuario.
- **Lo que NO hace** (por diseño): clic libre, escribir en páginas, publicar, descargar, leer correo/mensajes, tocar contraseñas/cookies. Las redes sociales solo se abren.
- Seguridad: todo lo define `agent/policy.json` (listas blancas de sitios y programas; solo el dueño la edita). El modelo solo propone una acción; el código la valida. El texto de internet se trata como dato no confiable y nunca genera acciones. Registro en `logs/audit-*.jsonl` (hashes encadenados). `agent/STOP` (archivo) detiene todo.
- Edge usa un perfil propio (`profile_mode: host` = en el PC, no en la USB) y un puerto de control aleatorio solo en `127.0.0.1`; se cierra por su propio perfil, nunca por nombre.
- Google puede pedir verificación (captcha) a navegadores automatizados: Santuario se detiene y te pide resolverla tú en la ventana; no la automatiza.
- Más detalle: `agent/PLAN.md`.

## Agente 24/7: tareas programadas y Telegram
Un **demonio propio en PowerShell** (no OpenClaw: necesita Node, es enorme y tiene un historial de seguridad malo) que ejecuta tareas y atiende Telegram con tu modelo local.
- **Arrancarlo:** `Santuario-Agente.bat` (ventana vigilante: si el agente se cae, lo reinicia; mantiene el PC despierto mientras corre). Para detenerlo: cerrar la ventana o crear `agent\QUIT`. Pausa de emergencia: crear `agent\STOP` (o `/stop` desde Telegram).
- **Crear tareas** (en la consola de Santuario o por Telegram), en lenguaje natural; el código te muestra qué guardará y pide confirmación:
  `recuérdame mañana a las 9 llamar al banco` · `en 20 minutos recuérdame sacar la pasta` · `cada día a las 8 busca noticias de Monterrey` · `cada lunes a las 9 recuérdame pagar la renta` · `... por telegram` (el aviso va a tu celular).
  Tipos: recordatorio, pregunta (el modelo local responde), búsqueda (Google vía Edge + resumen). Comandos: `/tareas` · `/cancelar t1` · `/aprobar t1` · `/avisos` · `/agente`.
- **Telegram** (`Configurar-Telegram.bat`, una vez): pegas el token de tu bot (de @BotFather); se guarda **cifrado con DPAPI en tu PC, no en la USB**, y te empareja con un código que solo ves en la consola. Solo tu cuenta (id numérico, chat privado) recibe respuesta; los demás son ignorados en silencio.
  - Desde Telegram: conversar (modelo local, región con filtros), `/tareas`, `/cancelar`, `/estado`, `/stop`, `/reanudar`, crear recordatorios y, si lo habilitas en el PC (`/remoto herramientas on`, caduca solo), buscar en Google.
  - **Nunca** desde Telegram: abrir programas o sitios, reproducir audio, tocar archivos. Las tareas de búsqueda creadas por Telegram quedan **pendientes** hasta que las apruebes en el PC.
- **Seguridad:** tareas firmadas (HMAC con clave DPAPI de tu PC; si alguien las edita —texto, hora o intervalo— se bloquean), caducan (30 días), máximo 10 vigentes, cada tarea se marca antes de ejecutarse (nunca se repite en bucle) y las atrasadas por un reinicio no se repiten solas. El dueño de Telegram y las herramientas remotas también van firmados. El token **solo** se envía a `api.telegram.org` (aunque `policy.json` diga otra cosa), nunca aparece en registros ni errores, y el contenido de los mensajes no se registra. Ollama sigue sin internet (solo el agente habla con Telegram).
- **Candado de política:** la primera vez el agente registra la huella de `agent\policy.json` en tu PC. Si el archivo cambia (lo editaste tú o alguien con acceso a la USB), el **canal remoto se desactiva** hasta que lo apruebes en la consola con `/agente aprobar`. Si editas `policy.json` a propósito, apruébalo igual.
- **Inicio automático con Windows (opcional, no está instalado):** `Instalar-Inicio-Automatico.bat` (muestra primero qué hará y pide escribir SI). Crea un acceso directo en tu carpeta Inicio y guarda en tu PC (no en la USB) el verificador, el número de serie de la USB y una huella de los scripts, de Ollama y de `brain.json`. Al iniciar sesión el agente **solo** arranca si esa misma USB está puesta (aunque cambie de letra) y nada cambió. `Quitar-Inicio-Automatico.bat` lo deshace (`... TODO` borra además el token cifrado y las claves de este PC).
- **Si cierras la ventana del agente:** Edge del agente (si había abierto una búsqueda) se queda un rato abierto hasta el siguiente arranque, que lo limpia. Para parar bien, crea `agent\QUIT`.
- **Límite conocido del emparejamiento:** mientras la ventana de emparejamiento está abierta (10 min), quien envíe 3 códigos erróneos al bot puede cancelarla (no puede tomar el control); repite `Configurar-Telegram.bat`. Cierra el agente antes de emparejar.
- **WhatsApp:** fuera de esta fase. La vía oficial exige un servidor público (webhook) y cuenta de empresa; las no oficiales pueden dar de baja tu número y exponen todos tus chats.
- Pruebas: `agent\tests\` (tareas, y demonio contra un Telegram falso local, sin internet ni token real).

## Privacidad: modo 100% local (verificado)
- `Santuario.bat` arranca Ollama con `OLLAMA_NO_CLOUD=1` y un proxy muerto (`127.0.0.1:9`) como interruptor de red: cualquier intento de salir a internet falla.
- **Por qué:** Ollama sin esas protecciones abre una conexión permanente a `ollama.com:443` desde el arranque (medido el 2026-10-08). Con ellas, 0 conexiones fuera de `127.0.0.1` durante arranque, carga de modelo, chat y 40 s en reposo.
- **Único script con internet:** `Instalar-Cerebro.bat` (descarga modelos que falten). Úsalo solo cuando quieras instalar algo.
- Las conversaciones se guardan solo en `logs\` de esta USB.

## Uso
- **Santuario.bat**: doble clic. Muestra el banner (Zeus + SANTUARIO, ~25% de la terminal) y debajo el chat.
- **Scroll:** el banner va arriba del historial y la conversación completa se puede subir con la rueda del mouse o `Ctrl+Shift+RePág`. (Un encabezado anclado que no se mueve es posible con `"header_fixed": true` en `brain.json`, pero entonces la terminal NO guarda historial de lo que sale por arriba; por eso está desactivado.)
- **Instalar-Cerebro.bat**: reconstruye las regiones desde `brain.json` (con internet descarga lo que falte). Úsalo en una USB nueva o si cambias `brain.json`.
- Comandos dentro del chat: `/cerebro` (ver regiones y RAM) · `/auto` · `/<region>` (fija una región, ej. `/code`, `/libre`, `/analyst`) · `/manos` · `/reset` · `/bye`.
- Si una región con filtros se niega a responder, Santuario reintenta solo con la región libre.
- Cada conversación se guarda en `logs\chat-AAAA-MM-DD.txt` (la zona de chat no conserva historial de scroll).

## El cerebro (`brain.json`)
| Región | Modelo | RAM aprox. | Cuándo se usa |
|---|---|---|---|
| general | Qwen3.5 2B | 2.1 GB | por defecto, conversación en español |
| code | Qwen2.5-Coder 1.5B | 1.2 GB | programación y scripts |
| agent | Granite 4.0 1B | 1.1 GB | planes paso a paso, flujos, JSON de herramientas |
| hermes | Hermes 3 8B (Q3) | 5 GB | mejora de `agent` si hay >= 6.5 GB libres |
| analyst | Dolphin Mistral 7B | 5.5 GB | malware / logs / tráfico (análisis defensivo), >= 6.5 GB libres |
| analyst_lite | Dolphin Phi 2.7B | 2 GB | respaldo del analista con poca RAM |
| libre | Huihui Qwen3.5 4B abliterated | 3.5 GB | "sin censura", o tras un rechazo; >= 4.5 GB libres |
| libre8 | Llama 3.1 8B abliterated (Q3) | 5 GB | mejora de `libre` si hay >= 6.5 GB libres |
| libre2 | Huihui Qwen3.5 2B abliterated | 1.8 GB | respaldo de `libre` con poca RAM |
| gemma | Gemma 2 2B abliterated | 2.2 GB | manual (`/gemma`), otra "voz" |
Solo un modelo está en RAM a la vez. Cada región tiene `upgrade_to` (mejora si hay RAM) y `fallback` (respaldo si no cabe).
Medido en un PC de 6 GB con ~1.6 GB libres: las regiones de hasta ~4B van bien (3-13 tok/s); los 7-8B cargan muy lento
y el analista de 7B no llegó a cargar; en un PC de 8 GB deberían funcionar.

## Estructura
| Ruta | Contenido |
|---|---|
| `brain.json` | definición del cerebro (regiones, modelos, RAM, disparadores) y la identidad "Santuario" |
| `app/ollama/` | Ollama portable |
| `app/santuario.ps1`, `header.ps1`, `setup.ps1` | enrutador, encabezado ANSI, instalador del cerebro |
| `app/env.bat`, `serve.bat` | entorno portable (redirige claves/logs a `data/`) |
| `app/splash/zeus.jpg` | imagen fuente del encabezado (se convierte a ANSI al arrancar) |
| `models/` | modelos (formato Ollama) · `modelfiles/` generados desde `brain.json` |
| `data/` | claves y logs de Ollama (no se escribe nada en el PC anfitrión) |
| `agent/` | las "manos" (`hands.ps1`) y el agente 24/7 (`daemon.ps1`, `tasks.ps1`, `telegram.ps1`), `policy.json` (listas blancas y límites), `PLAN*.md`, `tests/` |
| `training/`, `knowledge/` | futuras fases: entrenamiento propio y RAG |
| `INVESTIGACION.md` | investigación de modelos y de fine-tuning |

## Notas técnicas
- La USB es FAT32: ningún archivo puede pasar de 4 GB (por eso los modelos de 8B van en Q3_K_M).
- En Windows, `FROM nombre:tag` en un Modelfile falla; se usan alias (`ollama cp`) definidos en `brain.json`.
- Los `.ps1` son ASCII a propósito (PowerShell 5.1 lee mal los acentos sin BOM); los textos con acentos viven en `brain.json`.
- Dolphin no está entrenado específicamente en malware: es un modelo poco restrictivo al que se le da un rol de analista defensivo.

## Habilidades del taller (leer, analizar y mejorar código, revisar el PC, crear páginas web)

Solo en la consola local (nunca desde Telegram ni tareas). Escribe `/taller` para verlas. Cada carpeta pide permiso con un código; los secretos (`.env`, claves, cookies…) no se leen: solo se avisa de que existen.

- `/analizar <carpeta> [explicar]` — secretos (siempre tapados), patrones peligrosos por lenguaje, errores de sintaxis PowerShell, métricas e informe opcional. También: *"analiza el código de la carpeta C:\proyecto"*.
- `/leer <archivo>` — muestra un archivo de texto (secretos tapados).
- `/mejorar <archivo>` — arreglos automáticos y propuestas del modelo como **diff**, con respaldo verificado, confirmación escrita y `/deshacer`.
- `/escanear` — revisión de seguridad de ESTE PC, solo lectura (antivirus, firewall, RDP, SMB1, UAC, cuentas, inicio, tareas…). No escanea otras máquinas ni la red.
- `/web <lo que quieres>` — página web accesible (HTML+CSS, sin scripts ni recursos externos): el modelo propone una especificación JSON y el código genera y valida el sitio en `data\workspace\sitios\`.

Pruebas: `agent\tests\skills-*.ps1` y `bench.ps1` (presupuestos de rendimiento). Plan, límites y procedencia: `agent\PLAN-SKILLS.md`, `agent\skills\SOURCE.md`.

## Seguridad: integridad y límites conocidos (auditoría 2026-10-10)

- **Integridad al arrancar:** `Santuario.bat` compara los scripts y la configuración de la USB con una huella guardada en TU PC (`%LOCALAPPDATA%\Santuario\integrity.json`, fuera de la USB) y comprueba la firma de los binarios de Ollama. La primera vez, y cada vez que algo cambie (por ejemplo tras una actualización tuya), te pide escribir **SI** para aprobarlo. El agente 24/7, `Configurar-Telegram.bat` e `Instalar-Cerebro.bat` NO arrancan si la integridad no está aprobada (no preguntan: abre `Santuario.bat` una vez).
- Los `.bat` usan rutas absolutas de Windows (sin plantado por directorio actual) y comprueban que el puerto de Ollama lo tiene el Ollama de la USB.
- Registros de chat y auditoría de la consola: se borran a los 30 días; los secretos reconocibles se tapan antes de guardarse. `brain.json` → `"ui": { "chat_log": false }` apaga el registro de chat.
- **Lo que NO puedo garantizar:** una USB FAT32 no cifra ni protege permisos. Si la pierdes, quien la encuentre lee `logs\`, `data\` y los respaldos del taller → usa BitLocker To Go (acepta FAT32) en la USB. Malware que corra como tu mismo usuario en un PC puede leer lo que tu usuario puede leer (token DPAPI incluido). El puerto de depuración de Edge (manos) no tiene autenticación mientras Edge está abierto; usa `profile_mode: ephemeral` en `agent\policy.json` si no quieres sesiones guardadas.
