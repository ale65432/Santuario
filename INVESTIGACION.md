# Santuario — investigación (2026-10-07)

Datos leídos de Ollama, Hugging Face y GitHub. Las velocidades (tok/s) son **estimaciones extrapoladas**
desde la medición real de llama3.2:1b Q8_0 (~6-8 tok/s). Hay que medirlas en el PC de 4 GB.

## Presupuesto de RAM (PC de 4 GB)
Windows 11 usa ~1.5-2 GB en reposo, quedan ~2 GB. Regla: GGUF <= 1.3-1.4 GB, contexto 4k, un solo modelo cargado
(`OLLAMA_MAX_LOADED_MODELS=1`, ya configurado en Santuario.bat).

## Modelos candidatos (tags de Ollama verificados)
| Modelo | Tag / fuente | Disco | Licencia | Rol propuesto |
|---|---|---|---|---|
| Qwen3.5 2B | `hf.co/unsloth/Qwen3.5-2B-GGUF:Q4_K_M` (1.28 GB) | 1.28 GB | Apache-2.0 | Principal: español + tools (código sin verificar) |
| Qwen2.5-Coder 1.5B | `qwen2.5-coder:1.5b` | 0.99 GB | Apache-2.0 | Especialista en código |
| Granite 4.0 1B híbrido | `hf.co/ibm-granite/granite-4.0-h-1b-GGUF:Q4_K_M` | 0.90 GB | Apache-2.0 | Agente / tool calling (HumanEval ~74) |
| Qwen3.5 0.8B | `qwen3.5:0.8b-q8_0` | 1.0 GB | Apache-2.0 (asumida) | Respaldo ultraligero |
| Gemma 3 1B | `gemma3:1b` | 0.82 GB | Gemma ToU | Charla en español |
Descartados: Qwen2.5-Coder 3B (licencia no comercial y 1.9 GB), LFM2.5 Thinking (no recomendado para código), modelos >=3B.
Cuantización: Q4_K_M. Evitar Q2/Q3. Desactivar "thinking" en Qwen3/3.5 (gasta tokens a 5-10 tok/s).

## Entrenamiento (en la nube, no en el PC de 4 GB)
- Herramienta: **Unsloth** (Apache-2.0) en Google Colab T4 gratis, QLoRA 4-bit, notebooks en github.com/unslothai/notebooks.
- Flujo: LoRA -> merge -> GGUF (q4_k_m) -> copiar a `training/output` -> `ollama create`.
- Alternativas: LLaMA-Factory (interfaz web), Axolotl. llama.cpp para convertir/cuantizar.
- Datos: 5-20K ejemplos mezclados (Magicoder-OSS-Instruct, CodeAlpaca, xlam/hermes function-calling, es2bash,
  alpaca-spanish) + **cientos de ejemplos propios en español sobre tus automatizaciones** (lo que más aporta).
  Faltan datasets de PowerShell en español: hay que generarlos.
- Licencias: varios datasets son sintéticos (GPT); riesgo bajo para uso personal. Llevar lista de atribuciones si se publica.
- Colab es efímero: guardar adaptador y GGUF en Drive antes de cerrar.

## Alternativa más barata que el fine-tuning
System prompt fuerte + ejemplos few-shot + RAG ligero (nomic-embed-text ~270 MB vía Ollama + almacén en archivo).
Da gran parte del valor con menos riesgo. No cargar modelo de chat y de embeddings a la vez en 4 GB.

## Fase 2 (agente de navegador), solo referencia
browser-use (MIT), Playwright MCP (Apache-2.0), Stagehand (MIT). Un modelo de 1-2B en CPU probablemente no sea fiable
para controlar el navegador; empezar por Granite 4.0 1B y probar. Revisar el código de cada repo antes de adoptarlo.
