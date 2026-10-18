# Fase "Manos" — estado

Objetivo: que Santuario pueda usar el navegador Edge (YouTube, redes sociales, buscar en Google para investigar) y abrir programas del PC,
sin dejar de ser local: el modelo y Ollama siguen SIN internet (modo local de `Santuario.bat`); solo Edge sale a la red.

## Decisiones de diseño
- Control de Edge con **PowerShell puro + CDP** (WebSocket local). No hace falta instalar nada (ni Node, ni Playwright, ni drivers).
- **Herramientas de alto nivel y deterministas**, no un agente con clic libre: abrir sitio, buscar en Google (lee resultados), buscar/reproducir en YouTube, abrir programa de la lista.
- El modelo solo **propone** `{accion, argumento}` (JSON con esquema); el **código** valida (listas blancas), confirma (código tecleado) y registra.
- Lo obvio se resuelve con **reglas** (sin gastar el modelo); el modelo pequeño solo interviene como respaldo.
- **Contexto de sesión**: sabe qué sitio tiene abierto y reutiliza SU pestaña ("ahora busca X" busca en ese YouTube; "pon el primero" reproduce lo buscado). Cada acción queda en el historial que ve el modelo.
- El texto de internet es dato no confiable: nunca produce acciones; se resume en una pasada aparte con delimitadores aleatorios.

## Hecho (2026-10-08)
- Investigación (opciones técnicas) y modelo de amenazas por agentes; revisión de código por un tercer agente (sin críticos; altos/medios corregidos).
- `hands.ps1`, `policy.json`, integración en el router (`/manos`, `/manos off`, `/manos login`, `/manos borrar-sesion`).
- Pruebas: 130 unitarias (frases, contexto, URLs engañosas, texto invisible, auditoría), 22 de extremo a extremo con Edge real, y prueba con la app real escribiendo en su ventana.
- Hallazgos corregidos: Edge cargaba extensiones del sistema (ahora `--disable-extensions`), carpetas de usuario redirigidas a la USB rompían el perfil (ahora se calculan las reales), texto largo/código nunca sale a internet, excepciones no tumban la sesión.

## Límites conocidos
- Google puede pedir verificación (captcha) a navegadores automatizados: se detiene y te pide resolverla en la ventana.
- Las redes sociales solo se abren; no se busca ni se escribe dentro de ellas.
- Edge pasa al frente al abrir una página; hay que volver a la ventana de Santuario para seguir escribiendo.
- El perfil de Edge ("host") queda en el PC donde se use; `/manos borrar-sesion` lo elimina.
- Sin pruebas con redes sociales reales ni con reproducción de video (se probó en seco para no sonar sin aviso).

## Siguiente
- Entrenamiento propio (Colab/Unsloth) y RAG con tus documentos.
