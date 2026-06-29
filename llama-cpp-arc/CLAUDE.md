# llama-cpp-arc — llama.cpp SYCL nativo (Intel Arc 140V)

Sucesor de `../ipex-llm/`. Contexto de hardware y ecosistema en `../CLAUDE.md`.
Guía de instalación completa: `local-llm-yoga-slim7-ubuntu2404-llamacpp.md`

## Estructura del proyecto

```
llama-cpp-arc/
├── llama.cpp/          # repositorio clonado — compilar aquí
│   └── build/bin/      # binarios: llama-server, llama-bench, llama-cli
├── models/             # GGUFs descargados de Hugging Face
├── start-server.sh     # script de arranque (activa oneAPI + lanza llama-server)
└── local-llm-yoga-slim7-ubuntu2404-llamacpp.md  # guía completa de instalación
```

## Comandos de desarrollo

```bash
# Antes de cualquier tarea: activar entorno oneAPI
source /opt/intel/oneapi/setvars.sh

# Verificar GPU
sycl-ls

# Compilar (tras git pull en llama.cpp/ o cambio de flags)
cmake --build llama.cpp/build --config Release -j$(nproc) \
  --target llama-server llama-bench llama-cli

# Arrancar servidor
./start-server.sh                        # modelo por defecto
./start-server.sh models/<nombre>.gguf  # modelo específico
```

## Stack

- **Backend**: llama.cpp compilado con `GGML_SYCL=ON` + compilador Intel `icx/icpx` (oneAPI)
- **Servidor**: `llama-server` — API OpenAI-compatible en `localhost:8080`
- **Sin Docker** — instalación nativa
- **Modelos**: GGUFs de Hugging Face (bartowski, unsloth, lmstudio-community)

## Estado

Proyecto en bootstrap — compilación y validación pendientes.

## Notas de desarrollo

- Los paquetes oneAPI del compilador usan `apt.repos.intel.com/oneapi` — distinto del repo de GPU drivers (`repositories.intel.com/gpu`) que no funciona con Xe2
- `sycl-ls` es el primer diagnóstico: si no muestra el Arc 140V, el problema es Level Zero runtime, no el compilador
