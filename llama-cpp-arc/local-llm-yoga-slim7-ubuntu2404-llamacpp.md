# Local LLM Inference — Yoga Slim 7 14ILL10 (llama.cpp SYCL)
**Ubuntu 24.04 LTS · Intel Core Ultra 7 258V · Intel Arc 140V (Xe2) · 32 GB LPDDR5X**

> **Documento en evolución.** Las secciones validadas en hardware real están marcadas con ✅.
> Las marcadas con ⚠️ están documentadas pero pendientes de prueba — pueden requerir ajustes.

---

## Índice

1. [Resumen de hardware y arquitectura de solución](#1-resumen-de-hardware-y-arquitectura-de-solución)
2. [Prerequisitos del sistema](#2-prerequisitos-del-sistema)
3. [Intel GPU Compute Runtime (Level Zero — host-side)](#3-intel-gpu-compute-runtime-level-zero--host-side)
4. [oneAPI — compilador SYCL e Intel MKL](#4-oneapi--compilador-sycl-e-intel-mkl)
5. [Compilación de llama.cpp con backend SYCL](#5-compilación-de-llamacpp-con-backend-sycl)
6. [llama-server — configuración y arranque](#6-llama-server--configuración-y-arranque)
7. [Modelos recomendados](#7-modelos-recomendados)
8. [Gestión de modelos y benchmarking](#8-gestión-de-modelos-y-benchmarking)
9. [Integración con herramientas externas](#9-integración-con-herramientas-externas)
10. [Systemd service (autoarranque)](#10-systemd-service-autoarranque)
11. [Tuning de SO para rendimiento](#11-tuning-de-so-para-rendimiento)
12. [Troubleshooting](#12-troubleshooting)

---

## 1. Resumen de hardware y arquitectura de solución

| Componente | Detalle |
|---|---|
| CPU | Intel Core Ultra 7 258V (Lunar Lake, 8 cores @ 4.7 GHz) |
| GPU | Intel Arc 140V (Xe2 iGPU, 8 Xe2 cores, driver: `xe`) |
| NPU | Intel AI Boost / Lunar Lake NPU (`intel_vpu`) |
| RAM | 32 GB LPDDR5X-8533 unificada (shared CPU/GPU/NPU, ~97 GB/s) |
| Storage | Samsung NVMe PM9C1b 1 TB |
| OS | Ubuntu 24.04 LTS, kernel 6.19.10 |

### Por qué llama.cpp SYCL nativo

El stack anterior (`../ipex-llm/`) usaba IPEX-LLM, un fork de Ollama parchado por Intel para SYCL/Level Zero. Ese proyecto fue archivado en enero 2026. llama.cpp es el motor de inferencia subyacente real — IPEX-LLM lo envolvía en Docker para distribuir el toolchain de Intel precompilado.

Este stack compila llama.cpp directamente con el compilador Intel `icx/icpx` (oneAPI), sin intermediarios Docker. Lo que se gana:

- Speculative decoding (draft model) — +50–150 % potencial en generación
- IQ quantizations (IQ4\_XS, IQ3\_M) — mejor calidad/GB que K\_M
- Soporte de modelos nuevos al día con upstream llama.cpp
- API OpenAI-compatible en `localhost:8080` — mismos clientes que con Ollama, solo cambia el puerto

```
VS Code (Twinny / Cline / Roo Code) · Open WebUI · Scripts Python
                     │
                     │  OpenAI-compatible REST  (localhost:8080)
                     ▼
            llama-server  (llama.cpp SYCL)
                     │
                     │  SYCL / Level Zero
                     ▼
          Intel Arc 140V  (Xe2, driver xe)
          ──────────────────────────────────
          LPDDR5X-8533  ·  32 GB  unificada
```

---

## 2. Prerequisitos del sistema ✅

### 2.1 Verificar que el GPU está activo con driver xe

```bash
# Driver xe activo para el iGPU (NO i915 — Xe2 usa driver diferente)
lspci -k | grep -A3 -i "VGA\|Display"
# Debe mostrar: Kernel driver in use: xe

# Dispositivos DRI disponibles
ls -la /dev/dri/
# Esperado: card1, renderD128
```

### 2.2 Grupos de usuario

```bash
# Añadir usuario a los grupos render y video
sudo usermod -aG render,video $USER

# Verificar membresía
groups $USER
# Debe incluir: render video

# IMPORTANTE: cerrar sesión y volver a entrar para que los grupos se activen.
```

### 2.3 Dependencias de compilación

```bash
sudo apt update
sudo apt install -y \
  git cmake ninja-build \
  pkg-config \
  libgomp1 \
  python3-pip
```

---

## 3. Intel GPU Compute Runtime (Level Zero — host-side) ✅

Este paso instala las librerías userspace de Level Zero en el host Ubuntu 24.04.
Son las que permiten que el runtime SYCL se comunique con el driver `xe` del kernel.

> **Método validado en Lunar Lake (Xe2):** el repositorio oficial de Intel (`repositories.intel.com/gpu/ubuntu noble`) **no incluye** paquetes actualizados para Xe2. El único método que funciona es el **PPA de Canonical Intel Graphics Preview**, mantenido en colaboración con Intel:
> [`https://github.com/canonical/intel-graphics-preview`](https://github.com/canonical/intel-graphics-preview)

```bash
# Añadir el PPA de Canonical Intel Graphics Preview
sudo add-apt-repository ppa:ubuntu-oem/intel-graphics-preview
sudo apt update

# Instalar compute runtime con soporte Xe2 / Lunar Lake
sudo apt install -y \
  libze-intel-gpu1 \
  libze1 \
  intel-opencl-icd \
  intel-level-zero-gpu \
  level-zero \
  clinfo

# Verificar detección del GPU vía Level Zero
clinfo -l
# Esperado:
# Platform #0: Intel(R) OpenCL Graphics
#  -- Device #0: Intel(R) Arc(TM) 140V Graphics

ls /dev/dri/
# card1  renderD128
```

> **Por qué el PPA:** el repositorio `repositories.intel.com/gpu/ubuntu noble` existe pero no contiene versiones compatibles con Xe2/Lunar Lake para Ubuntu 24.04 Noble. El PPA `ubuntu-oem/intel-graphics-preview` es el canal oficial Intel+Canonical para hardware reciente. Es el mismo repo utilizado en el stack IPEX-LLM anterior.

---

## 4. oneAPI — compilador SYCL e Intel MKL ⚠️

> **Nota de arquitectura:** el repositorio `apt.repos.intel.com/oneapi` (compilador + MKL) es **distinto** del repositorio de GPU drivers que no funciona con Xe2. Los paquetes oneAPI del compilador sí funcionan en Ubuntu 24.04 Noble.

```bash
# Añadir GPG key y repositorio oneAPI
wget -O- https://apt.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB \
  | gpg --dearmor \
  | sudo tee /usr/share/keyrings/oneapi-archive-keyring.gpg > /dev/null

echo "deb [signed-by=/usr/share/keyrings/oneapi-archive-keyring.gpg] \
  https://apt.repos.intel.com/oneapi all main" \
  | sudo tee /etc/apt/sources.list.d/oneAPI.list

sudo apt update

# Instalar compilador SYCL (icx/icpx) + MKL
sudo apt install -y \
  intel-oneapi-dpcpp-cpp \
  intel-oneapi-mkl \
  intel-oneapi-mkl-devel

# Verificar instalación
source /opt/intel/oneapi/setvars.sh

icx --version
# Intel(R) oneAPI DPC++/C++ Compiler ...

# Verificar que sycl-ls detecta el Arc 140V
sycl-ls
# Esperado (entre otros):
# [opencl:gpu][opencl:0] Intel(R) OpenCL Graphics, Intel(R) Arc(TM) 140V Graphics ...
# [level_zero:gpu][level_zero:0] Intel(R) Level-Zero, Intel(R) Arc(TM) 140V Graphics ...
```

> ⚠️ **Si `sycl-ls` no muestra el Arc 140V:** el problema es el Level Zero runtime (§3), no el compilador. Verificar que `clinfo -l` sí muestra el GPU antes de continuar.

> **`setvars.sh`**: este script configura `PATH`, `LD_LIBRARY_PATH`, `MKLROOT` y variables de entorno necesarias para icx/icpx y MKL. Debe ejecutarse en cada sesión de terminal antes de compilar o arrancar el servidor. Ver §6 para activación automática vía systemd.

---

## 5. Compilación de llama.cpp con backend SYCL ⚠️

```bash
# Clonar llama.cpp
git clone https://github.com/ggml-org/llama.cpp.git
cd llama.cpp

# Activar entorno oneAPI (si no está ya activo)
source /opt/intel/oneapi/setvars.sh

# Compilar con backend SYCL
cmake -B build \
  -DGGML_SYCL=ON \
  -DCMAKE_C_COMPILER=icx \
  -DCMAKE_CXX_COMPILER=icpx \
  -DGGML_SYCL_F16=ON \
  -DCMAKE_BUILD_TYPE=Release

cmake --build build --config Release -j$(nproc) \
  --target llama-server llama-bench llama-cli

# Verificar que el binario detecta el GPU
./build/bin/llama-server --list-devices
# Debe listar Intel Arc 140V como dispositivo disponible
```

> **`DGGML_SYCL_F16=ON`**: activa operaciones en FP16 en el backend SYCL. Reduce el uso de memoria y puede mejorar el throughput en hardware con soporte nativo FP16 como el Arc 140V Xe2. Pendiente de verificar impacto real en este hardware.

> **Tiempo de compilación:** la compilación con icx/icpx tarda más que con gcc/clang por la profundidad de optimizaciones SYCL. Esperar 5–15 minutos en función del número de cores disponibles.

> **`nproc`**: usa todos los cores disponibles. En el Core Ultra 7 258V (8 cores), `-j8` es equivalente. Puedes reducir a `-j4` si necesitas usar el equipo durante la compilación.

---

## 6. llama-server — configuración y arranque ⚠️

### 6.1 Variables de entorno SYCL

```bash
# Activar oneAPI (necesario en cada sesión)
source /opt/intel/oneapi/setvars.sh

# Seleccionar el Arc 140V (primer dispositivo Level Zero)
export GGML_SYCL_DEVICE=0

# Cache persistente de kernels SYCL compilados (evita recompilación en cada arranque)
export SYCL_CACHE_PERSISTENT=1

# Permite que el runtime consulte métricas del GPU
export ZES_ENABLE_SYSMAN=1
```

### 6.2 Arrancar el servidor

```bash
cd ~/llm/llama-cpp-arc/llama.cpp

./build/bin/llama-server \
  -m models/qwen2.5-coder-14b-instruct-q4_k_m.gguf \
  --port 8080 \
  --host 0.0.0.0 \
  --n-gpu-layers 999 \
  --ctx-size 8192 \
  --parallel 1 \
  --log-disable

# Verificar que el servidor responde
curl http://localhost:8080/health
# {"status":"ok"}
```

| Parámetro | Valor | Descripción |
|---|---|---|
| `--n-gpu-layers 999` | 999 (todas) | Carga todas las capas en GPU — sin split CPU/GPU |
| `--ctx-size` | 8192 | Contexto por defecto; subir a 16384–32768 según modelo y RAM disponible |
| `--parallel` | 1 | Single-user explícito — evita reservar buffers para peticiones paralelas |
| `--port` | 8080 | Puerto del API (distinto de Ollama que usa 11434) |
| `--host` | 0.0.0.0 | Escuchar en todas las interfaces |

### 6.3 Primera carga de modelo

La primera vez que se carga un modelo, el runtime SYCL compila los kernels para el hardware específico (Arc 140V Xe2). Esto tarda **2–5 minutos** y es completamente normal. Las compilaciones se cachean en `~/.cache/sycl/` y las cargas posteriores son casi instantáneas.

```bash
# Ver logs del servidor durante la primera carga
# El servidor imprime el progreso de compilación SYCL en stderr
```

### 6.4 Script de arranque

Crear `~/llm/llama-cpp-arc/start-server.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Directorio del proyecto
LLAMACPP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/llama.cpp" && pwd)"
MODELS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/models" && pwd)"

# Activar oneAPI
source /opt/intel/oneapi/setvars.sh --force

# Variables SYCL
export GGML_SYCL_DEVICE=0
export SYCL_CACHE_PERSISTENT=1
export ZES_ENABLE_SYSMAN=1

# Modelo por defecto (pasar como argumento para cambiarlo)
MODEL="${1:-${MODELS_DIR}/qwen2.5-coder-14b-instruct-q4_k_m.gguf}"

exec "${LLAMACPP_DIR}/build/bin/llama-server" \
  -m "${MODEL}" \
  --port 8080 \
  --host 0.0.0.0 \
  --n-gpu-layers 999 \
  --ctx-size 8192 \
  --parallel 1
```

```bash
chmod +x ~/llm/llama-cpp-arc/start-server.sh

# Uso
./start-server.sh                                          # modelo por defecto
./start-server.sh models/qwen3-8b-q4_k_m.gguf            # modelo específico
```

---

## 7. Modelos recomendados ⚠️

### Presupuesto de memoria

- RAM total: 32 GB
- OS + escritorio + apps en uso: ~11–12 GB
- Disponible para modelos (medido con IPEX-LLM): ~19–20 GB tras reboot limpio
- **Techo seguro en uso cotidiano: 16 GB de modelo**

> Con 32 GB de RAM unificada no es posible separar "VRAM del GPU" del resto de la RAM. El Arc 140V accede a la misma piscina LPDDR5X que el CPU.

> ⚠️ **Comportamiento del driver xe:** una vez el driver xe asigna páginas de RAM al pool GPU (al cargar el primer modelo), no las devuelve al sistema aunque el modelo se descargue. La memoria solo se recupera completamente con un reboot o `echo 3 > /proc/sys/vm/drop_caches` tras parar el servidor.

### 7.1 Modelos recomendados (GGUFs de Hugging Face)

Usar siempre publishers verificados: **bartowski**, **unsloth**, **lmstudio-community**. No usar publishers desconocidos.

| Modelo | Quant | Tamaño disco | Rol | Fuente HF |
|---|---|---|---|---|
| Qwen2.5-Coder-14B-Instruct | Q4\_K\_M | ~9.0 GB | Coding agentic (Cline) | bartowski |
| Qwen3-8B | Q4\_K\_M | ~5.2 GB | Razonamiento / contexto largo | unsloth |
| Llama-3.1-8B-Instruct | Q4\_K\_M | ~4.9 GB | General rápido | bartowski |
| Gemma-3-12B-IT | Q4\_K\_M | ~8.1 GB | General / visión | bartowski |
| Phi-4-mini-Instruct | Q4\_K\_M | ~2.5 GB | Autocompletado FIM (Twinny) | bartowski |

> Los valores de RAM runtime con llama.cpp SYCL **están pendientes de medición**. Como referencia, IPEX-LLM con Flash Attention usaba ~40 % menos que el tamaño en disco.

### 7.2 Descarga de modelos

```bash
# Instalar huggingface-cli
pip install --user huggingface-hub

mkdir -p ~/llm/llama-cpp-arc/models

# Descargar modelo específico (ejemplo: Qwen2.5-Coder-14B Q4_K_M)
huggingface-cli download \
  bartowski/Qwen2.5-Coder-14B-Instruct-GGUF \
  Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf \
  --local-dir ~/llm/llama-cpp-arc/models

# Descargar Qwen3-8B
huggingface-cli download \
  unsloth/Qwen3-8B-GGUF \
  Qwen3-8B-Q4_K_M.gguf \
  --local-dir ~/llm/llama-cpp-arc/models
```

---

## 8. Gestión de modelos y benchmarking ⚠️

### 8.1 Verificar inferencia GPU

```bash
# Con el servidor arrancado, enviar un prompt y verificar respuesta
curl -s http://localhost:8080/completion \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "Explain in exactly 50 words what a transformer neural network is.",
    "n_predict": 128,
    "stream": false
  }' | python3 -m json.tool | grep -E '"content"|"tokens_per_second"|"timings"'

# API compatible OpenAI (chat completions)
curl -s http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "local",
    "messages": [{"role": "user", "content": "Hello"}],
    "stream": false
  }' | python3 -m json.tool
```

### 8.2 Monitorización del GPU durante inferencia ✅

> `intel_gpu_top` **no funciona** con el driver `xe` (Lunar Lake/Xe2). Usa `xpu-smi` en su lugar.

```bash
# Snapshot puntual
xpu-smi stats -d 0

# Monitorización continua: utilización + memoria + frecuencia
# -m 0=GPU_UTIL, 5=MEM_UTIL, 18=MEM_USED  |  -i intervalo en segundos
sudo xpu-smi dump -d 0 -m 0,5,18 -i 1

# Sin sudo (sin utilización de engines, el resto funciona)
xpu-smi dump -d 0 -m 5,18 -i 1

# Frecuencia activa via sysfs (sin herramientas extra)
watch -n1 'echo "Act: $(cat /sys/class/drm/card1/device/tile0/gt0/freq0/act_freq) MHz" && \
           echo "Cur: $(cat /sys/class/drm/card1/device/tile0/gt0/freq0/cur_freq) MHz"'
```

**Combinación práctica durante inferencia** (dos terminales):
```bash
# Terminal 1 — GPU
sudo xpu-smi dump -d 0 -m 0,5,18 -i 1

# Terminal 2 — memoria del sistema
watch -n1 'grep -E "MemFree|MemAvailable" /proc/meminfo'
```

### 8.3 Benchmark con llama-bench

```bash
# Benchmark básico: prefill y generación
./build/bin/llama-bench \
  -m models/qwen3-8b-q4_k_m.gguf \
  -n 128 \
  -ngl 999

# Opciones útiles:
# -n <tokens>       tokens a generar
# -p <tokens>       tokens de prompt (prefill)
# -ngl <layers>     capas en GPU (999 = todas)
# -t <threads>      threads CPU (relevante solo si algunas capas van a CPU)
```

> Los resultados de `llama-bench` se añadirán a este documento una vez validados en Arc 140V.

**Referencia baseline — IPEX-LLM (mismos modelos Q4\_K\_M, Arc 140V, CTX=8192):**

| Modelo | Gen tok/s | Prefill tok/s | TTFT ms |
|---|---|---|---|
| qwen2.5-coder:7b | 20.0 | 814 | 56 ms |
| qwen3:8b | 18.1 | 522 | 62 ms |
| llama3.1:8b-instruct | 18.9 | 429 | 56 ms |
| gemma3:12b | 10.5 | 240 | 100 ms |
| qwen2.5:14b-instruct | 10.7 | 451 | 100 ms |

---

## 9. Integración con herramientas externas ⚠️

El endpoint de llama-server es compatible con la spec de OpenAI. La diferencia respecto al stack IPEX-LLM es el puerto (`8080` en lugar de `11434`) y que no hay registro de modelos — el modelo se especifica al arrancar el servidor, no al llamar a la API.

### 9.1 Datos de conexión

| Parámetro | Valor |
|---|---|
| Endpoint OpenAI-compatible | `http://localhost:8080/v1` |
| Endpoint llama.cpp nativo | `http://localhost:8080` |
| API Key | cualquier valor no vacío (p.ej. `llama`) |
| Modelos disponibles | el modelo activo al arrancar el servidor |

### 9.2 VS Code — extensiones

#### Twinny — autocompletado inline + chat

| Ajuste | Valor |
|---|---|
| API hostname | `localhost` |
| API port | `8080` |
| Fill-in-middle model | `phi4-mini` (o el nombre que aparezca en `/v1/models`) |
| Chat model | `qwen3:8b` |
| API provider | `llamacpp` u `OpenAI Compatible` |

> ⚠️ Verificar qué valor de `model` acepta Twinny cuando el backend es llama-server (el campo puede requerir el nombre del fichero GGUF o cualquier string según la versión).

#### Cline / Roo Code — agente de codificación

| Ajuste | Valor |
|---|---|
| API Provider | `OpenAI Compatible` |
| Base URL | `http://localhost:8080/v1` |
| API Key | `llama` |
| Model | (nombre que devuelva `/v1/models`) |

#### CodeGPT — chat simple

| Ajuste | Valor |
|---|---|
| LLM Provider | `Custom` / `OpenAI Compatible` |
| API URL | `http://localhost:8080/v1` |
| Model | (nombre del modelo activo) |

### 9.3 API compatible con OpenAI (scripts Python)

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:8080/v1",
    api_key="llama",  # Requerido por el cliente pero ignorado por llama-server
)

response = client.chat.completions.create(
    model="local",
    messages=[
        {"role": "system", "content": "You are a helpful assistant. Reply only in JSON."},
        {"role": "user", "content": "Extract vendor and total from: Invoice from Acme Corp, total $1,234.56"},
    ],
    temperature=0.1,
)
print(response.choices[0].message.content)
```

---

## 10. Systemd service (autoarranque) ⚠️

```bash
sudo tee /etc/systemd/system/llama-server.service > /dev/null <<'EOF'
[Unit]
Description=llama-server SYCL (Intel Arc 140V)
After=multi-user.target
Wants=network-online.target

[Service]
Type=simple
User=YOUR_USER
WorkingDirectory=/home/YOUR_USER/llm/llama-cpp-arc

# Activar oneAPI antes de arrancar el servidor
ExecStartPre=/bin/bash -c 'source /opt/intel/oneapi/setvars.sh --force'
ExecStart=/home/YOUR_USER/llm/llama-cpp-arc/start-server.sh

Environment=GGML_SYCL_DEVICE=0
Environment=SYCL_CACHE_PERSISTENT=1
Environment=ZES_ENABLE_SYSMAN=1

Restart=on-failure
RestartSec=10s
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
EOF

# Reemplazar YOUR_USER con tu usuario
sudo sed -i "s/YOUR_USER/$USER/g" /etc/systemd/system/llama-server.service

# Habilitar
sudo systemctl daemon-reload
sudo systemctl enable --now llama-server.service

# Estado
sudo systemctl status llama-server.service
```

> ⚠️ **`source` en ExecStartPre:** systemd no propaga variables de entorno entre directivas. Puede ser necesario inline el contenido de `setvars.sh` en el service o usar `EnvironmentFile`. Pendiente de validar la forma correcta de activar oneAPI en un service unit.

---

## 11. Tuning de SO para rendimiento ✅

Dos ficheros de configuración que mejoran la estabilidad y el rendimiento de la inferencia. Independientes del servidor — persisten a través de reboots. Idénticos a los del stack IPEX-LLM anterior.

### sysctl (`/etc/sysctl.d/99-llm-performance.conf`)

```bash
sudo tee /etc/sysctl.d/99-llm-performance.conf > /dev/null <<'EOF'
# Memoria
vm.swappiness = 10               # Evitar swap con 30 GB de RAM disponibles
vm.dirty_background_ratio = 5    # Flush de escrituras al 5%
vm.dirty_ratio = 15
vm.vfs_cache_pressure = 50       # Retener caché de inodos/dentries — carga de modelos más rápida
vm.min_free_kbytes = 524288      # Reservar 512 MB libres

# Red (API localhost:8080)
net.ipv4.tcp_fastopen = 3        # Reduce latencia en conexiones TCP localhost
EOF

# Aplicar sin reboot
sudo sysctl -p /etc/sysctl.d/99-llm-performance.conf
```

### CPU governor + HWP dynamic boost

```bash
sudo tee /etc/systemd/system/cpu-performance.service > /dev/null <<'EOF'
[Unit]
Description=CPU performance governor and HWP dynamic boost
After=multi-user.target
Before=llama-server.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > "$f"; done'
ExecStart=-/bin/sh -c 'echo 1 > /sys/devices/system/cpu/intel_pstate/hwp_dynamic_boost'

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload && sudo systemctl enable --now cpu-performance.service
```

> **`Before=llama-server.service`:** el governor debe estar activo antes de que el servidor empiece a compilar kernels SYCL en el primer arranque.

Verificación:

```bash
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor  # performance
cat /sys/devices/system/cpu/intel_pstate/hwp_dynamic_boost  # 1
cat /proc/sys/vm/swappiness                                 # 10
```

---

## 12. Troubleshooting

### `sycl-ls` no muestra el Arc 140V

```bash
# Verificar que Level Zero detecta el GPU
clinfo -l
# Si no aparece "Intel Arc" → problema de Level Zero en el host (ver §3)

# Verificar grupos del usuario
groups $USER
# Debe incluir: render video

# Si los grupos no están activos después de añadirlos:
newgrp render  # Activar en la sesión actual sin cerrar sesión
```

### Error de compilación: `icx: command not found`

```bash
# oneAPI no está activado en la sesión actual
source /opt/intel/oneapi/setvars.sh
icx --version
```

### El servidor no detecta el GPU (inferencia va a CPU)

```bash
# Verificar que el servidor ve el GPU al arrancar
./build/bin/llama-server --list-devices
# Si no muestra "Intel Arc" → SYCL no está configurado correctamente

# Verificar que sycl-ls funciona antes de arrancar el servidor
source /opt/intel/oneapi/setvars.sh
sycl-ls

# Durante inferencia activa, verificar utilización GPU:
sudo xpu-smi dump -d 0 -m 0,5,18 -i 1
# GPU util (columna 0) debe ser > 80 % durante generación
# Si GPU util ~0 % → la inferencia está yendo por CPU
```

### Error SYCL en tiempo de ejecución: "No device of requested type available"

```bash
# Causa más probable: Level Zero no detecta el GPU correctamente
# o GGML_SYCL_DEVICE apunta a un índice incorrecto

# Ver dispositivos disponibles
source /opt/intel/oneapi/setvars.sh && sycl-ls

# Probar con GGML_SYCL_DEVICE=0 (primer GPU)
GGML_SYCL_DEVICE=0 ./build/bin/llama-server --list-devices
```

### Primera inferencia tarda 2–5 minutos

Comportamiento normal. El runtime SYCL compila los kernels para el Arc 140V Xe2 en el primer uso. Las compilaciones se cachean en `~/.cache/sycl/` (con `SYCL_CACHE_PERSISTENT=1` activo). Las cargas posteriores son casi instantáneas.

### Memoria RAM no se recupera tras parar el servidor

```bash
# Verificar memoria antes de liberar
xpu-smi dump -d 0 -m 5 -i 1 -n 1

# Liberar pool GPU sin reboot (parar servidor primero)
sudo sync && sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
sudo swapoff -a && sudo swapon -a

# Verificar resultado
free -h
```

> El driver `xe` retiene páginas en el pool GPU aunque el servidor esté parado. `drop_caches` fuerza la liberación del page cache. El reboot sigue siendo la opción más limpia pero no es necesario.

### OOM — el modelo no carga

```bash
# Verificar memoria disponible
free -h

# Si MemAvailable < tamaño del modelo → liberar memoria (ver arriba)
# o usar un modelo más pequeño / quantización más agresiva (IQ4_XS en lugar de Q4_K_M)
```

---

## Quick Reference

```bash
# Activar entorno oneAPI (necesario antes de compilar o arrancar)
source /opt/intel/oneapi/setvars.sh

# Verificar GPU
sycl-ls
clinfo -l

# Arrancar servidor (modelo por defecto)
./start-server.sh

# Arrancar con modelo específico
./start-server.sh models/qwen3-8b-q4_k_m.gguf

# Verificar que el servidor responde
curl http://localhost:8080/health

# Test rápido de inferencia
curl -s http://localhost:8080/completion \
  -d '{"prompt":"Hello","n_predict":16,"stream":false}' \
  | python3 -c "import sys,json; d=json.load(sys.stdin); \
    t=d['timings']; print(f\"{t['predicted_per_second']:.1f} tok/s\")"

# Monitorización GPU durante inferencia
sudo xpu-smi dump -d 0 -m 0,5,18 -i 1

# Benchmark
./build/bin/llama-bench -m models/<modelo>.gguf -n 128 -ngl 999

# Recompilar llama.cpp (tras pull de nuevas versiones)
source /opt/intel/oneapi/setvars.sh
cmake --build build --config Release -j$(nproc) \
  --target llama-server llama-bench llama-cli
```
