# Santuario — cómo ejecutarlo (paso a paso)

Santuario es un asistente de IA **local y portable** para Windows: los modelos corren en tu propio PC con Ollama,
sin enviar nada a internet. Tiene un cerebro de varias "regiones" (modelos), un agente de tareas, habilidades para leer,
analizar y mejorar código, crear archivos y páginas web, y una revisión de seguridad del PC.

> Este repositorio trae **solo el código**. Los modelos (decenas de GB) y Ollama se descargan en los pasos 3 y 4.

## 0. Requisitos
- **Windows 10 u 11** (PowerShell 5.1, ya incluido). No funciona en Mac, Linux ni ChromeOS.
- **Git** para clonar el repositorio.
- **RAM:** mínimo 4 GB (modelos pequeños). Lo ideal son 8 GB o más.
- **Disco:** entre 3 GB (solo modelos chicos) y ~25 GB (todas las regiones).
- Si lo vas a poner en una **USB**, formatéala en **exFAT o NTFS**. FAT32 no admite archivos de más de 4 GB y varios modelos pesan más.
- Conexión a internet **solo** para los pasos 3 y 4 (descargas). Después funciona sin internet.

## 1. Clonar
```bash
git clone <URL-DEL-REPOSITORIO> Santuario
cd Santuario
```
(Pon el repositorio en una carpeta cuya ruta no tenga espacios si puedes, por ejemplo `C:\Santuario` o `E:\Santuario`.)

## 2. Desbloquear los archivos (solo si descargaste un ZIP en vez de clonar)
Clic derecho en el ZIP → Propiedades → **Desbloquear**, antes de extraerlo. Con `git clone` no hace falta.

## 3. Descargar Ollama portable
1. Entra a <https://github.com/ollama/ollama/releases> y baja **`ollama-windows-amd64.zip`** (versión estable más reciente).
2. Extrae el contenido dentro de la carpeta **`app\ollama\`** de Santuario, de modo que exista **`app\ollama\ollama.exe`**.

Santuario comprueba que los programas de Ollama tengan la firma digital oficial; si algo no coincide, no arranca.

## 4. Descargar el cerebro (modelos)
Haz doble clic en **`Instalar-Cerebro.bat`**. Descarga los modelos de `brain.json` y crea las regiones.
Es lo único que usa internet y puede tardar mucho (todas las regiones ≈ 23 GB).

**Para un PC modesto**, antes de ejecutarlo abre `brain.json` y deja solo las regiones pequeñas (por ejemplo `general`, `code`, `agent`,
`analyst_lite`, `libre2` y `gemma`, de 1 a 2,2 GB); borra las demás.

## 5. Ejecutar
Haz doble clic en **`Santuario.bat`**.

- La **primera vez** aparece *"PRIMERA VEZ en este PC"* y tarda cerca de un minuto en comprobar firmas. Escribe **`SI`** para aprobar
  (solo si el código es el que clonaste de este repositorio). Si luego modificas scripts, volverá a pedirlo.
- Se abre el chat. El **agente de tareas** arranca solo en segundo plano y se detiene al salir.
- Para salir escribe **`/bye`**.

### Qué puedes escribir
| Escribe | Qué hace |
|---|---|
| (cualquier texto) | Conversa; el enrutador elige la región (general, código, libre…) |
| `/cerebro` | Muestra las regiones y la RAM libre |
| `/taller` | Lista las habilidades |
| `/analizar <carpeta>` | Revisa el código de una carpeta (secretos, patrones peligrosos, métricas) |
| `/leer <archivo>` | Muestra un archivo (secretos tapados) |
| `/mejorar <archivo>` | Propone arreglos como *diff*, con respaldo y confirmación; `/deshacer` los revierte |
| `/crear <archivo o carpeta>` | Crea archivos o carpetas (nunca sobrescribe ni ejecuta) |
| `/web <descripción>` | Genera una página web accesible |
| `/escanear` | Revisión de seguridad de este PC (solo lectura) |
| `/manos` | Activa el control del navegador Edge (opcional; usa internet) |
| `recuérdame mañana a las 9 ...` | Crea una tarea para el agente |
| `/reset`, `/auto`, `/bye` | Borrar historial, modo automático, salir |

Cada vez que Santuario vaya a tocar una carpeta o un archivo te pedirá un **código de confirmación** que debes escribir tú.

## 6. Opcionales
- **Telegram:** `Configurar-Telegram.bat` (necesitas crear tu propio bot con @BotFather). El token queda cifrado con tu usuario de Windows.
- **Ejecutable `Santuario.exe`:** `Compilar.bat` lo genera. Con `Santuario.exe --sellar` puedes **cifrar** los scripts y datos de la carpeta
  con una clave tuya (los modelos y Ollama no se cifran). Si olvidas la clave no hay recuperación.
- **Inicio automático** con Windows: `Instalar-Inicio-Automatico.bat` / `Quitar-Inicio-Automatico.bat` (opcional; pide confirmación).

## 7. Si algo falla
- *"Arranque cancelado por la verificación de integridad"*: respondiste que no al aviso, o falta/está alterado algo en `app\ollama\`. Vuelve a ejecutar y revisa la lista de archivos que muestra.
- *"No se pudo iniciar Ollama"*: no existe `app\ollama\ollama.exe` (paso 3) o otro programa ocupa el puerto 11434.
- Respuestas muy lentas: poca RAM libre. Cierra programas, usa regiones pequeñas (`/code`, `/agent`) o quita las grandes de `brain.json`.
- El modelo pequeño se equivoca en cuentas y datos: es un límite de los modelos de 1–2B, no del programa.

## 8. Privacidad
- Los modelos y Ollama funcionan **sin internet** (`OLLAMA_NO_CLOUD`, proxys apagados).
- Solo salen a la red: el navegador Edge si activas `/manos`, y el agente hacia `api.telegram.org` si configuras Telegram.
- Tus conversaciones, tareas y claves se guardan en `data\` y `logs\` (fuera del repositorio; `.gitignore` los excluye). **No subas esas carpetas.**

## 9. Probar que todo funciona (opcional)
Dentro de `agent\tests\` hay pruebas automáticas (por ejemplo `skills-unit.ps1`, `tasks-unit.ps1`).
Ejecútalas con `app\env.bat` cargado: `cmd /c "call app\env.bat && powershell -NoProfile -ExecutionPolicy Bypass -File agent\tests\skills-unit.ps1"`.
