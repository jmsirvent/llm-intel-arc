# ~/llm — Local LLM Inference (Intel Arc 140V)

Contexto compartido para todos los proyectos de inferencia local bajo este directorio.
Los proyectos heredan estas instrucciones; cada uno tiene su propio CLAUDE.md con detalles específicos.

## Hardware

- **Máquina**: Lenovo Yoga Slim 7 — Intel Core Ultra 7 258V (Lunar Lake)
- **iGPU**: Arc 140V (Xe2, 8 Xe-cores) — memoria compartida con CPU (LPDDR5x)
- **RAM total**: 32 GB LPDDR5X-8533 | ~20 GB disponibles en uso cotidiano (OS + escritorio + apps consumen ~12 GB)
- **OS**: Ubuntu 24.04 LTS

## Drivers y stack de compute

- **Driver kernel**: `xe` (NO `i915` — Xe2 usa driver diferente)
- **Compute stack**: Level Zero → SYCL (oneAPI) — mismo stack en todos los proyectos
- **Drivers GPU**: usar `ppa:ubuntu-oem/intel-graphics-preview` (el repo oficial Intel `repositories.intel.com` NO funciona para Xe2/Lunar Lake en Ubuntu 24.04)

## Monitorización GPU

`intel_gpu_top` NO funciona con driver `xe` (usa PMU de `i915`). Alternativa:

```bash
sudo xpu-smi dump -d 0 -m 0,5,18 -i 1   # utilización, VRAM, potencia — necesita sudo para engines
xpu-smi stats -d 0                        # snapshot puntual: frecuencia, temperatura, memoria
```

## Estado del ecosistema Intel LLM (junio 2026)

| Proyecto | Estado | Notas |
|---|---|---|
| `intel/ipex-llm` | **Archivado** enero 2026 | Security issues conocidos; imagen Docker congelada |
| `ipex-llm/ipex-llm` | Fork comunitario activo | 139 stars, última release abril 2025 — incierto |
| `intel-oneapi-*` (apt) | **Activo** | Compilador SYCL (icx/icpx) + MKL disponibles en Ubuntu 24.04 |
| `llama.cpp` upstream | **Activo** | Backend real de todos los stacks; SYCL soportado con oneAPI |

## Proyectos

| Directorio | Stack | Estado | Propósito |
|---|---|---|---|
| `ipex-llm/` | IPEX-LLM (Ollama fork SYCL, Docker) | Producción, congelado | Stack actual funcional |
| `llama-cpp-arc/` | llama.cpp SYCL nativo (sin Docker) | En desarrollo | Stack futuro — acceso a features upstream (speculative decoding, IQ quants, modelos nuevos) |

## Decisión de arquitectura

Los proyectos bajo `~/llm/` priorizan **instalación nativa sobre Docker** para inferencia local en monopuesto:
- Acceso directo al GPU sin passthrough ni device mapping
- Menor overhead de gestión
- Docker se usó con IPEX-LLM porque era la única forma de distribuir ese stack — no por preferencia
