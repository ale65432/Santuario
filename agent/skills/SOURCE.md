# Procedencia de las habilidades del taller (2026-10-10)

Codigo propio de Santuario (PowerShell 5.1), escrito en esta sesion. No se instalo ni copio ningun paquete.

- Patrones de secretos (`codescan.ps1`): formas de token publicadas por gitleaks (MIT, github.com/gitleaks/gitleaks, config/gitleaks.toml) y la lista de palabras clave de detect-secrets (Apache-2.0, github.com/Yelp/detect-secrets). Reescritos a mano para .NET y probados con positivos y negativos propios; las reglas por lenguaje se escribieron a partir de la guia de un agente de investigacion (no verificadas contra una fuente) y se afinaron con las pruebas.
- Revision de seguridad del PC (`pcscan.ps1`): comprobaciones de solo lectura con cmdlets estandar de Windows.
- Sistema de diseno de las paginas (`design/`): creado por un agente de diseno de esta sesion. Los contrastes se recalculan en codigo (`Test-PaletteContrast`); solo se usan fuentes del sistema y no hay recursos externos.
- Modelo de amenazas: informe del agente de seguridad de esta sesion (sandbox de rutas, lista negra, escritura segura, entrada no confiable). Ver `agent\PLAN-SKILLS.md`.

Nada de esto se ejecuta solo: no hay hooks ni inicio automatico. Todo se invoca desde la consola con comandos escritos por el dueno.
