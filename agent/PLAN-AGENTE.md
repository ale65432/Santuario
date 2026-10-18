# Fase "Agente 24/7" — plan y estado

Objetivo: que Santuario sea un agente personal local y permanente: crea y ejecuta tareas programadas, atiende mensajes (Telegram) y hace varias cosas,
todo con el modelo local. Referencia de producto: OpenClaw (estudiado; NO se instala: Node, tamaño enorme, historial de seguridad malo).

## Principios
- El modelo y Ollama siguen sin internet. Solo salen a la red: Edge (manos) y el demonio (solo api.telegram.org).
- Un canal remoto es una puerta de entrada: lista blanca por ID numérico + emparejamiento con código mostrado solo en la consola del PC.
- Desde el canal remoto y las tareas: nada de abrir programas ni sitios ni audio (origen "remoto"/"tarea" bloqueado en `hands.ps1`).
- Las tareas son datos del dueño, firmadas (HMAC/DPAPI); el modelo no las crea ni edita. Las creadas por Telegram que no sean recordatorios quedan pendientes de aprobación en el PC.
- El token del bot nunca va en texto plano: DPAPI en la carpeta real del usuario del PC (no en la USB). Se redacta de todo registro.
- Nada se registra en el PC anfitrión (inicio automático) sin que el dueño lo ejecute a propósito.

## Estado (2026-10-08)
| Pieza | Archivo | Estado |
|---|---|---|
| Biblioteca común (consola y demonio) | `app/lib.ps1` | hecho |
| Motor de tareas: almacén, horarios en español, firmas, caducidad, planificador | `agent/tasks.ps1` | hecho, 104 pruebas |
| Conector Telegram (long polling, lista blanca, emparejamiento, token DPAPI) | `agent/telegram.ps1`, `setup-telegram.ps1`, `Configurar-Telegram.bat` | hecho; probado con Telegram falso local (NO con un bot real: falta el token del dueño) |
| Demonio + vigilante + anti-suspensión | `agent/daemon.ps1`, `Santuario-Agente.bat` | hecho, 72 pruebas con Telegram falso + prueba real con la app |
| Consola: tareas en lenguaje natural, `/tareas`, `/aprobar`, `/agente`, `/avisos`, `/remoto` | `agent/console-agent.ps1`, `app/santuario.ps1` | hecho |
| Inicio automático (opcional) | `Instalar-Inicio-Automatico.bat` + `app/autostart-*.ps1` | escrito, verificador probado (5 casos) y ensayado en seco; NO instalado |
| WhatsApp | — | fuera de esta fase (ver README) |
| Revisión de código por agente independiente | — | ver abajo |

## Bugs reales que cazaron las pruebas (y quedaron corregidos)
- `0x80000001` en PowerShell es un número negativo: el demonio se caía al arrancar (anti-suspensión).
- `ConvertFrom-Json` devuelve una lista JSON como un solo objeto: las tareas se anidaban y se mezclaban los estados.
- Un solo mensaje pendiente no se descartaba al arrancar (`.Count` de un objeto suelto es `$null`): se ejecutó una orden vieja.

## Revisión de código (agente independiente) y qué se corrigió
Sin críticos de ejecución remota: el canal (dueño, grupos, reenvíos, medios), los orígenes remoto/tarea, el token y las confirmaciones salieron limpios. Se corrigieron:
- **Crítico — autoarranque:** el verificador vivía en la USB y no estaba en la huella → ahora vive en el PC, comprueba el nº de serie de la USB y cubre más archivos (Ollama, brain.json). 5 pruebas.
- **Alto — token a otro destino:** `policy.json` podía redirigirlo → el host está fijado en código (`api.telegram.org`); el modo de prueba solo admite localhost.
- **Alto — 2.ª instancia borraba el pid** del agente vivo → solo la instancia dueña limpia (y de ahí el Ollama colgado). Comprobado que `finally` corre con `exit` dentro de `try`.
- **Alto — Telegram sin red al arrancar** quedaba desactivado → reintenta con espera creciente.
- **Alto — Ollama caído** nadie lo reiniciaba → el agente sale (código 2) y el vigilante `.bat` lo levanta dentro del bucle; la consola ya no mata el Ollama del agente al salir.
- **Alto — `tasks.json` ilegible → se guardaba vacío** (se perdían tareas) → ahora avisa y no escribe; candado entre consola y demonio; `.tmp` por proceso; tarea marcada antes de ejecutarse.
- **Alto — `/remoto desvincular` no surtía efecto** hasta reiniciar → el dueño se relee en cada vuelta (y va firmado).
- **Medio:** firma ampliada (programación) + prueba firmada de aprobación (una tarea pendiente activada a mano se bloquea); candado de política; herramientas remotas firmadas y con tope; tiempos de espera del modelo acotados; STOP detiene el lote; búsquedas espaciadas; Edge del agente en segundo plano y cerrado tras 10 min sin uso; QuickEdit desactivado; vigilante `.bat` con tope de reinicios; mensajes del dueño descartados por reloj desfasado se registran; `/stop` exento del límite de mensajes; acentos de Telegram leídos como UTF-8; enlaces omitidos al enviar.
- **Bajo:** "9 amigos" ya no se lee como "9 am"; "cada 2 días" funciona; buzón con tope; rotación de la auditoría del agente.
- **Sin corregir (documentado):** DoS de la ventana de emparejamiento por desconocidos; Edge del agente queda vivo si se cierra la ventana a la fuerza (se limpia al siguiente arranque); quien tenga escritura en la USB puede reactivar una tarea ya completada (con la firma intacta).

## Agentes desplegados
- Investigación A: OpenClaw y proyectos similares. Investigación B: canales (Telegram/WhatsApp) y 24/7 en Windows. Seguridad: modelo de amenazas del agente remoto. Revisión de código al terminar.

## Pendiente del dueño
- Crear el bot (@BotFather) y ejecutar `Configurar-Telegram.bat`; probar en un bot real.
- Decidir si quiere el inicio automático con Windows.
- Decidir si quiere WhatsApp por la vía oficial con un relay (proyecto aparte).
