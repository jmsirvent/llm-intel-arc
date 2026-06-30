# Local LLM Inference — Yoga Slim 7 14ILL10
**Ubuntu 24.04 LTS · Intel Core Ultra 7 258V · Intel Arc 140V (Xe2) · 32 GB LPDDR5X**

---

## Índice

1. [Resumen de hardware y arquitectura de solución](#1-resumen-de-hardware-y-arquitectura-de-solución)
2. [Prerequisitos del sistema](#2-prerequisitos-del-sistema)
3. [Instalación de Docker](#3-instalación-de-docker)
4. [Intel GPU Compute Runtime (Level Zero — host-side)](#4-intel-gpu-compute-runtime-level-zero--host-side)
5. [Backend principal: IPEX-LLM + Ollama (Docker)](#5-backend-principal-ipex-llm--ollama-docker)
6. [Modelos recomendados](#6-modelos-recomendados)
7. [Gestión de modelos](#7-gestión-de-modelos)
8. [Integración con herramientas externas](#8-integración-con-herramientas-externas)
9. [Backend secundario: OpenVINO GenAI (NPU)](#9-backend-secundario-openvino-genai-npu)
10. [Troubleshooting](#10-troubleshooting)

---

## 1. Resumen de hardware y arquitectura de solución

| Componente | Detalle |
|---|---|
| CPU | Intel Core Ultra 7 258V (Lunar Lake, 8 cores @ 4.7 GHz) |
| GPU | Intel Arc 140V (Xe2 iGPU, 8 Xe2 cores, driver: `xe`) |
| NPU | Intel AI Boost / Lunar Lake NPU (`intel_vpu`) |
| RAM | 32 GB LPDDR5X-8533 unificada (shared CPU/GPU/NPU, ~97 GB/s medida) |
| Storage | Samsung NVMe PM9C1b 1 TB |
| OS | Ubuntu 24.04 LTS, kernel 6.19.10 |

### Por qué IPEX-LLM en lugar de Ollama estándar

**Ollama estándar NO soporta Intel Arc GPU en Linux.** Sin configuración adicional, Ollama detecta la ausencia de CUDA/ROCm y cae silenciosamente a CPU-only (~9 tok/s en Qwen3:8b Q4_K_M). IPEX-LLM es el fork oficial de Intel que parchea Ollama para usar el stack SYCL/Level Zero nativo de los GPU Xe, logrando ~18-20 tok/s en el mismo modelo — 2× el throughput de CPU-only.

La arquitectura resultante es:

```
VS Code (Twinny/CodeGPT) / Open WebUI / Apps externas
          │
          │ OpenAI-compatible REST (localhost:11434)
          ▼
   IPEX-LLM Ollama (Docker)
          │
          │ SYCL / Level Zero
          ▼
   Intel Arc 140V (Xe2)
   ──────────────────────
   LPDDR5X-8533 (32 GB shared)
```

---

## 2. Prerequisitos del sistema

### 2.1 Verificar que el GPU y NPU están activos

```bash
# Verificar driver xe activo para el iGPU
lspci -k | grep -A3 -i "VGA\|Display"
# Debe mostrar: Kernel driver in use: xe

# Verificar dispositivos DRI disponibles
ls -la /dev/dri/
# Esperado: card1, renderD128

# Verificar NPU (intel_vpu)
lspci -k | grep -A3 -i "NPU\|VPU"
# Kernel driver in use: intel_vpu
```

### 2.2 Grupos de usuario (obligatorio para /dev/dri passthrough)

```bash
# Añadir usuario a los grupos render y video
sudo usermod -aG render,video $USER

# Verificar membresía (requiere nueva sesión para surtir efecto)
groups $USER

# IMPORTANTE: cerrar sesión y volver a entrar para que los grupos se activen.
# Sin esto, el passthrough de /dev/dri al contenedor fallará silenciosamente.
```

### 2.3 Ubuntu 24.04 + Lunar Lake: nota sobre soporte de kernel

El kernel 6.19.10 incluye el driver `xe` completamente maduro para Lunar Lake. La parte del kernel está cubierta. Lo que necesitas instalar en el host son las librerías **userspace** de Level Zero que permiten que el contenedor Docker se comunique con el driver xe del kernel.

> ⚠️ Ubuntu 24.04 Noble NO incluye por defecto los paquetes de compute runtime actualizados para Lunar Lake/Xe2. El repositorio oficial de Intel (`repositories.intel.com`) **no es suficiente** para Xe2 — es necesario el PPA de Canonical (`ppa:ubuntu-oem/intel-graphics-preview`). Ver §4.

---

## 3. Instalación de Docker

```bash
# Eliminar instalaciones antiguas (docker.io del repo Ubuntu — no usar)
sudo apt remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

# Dependencias
sudo apt update
sudo apt install -y ca-certificates curl gnupg lsb-release

# Añadir GPG key oficial de Docker
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# Añadir repositorio Docker CE
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Instalar Docker CE
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Añadir usuario al grupo docker
sudo usermod -aG docker $USER

# Habilitar y arrancar Docker
sudo systemctl enable --now docker

# Verificar
docker run --rm hello-world
```

> **Nota:** Después de añadir el usuario a `docker`, `render` y `video`, necesitas cerrar sesión y volver a entrar (o ejecutar `newgrp docker` en el terminal actual para la sesión en curso).

---

## 4. Intel GPU Compute Runtime (Level Zero — host-side)

Este paso instala las librerías userspace de Level Zero en el **host** Ubuntu 24.04. El contenedor Docker de IPEX-LLM las necesita disponibles a través del passthrough de `/dev/dri`.

> **Método validado en Lunar Lake (Xe2):** el repositorio oficial de Intel (`repositories.intel.com`) no incluye paquetes actualizados para Xe2 en Ubuntu 24.04 Noble. El único método que funciona es el **PPA de Canonical Intel Graphics Preview**, mantenido en colaboración con Intel:
> [`https://github.com/canonical/intel-graphics-preview`](https://github.com/canonical/intel-graphics-preview)

```bash
# Paso 1: Añadir el PPA de Canonical Intel Graphics Preview
# Fuente: https://github.com/canonical/intel-graphics-preview
sudo add-apt-repository ppa:ubuntu-oem/intel-graphics-preview
sudo apt update

# Paso 2: Instalar compute runtime con soporte para Xe2 / Lunar Lake
sudo apt install -y \
  libze-intel-gpu1 \
  libze1 \
  intel-opencl-icd \
  intel-level-zero-gpu \
  level-zero \
  clinfo

# Paso 3: Verificar detección del GPU vía Level Zero
clinfo -l
# Esperado:
# Platform #0: Intel(R) OpenCL Graphics
#  -- Device #0: Intel(R) Arc(TM) 140V Graphics

ls /dev/dri/
# card1  renderD128
```

> **Por qué el PPA y no el repo de Intel:** el repositorio `repositories.intel.com/gpu/ubuntu noble` existe pero no contiene versiones compatibles con Xe2/Lunar Lake para Noble. El PPA `ubuntu-oem/intel-graphics-preview` es el canal oficial Intel+Canonical para hardware reciente en Ubuntu 24.04 LTS. No es production-grade según Canonical, pero es el camino validado para Xe2 hasta que el HWE stack lo absorba.

---

## 5. Backend principal: IPEX-LLM + Ollama (Docker)

### 5.1 Estructura de directorios

```bash
mkdir -p ~/.ollama/models
mkdir -p ~/llm/ipex-llm
cd ~/llm/ipex-llm
```

### 5.2 Docker Compose

Crea el fichero `~/llm/ipex-llm/docker-compose.yml`:

```yaml
# docker-compose.yml — IPEX-LLM Ollama en Intel Arc 140V (Lunar Lake)
# Ubuntu 24.04 · kernel 6.19 · driver xe

services:
  ipex-llm-ollama:
    image: intelanalytics/ipex-llm-inference-cpp-xpu:latest
    container_name: ipex-llm
    restart: unless-stopped

    # Passthrough completo del GPU Intel Arc
    devices:
      - /dev/dri:/dev/dri

    ports:
      - "11434:11434"

    volumes:
      # Persistencia de modelos en el host
      - ~/.ollama/models:/root/.ollama/models
      # Persistencia del caché SYCL compilado — evita recompilación de 2-5 min tras docker compose down/up
      # neo_compiler_cache: kernels del driver NEO (Level Zero/OpenCL)
      # libsycl_cache: programas compilados por el runtime SYCL
      - ~/.cache/ipex-llm/neo_compiler_cache:/root/.cache/neo_compiler_cache
      - ~/.cache/ipex-llm/libsycl_cache:/root/.cache/libsycl_cache

    environment:
      # Escuchar en todas las interfaces para que otras herramientas se conecten
      OLLAMA_HOST: "0.0.0.0"

      # Forzar todas las capas del modelo al GPU (sin split CPU/GPU)
      OLLAMA_NUM_GPU: "999"

      # Seleccionar el iGPU Arc 140V (level_zero:0 = primer dispositivo Level Zero)
      ONEAPI_DEVICE_SELECTOR: "level_zero:0"

      # Cache persistente de kernels SYCL compilados
      SYCL_CACHE_PERSISTENT: "1"

      # Permite que el runtime consulte métricas del GPU (uso, temperatura)
      ZES_ENABLE_SYSMAN: "1"

      # Optimización de rendimiento para Arc A-Series y Xe2 en Linux
      SYCL_PI_LEVEL_ZERO_USE_IMMEDIATE_COMMANDLISTS: "1"

      # Evitar que el contenedor use proxy para localhost
      no_proxy: "localhost,127.0.0.1"

      # Contexto por defecto: 8K para uso interactivo y coding (KV cache pequeño)
      # Sube a 16K-32K por petición via num_ctx en el payload JSON para RAG/long-context
      OLLAMA_NUM_CTX: "8192"

      # Flash attention: reduce el KV cache con kernels optimizados
      # Nota: IPEX-LLM usa su propio backend SYCL — variables como OLLAMA_KV_CACHE_TYPE
      # no tienen efecto (requieren el path llama.cpp GPU estándar, validado 2026-06-26)
      OLLAMA_FLASH_ATTENTION: "1"

      # Un solo modelo en VRAM a la vez (default Ollama: hasta 3)
      # CRÍTICO: sin esta variable, múltiples modelos compiten por VRAM y los más grandes
      # caen silenciosamente a CPU (ollama ps mostrará "100% CPU" en lugar de "100% GPU")
      OLLAMA_MAX_LOADED_MODELS: "1"

      # Single-user explícito: evita reservar buffers para peticiones paralelas
      OLLAMA_NUM_PARALLEL: "1"

      # Mantener modelo caliente 30 min tras el último prompt
      # Evita recarga de 30-60s entre prompts en sesiones de trabajo activas
      OLLAMA_KEEP_ALIVE: "30m"

      # Limitar arenas glibc: reduce fragmentación de heap en procesos long-running
      MALLOC_ARENA_MAX: "2"

    # Memoria compartida ampliada: necesaria para modelos grandes
    # Con 32 GB de RAM unificada, 16 GB de shm es razonable
    shm_size: "16g"

    # Límite de memoria del contenedor (OS + escritorio + apps: ~8-12 GB medidos en uso cotidiano)
    mem_limit: "18g"

    # Inicializar IPEX-LLM con el perfil Arc y arrancar Ollama
    command: >
      bash -c "
        cd /llm/scripts/ &&
        source ipex-llm-init --gpu --device Arc &&
        bash start-ollama.sh &&
        echo '========================================' &&
        echo 'IPEX-LLM listo. Recuerda aplicar los Modelfiles si has recreado el contenedor:' &&
        echo '  ./modelfiles/apply.sh' &&
        echo '========================================' &&
        tail -f /llm/ollama/ollama.log
      "

    # Health check: verificar que el API de Ollama responde
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:11434/api/tags"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s  # Dar tiempo a la compilación inicial de kernels SYCL
```

### 5.3 Arrancar el servicio

```bash
cd ~/llm/ipex-llm

# Primera vez: la imagen es grande (~10 GB), esperar la descarga
docker compose up -d

# Ver logs (importante para la primera ejecución)
docker compose logs -f

# Verificar que el API responde (esperar ~60s el primer arranque)
curl http://localhost:11434/api/tags
# Respuesta: {"models":[]}  ← correcto, aún sin modelos
```

> **Primera inferencia:** al cargar un modelo por primera vez, IPEX-LLM compila los kernels SYCL para el hardware específico (Arc 140V Xe2). Esto tarda **2–5 minutos** y es completamente normal. Las ejecuciones posteriores son casi instantáneas gracias a dos cachés persistidos en el host:
> - `~/.cache/ipex-llm/neo_compiler_cache` — kernels compilados por el driver NEO (Level Zero)
> - `~/.cache/ipex-llm/libsycl_cache` — programas compilados por el runtime SYCL
>
> Ambos sobreviven a `docker compose down/up`. Si el caché se corrompe, ver §10.

```bash
# Actualizar la imagen del contenedor IPEX-LLM (publicaciones periódicas con mejoras SYCL)
docker compose pull
docker compose up -d   # Recrea el contenedor solo si la imagen cambió
```

> ⚠️ **Gotcha: reboot no aplica cambios en docker-compose.yml.** La política `restart: unless-stopped` reinicia el contenedor existente con su configuración original — las variables de entorno se congelan en el momento de creación del contenedor. Un reboot del sistema reinicia el contenedor antiguo, ignorando cualquier edición posterior del compose.
>
> Tras modificar `docker-compose.yml`, siempre recrea el contenedor explícitamente:
> ```bash
> docker compose down && docker compose up -d
> # O equivalente:
> docker compose up -d --force-recreate
> ```
> Para verificar que las variables están activas tras el cambio:
> ```bash
> docker compose exec ipex-llm-ollama env | grep OLLAMA
> ```

### 5.4 Systemd service (autoarranque)

Si prefieres que el servicio arranque con el sistema sin pasar por `docker compose`:

```bash
# Crear el service unit
sudo tee /etc/systemd/system/ipex-llm-ollama.service > /dev/null <<'EOF'
[Unit]
Description=IPEX-LLM Ollama (Intel Arc 140V)
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=forking
RemainAfterExit=yes
WorkingDirectory=/home/YOUR_USER/llm/ipex-llm
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=120
Restart=on-failure
RestartSec=10s
User=YOUR_USER
Group=docker

[Install]
WantedBy=multi-user.target
EOF

# Reemplazar YOUR_USER con tu usuario
sudo sed -i "s/YOUR_USER/$USER/g" /etc/systemd/system/ipex-llm-ollama.service

# Habilitar
sudo systemctl daemon-reload
sudo systemctl enable --now ipex-llm-ollama.service

# Estado
sudo systemctl status ipex-llm-ollama.service
```

### 5.5 Tuning de SO para rendimiento

Dos ficheros de configuración que mejoran la estabilidad y el rendimiento de la inferencia, y del sistema en general. Independientes del contenedor — persisten a través de reboots.

#### sysctl (`/etc/sysctl.d/99-llm-performance.conf`)

```bash
sudo tee /etc/sysctl.d/99-llm-performance.conf > /dev/null <<'EOF'
# Memoria
vm.swappiness = 10               # Evitar swap con 30 GB de RAM disponibles
vm.dirty_background_ratio = 5    # Flush de escrituras al 5% (default 10%) — evita stalls
vm.dirty_ratio = 15
vm.vfs_cache_pressure = 50       # Retener caché de inodos/dentries — carga de modelos más rápida
vm.min_free_kbytes = 524288      # Reservar 512 MB libres — evita reclaim durante picos

# Red (API localhost:11434)
net.ipv4.tcp_fastopen = 3        # Reduce latencia en conexiones TCP localhost (cliente + servidor)
EOF

# Aplicar sin reboot
sudo sysctl -p /etc/sysctl.d/99-llm-performance.conf
```

#### CPU governor + HWP dynamic boost (`/etc/systemd/system/cpu-performance.service`)

Fija el governor a `performance` y activa el HWP dynamic boost del `intel_pstate`. En hardware con HWP activo (`intel_pstate/status = active`) el governor es el mecanismo de fallback cuando `power-profiles-daemon` no está corriendo; fijarlo explícitamente garantiza el comportamiento en cualquier configuración.

```bash
sudo tee /etc/systemd/system/cpu-performance.service > /dev/null <<'EOF'
[Unit]
Description=CPU performance governor and HWP dynamic boost
After=multi-user.target
Before=docker.service

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

> **`Before=docker.service`**: el governor debe estar activo antes de que IPEX-LLM empiece a compilar kernels SYCL. Si el governor está en `powersave` durante la compilación inicial, los kernels pueden optimizarse para frecuencias más bajas.

Verificación:

```bash
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor  # performance
cat /sys/devices/system/cpu/intel_pstate/hwp_dynamic_boost  # 1
cat /proc/sys/vm/swappiness                                 # 10
```

---

## 6. Modelos recomendados

### Presupuesto de memoria

- RAM total: 32 GB
- OS + escritorio + apps en uso: ~11–12 GB
- Disponible para modelos (medido): ~19–20 GB tras reboot limpio
- **Techo seguro en uso cotidiano: 16 GB de modelo en VRAM**

> Con 32 GB de RAM unificada **no es posible separar "VRAM del GPU" del resto de la RAM**. El Arc 140V accede a la misma piscina LPDDR5X que el CPU. Cargar un modelo de 14 GB deja sólo ~6 GB para el resto del sistema.
>
> **Impacto de `OLLAMA_FLASH_ATTENTION: "1"`:** reduce el footprint en RAM de cada modelo aproximadamente un 40% respecto al tamaño del fichero `.gguf`. Los valores de la columna RAM en las tablas siguientes reflejan la RAM real medida con flash attention activo, no el tamaño del fichero en disco.

> ⚠️ **Comportamiento del driver xe con memoria unificada:** una vez el driver xe asigna páginas de RAM al pool GPU (al cargar el primer modelo), no las devuelve al sistema aunque el modelo se descargue. La memoria solo se recupera completamente con un reboot. Esto es normal en iGPU con driver xe en Linux.

### 6.1 Caso de uso: Coding assistant

*Python/Django, Bash, Terraform, Kubernetes YAML, refactoring*

| Modelo | Quant | RAM disco | RAM runtime¹ | tok/s (GPU)² | Contexto | Notas |
|---|---|---|---|---|---|---|
| `qwen2.5-coder:14b` | Q4_K_M | 9.0 GB | **~6.5 GB** | **10.4** | 128K | **Recomendado principal.** Mejor calidad en refactoring multi-archivo y tool-use agentic (Cline). 16K contexto vía Modelfile. |
| `phi4-mini` | Q4_K_M | 2.5 GB | **~1.5 GB** | **~25** | 128K | Autocompletado FIM (Twinny). Muy rápido y ligero; no reemplaza al 14b en tareas complejas. |

¹ RAM runtime medida con `OLLAMA_FLASH_ATTENTION: "1"` activo (reduce ~40% vs tamaño en disco).
² Medido en Arc 140V con la configuración optimizada de este documento (CTX=16384 para coder:14b).

### 6.2 Caso de uso: Chat general y RAG

*Documentos Q&A, workflows con retrieval, long-context summarization*

| Modelo | Quant | RAM disco | RAM runtime¹ | tok/s (GPU)² | Contexto | Notas |
|---|---|---|---|---|---|---|
| `qwen3:8b` | Q4_K_M | 5.2 GB | **~3.6 GB** | **18.1** | 128K | **Recomendado (velocidad).** Modo "thinking" conmutable. Pasar `"think": false` en el payload para velocidad máxima sin razonamiento. |
| `gemma3:12b` | Q4_K_M | 8.1 GB | **~5.8 GB** | **10.5** | 128K | **Recomendado (RAG y summarization).** Multimodal (visión). Carga correctamente gracias a `OLLAMA_FLASH_ATTENTION`. |
| `llama3.1:8b-instruct-q4_K_M` | Q4_K_M | 4.9 GB | ~3.7 GB | 18.9 | 128K | General rápido. Alternativa a qwen3:8b sin modo thinking. |
| `mistral-7b-instruct-v0.3` (OpenVINO IR) | INT4 | 4.0 GB | — | ~8–10 (NPU) | 32K | Vía NPU. Para inferencia de bajo consumo. Verificar compatibilidad con versión vigente de OpenVINO. |

¹ RAM runtime medida con `OLLAMA_FLASH_ATTENTION: "1"` activo.
² Medido en Arc 140V, CTX=8192, prompt fijo de 20 tokens.

### 6.3 Caso de uso: Análisis de documentos

*Extracción de facturas PDF, comparación de líneas entre proveedores/periodos, output estructurado JSON*

| Modelo | Quant | RAM disco | RAM runtime¹ | tok/s (GPU)² | Contexto | Notas |
|---|---|---|---|---|---|---|
| `gemma3:12b` | Q4_K_M | 8.1 GB | ~5.8 GB | ~10.5 | 128K | **Primera opción (visión).** Lee facturas renderizadas como imagen, eliminando errores de OCR en tablas numéricas. |
| `qwen3:8b` | Q4_K_M | 5.2 GB | ~3.6 GB | ~18.1 | 128K | **Primera opción (texto puro).** Excelente JSON structured output. Pasar `"think": false` para respuestas directas sin razonamiento. |
| ~~`llama3.1:8b-instruct-q8_0`~~ | Q8_0 | 8.5 GB | — | — | 128K | **Retirado.** La afirmación anterior ("mejor precisión numérica que el 14B Q4") era incorrecta: más parámetros pesa más que más bits. |

¹ RAM runtime medida con `OLLAMA_FLASH_ATTENTION: "1"` activo.
² Medido en Arc 140V, CTX=8192.

> **Tip structured output:** usa el parámetro `format` de la API Ollama (grammar-constrained decoding) para garantizar JSON válido con cualquier modelo:
> ```bash
> curl http://localhost:11434/api/generate \
>   -d '{"model":"qwen3:8b","prompt":"Extrae vendor, fecha y line-items de esta factura: ...","think":false,"format":"json","stream":false}'
> ```

### 6.4 Combinaciones simultáneas dentro del presupuesto de memoria

> Con `OLLAMA_MAX_LOADED_MODELS: "1"` (config recomendada), Ollama solo mantiene un modelo en VRAM simultáneamente — el modelo anterior se descarga antes de cargar el siguiente. Las combinaciones de la tabla ya no son el escenario habitual, sino el consumo máximo si decides subir `OLLAMA_MAX_LOADED_MODELS`.
>
> Las cifras de RAM son **runtime con flash attention activo** (no tamaño en disco). El KV cache añade RAM proporcional al contexto activo: con `OLLAMA_NUM_CTX: "8192"` el impacto es menor; a 32K de contexto un modelo 14B puede añadir 1–2 GB adicionales.

| Escenario | Modelos | RAM runtime (flash att.) | Estado |
|---|---|---|---|
| Coding (modelo único) | `qwen2.5-coder:14b` | ~6.5 GB | ✅ Muy holgado |
| Chat/RAG rápido | `qwen3:8b` | ~3.6 GB | ✅ Muy holgado |
| Chat/RAG + visión | `gemma3:12b` | ~5.8 GB | ✅ Holgado |
| Autocomplete FIM | `phi4-mini` | ~1.5 GB | ✅ Mínimo |
| Coding + Chat (MAX_LOADED=2) | `qwen2.5-coder:14b` + `qwen3:8b` | ~10.1 GB | ✅ OK |
| Coding + RAG visión (MAX_LOADED=2) | `qwen2.5-coder:14b` + `gemma3:12b` | ~12.3 GB | ✅ OK |

---

## 7. Gestión de modelos

### 7.1 Pull de modelos

```bash
# NOTA: el binario ollama está en ollama/ollama dentro del contenedor (no en PATH estándar)

# Stack activo (2026-06-26)
docker exec ipex-llm ollama/ollama pull qwen2.5-coder:14b            # Coding principal (Cline)
docker exec ipex-llm ollama/ollama pull qwen3:8b                     # RAG/chat rápido, reasoning
docker exec ipex-llm ollama/ollama pull gemma3:12b                   # RAG, summarization, visión/facturas
docker exec ipex-llm ollama/ollama pull llama3.1:8b-instruct-q4_K_M  # General rápido
docker exec ipex-llm ollama/ollama pull phi4-mini                    # Autocompletado FIM (Twinny)

# También puedes usar el CLI de Ollama si lo instalas en el host (opcional)
# curl -fsSL https://ollama.com/install.sh | sh
# OLLAMA_HOST=http://localhost:11434 ollama pull <modelo>
```

> Los modelos se guardan en `~/.ollama/models` del host gracias al bind mount, por lo que sobreviven a reinicios y recreaciones del contenedor.

### 7.2 Test de inferencia y benchmarking

```bash
# Test básico de respuesta (coding)
curl -s http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen2.5-coder:14b",
    "prompt": "Write a Python function to parse a PDF invoice using Docling and return structured JSON with vendor, date, line_items, and total_amount.",
    "stream": false
  }' | python3 -m json.tool | grep -E '"response"|"eval_count"|"eval_duration"'

# Calcular tokens/segundo (eval_count / eval_duration en nanosegundos)
# tok/s = eval_count / (eval_duration / 1_000_000_000)

# Test completo con streaming (más representativo de uso real)
curl -s http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen2.5-coder:14b",
    "prompt": "Explain Kubernetes readiness probes vs liveness probes",
    "stream": true
  }'

# Listar modelos cargados y su uso de memoria — columna PROCESSOR debe mostrar "100% GPU"
docker exec ipex-llm ollama/ollama ps

# Listar todos los modelos disponibles
docker exec ipex-llm ollama/ollama list
```

#### Benchmark completo multi-modelo

El proyecto incluye `benchmark.sh` para medir rendimiento reproducible:

```bash
cd ~/llm/ipex-llm

# Benchmark de un modelo (3 runs, el 1º incluye carga)
./benchmark.sh qwen2.5-coder:14b 16384 | tee benchmark-result.txt

# Con contexto mayor (para evaluar KV cache a largo plazo)
./benchmark.sh gemma3:12b 16384

# Nota para modelos con thinking (qwen3): el script pasa think:false por defecto
# para medir inferencia pura comparable entre modelos
```

**Resultados medidos en Arc 140V — configuración optimizada (2026-06-26):**

| Modelo | Gen tok/s | Prefill tok/s | TTFT ms | RAM runtime |
|---|---|---|---|---|
| phi4-mini | **~25** | — | — | ~1.5 GB |
| llama3.1:8b-instruct-q4_K_M | 18.9 | 429 | 56 ms | 3.7 GB |
| qwen3:8b (think=false) | 18.1 | 522 | 62 ms | 3.6 GB |
| gemma3:12b | 10.5 | 240 | 100 ms | 5.8 GB |
| qwen2.5-coder:14b | **10.4** | **692** | 134 ms | ~6.5 GB |

> **Cuello de botella:** el Arc 140V (~68 GB/s ancho de banda) genera tokens a velocidad inversamente proporcional al tamaño del modelo — la generación por token requiere leer todos los pesos desde RAM. El prefill (procesado del prompt) es mucho más rápido porque paraleliza la atención. Los modelos 14B con GQA (qwen2.5) superan al 12B (gemma3) en prefill por su arquitectura más eficiente.
>
> **Referencia baseline:** el impacto más crítico de la config optimizada fue en los modelos 14B: sin `OLLAMA_MAX_LOADED_MODELS: "1"` caían a CPU (6.7 tok/s); con él, GPU (~10.7 tok/s, +60%). El qwen2.5-coder:14b tiene mayor prefill (692 vs 451 tok/s del general 14B) por haber sido fine-tuned sobre prompts de código con secuencias más largas.

### 7.3 Monitorización del GPU durante inferencia

> **Nota:** `intel_gpu_top` **no funciona** con el driver `xe` (Lunar Lake/Xe2). Internamente
> usa el subsistema PMU de `i915`, que el driver `xe` no expone. Ejecutarlo produce:
> `"Failed to detect engines! (No such file or directory)"`.
> Usar `xpu-smi` en su lugar (basado en Level Zero, ya instalado).

```bash
# --- Opción recomendada: xpu-smi (Level Zero, detecta Arc 140V correctamente) ---

# Snapshot puntual: memoria, frecuencia, utilización
xpu-smi stats -d 0

# Monitorización continua: memoria usada (MiB) + utilización (%) + frecuencia (MHz)
# -m 0=GPU_UTIL, 5=MEM_UTIL, 18=MEM_USED  |  -i intervalo en segundos
sudo xpu-smi dump -d 0 -m 0,5,18 -i 1

# Sin sudo (sin utilización de engines, el resto funciona):
xpu-smi dump -d 0 -m 5,18 -i 1

# --- Opción ligera: sysfs del driver xe (sin herramientas extra) ---

# Frecuencia activa real vs. frecuencia solicitada (divergencia = throttling)
watch -n1 'echo "Act: $(cat /sys/class/drm/card1/device/tile0/gt0/freq0/act_freq) MHz" && \
           echo "Cur: $(cat /sys/class/drm/card1/device/tile0/gt0/freq0/cur_freq) MHz"'

# --- Actividad del contenedor y presión de memoria del sistema ---
docker stats ipex-llm

# Memoria RAM del sistema (útil: Arc 140V usa memoria unificada — VRAM comparte RAM)
watch -n1 'grep -E "MemFree|MemAvailable|MemTotal" /proc/meminfo'
```

**Combinación práctica durante inferencia** (dos terminales):
```bash
# Terminal 1 — actividad GPU
sudo xpu-smi dump -d 0 -m 0,5,18 -i 1

# Terminal 2 — carga del contenedor
docker stats ipex-llm
```

### 7.4 Modelfiles — configuración por modelo

Los Modelfiles permiten fijar parámetros por defecto (temperatura, contexto, system prompt) para cada modelo sin tocar el `docker-compose.yml`. No re-descargan pesos — crean un nuevo manifiesto sobre los blobs existentes.

Los Modelfiles del proyecto están en `~/llm/ipex-llm/modelfiles/`:

| Fichero | Modelo | temp | num_ctx | Cambio clave |
|---|---|---|---|---|
| `qwen2.5-coder-14b.Modelfile` | qwen2.5-coder:14b | 0.1 | **16384** | Baja temperatura + contexto 16K para Cline |
| `qwen3-8b.Modelfile` | qwen3:8b | 0.6 | **16384** | Doble contexto; temperatura recomendada por Qwen |
| `gemma3-12b.Modelfile` | gemma3:12b | 0.4 | **16384** | Doble contexto para documentos largos y visión |
| `llama3.1-8b.Modelfile` | llama3.1:8b-instruct-q4_K_M | 0.7 | 8192 | Ajuste mínimo, uso general |
| `phi4-mini.Modelfile` | phi4-mini | 0.4 | 4096 | Contexto reducido para FIM rápido (Twinny) |

```bash
# Aplicar todos los Modelfiles (re-ejecutar tras modificar cualquier fichero)
cd ~/llm/ipex-llm
./modelfiles/apply.sh
```

> ⚠️ **Gotcha IPEX-LLM:** `ollama create` en IPEX-LLM no soporta leer el Modelfile desde stdin (`-f -`). El script usa `docker cp` + ruta de fichero, que sí funciona. No cambiar este mecanismo.

> ⚠️ **Gotcha `PARAMETER think`:** `PARAMETER think false` en un Modelfile falla con `Error: unknown parameter 'think'` en IPEX-LLM. Para desactivar el modo razonamiento de qwen3, pasar `"think": false` directamente en el payload de la API:
> ```bash
> curl -s http://localhost:11434/api/generate \
>   -d '{"model":"qwen3:8b","prompt":"...","think":false,"stream":false}'
> ```
> En Open WebUI: configurar en los ajustes avanzados del modelo. En benchmark.sh: ya incluido por defecto.

Para modificar un Modelfile:
```bash
# 1. Editar el fichero
nano ~/llm/ipex-llm/modelfiles/qwen3-8b.Modelfile

# 2. Re-aplicar solo ese modelo
docker cp ~/llm/ipex-llm/modelfiles/qwen3-8b.Modelfile ipex-llm:/tmp/current.Modelfile
docker exec ipex-llm ollama/ollama create qwen3:8b -f /tmp/current.Modelfile

# O re-aplicar todos:
./modelfiles/apply.sh
```

---

## 8. Integración con herramientas externas

### 8.1 Integración con VS Code (extensiones de asistente de código)

El endpoint es compatible con cualquier extensión que soporte la API de Ollama o OpenAI-compatible.
Datos de conexión comunes a todas ellas:

| Parámetro | Valor |
|-----------|-------|
| Endpoint Ollama | `http://localhost:11434` |
| Endpoint OpenAI-compatible | `http://localhost:11434/v1` |
| API Key (OpenAI-compat.) | `ollama` (valor ignorado, pero requerido) |
| Modelos disponibles | `curl http://localhost:11434/api/tags` |

**Modelos recomendados por caso de uso:**

| Uso | Modelo | Notas |
|-----|--------|-------|
| Chat / razonamiento | `qwen3:8b` | Recomendado. Modo thinking conmutable (`"think":false` para velocidad). |
| Chat / RAG / visión | `gemma3:12b` | Alternativa con capacidad multimodal. |
| Coding agentic (Cline/Roo Code) | `qwen2.5-coder:14b` | Principal. 16K contexto, temperatura 0.1. |
| Autocompletado FIM (Twinny) | `phi4-mini` | Rápido (~25 tok/s), mínimo consumo RAM. |

> **Nota:** Continue.dev fue discontinuado tras su integración con Cursor. Extensiones
> alternativas activas con soporte Ollama: ver tabla de recomendaciones más abajo.

#### Extensiones recomendadas

| Extensión | ID en Marketplace | Protocolo | Mejor para |
|-----------|-------------------|-----------|------------|
| **Twinny** | `rjmacarthy.twinny` | Ollama nativo | Autocompletado FIM + chat ligero |
| **Cline** | `saoudrizwan.claude-dev` | OpenAI-compat. | Agente: edita ficheros, ejecuta comandos |
| **Roo Code** | `RooVeterinaryInc.roo-cline` | OpenAI-compat. | Fork de Cline con modos de rol adicionales |
| **CodeGPT** | `DanielSanMedium.vscode-codegpt` | Ollama nativo | Chat simple sin setup complejo |

---

##### Twinny — autocompletado inline + chat

Extensión ligera con soporte nativo Ollama. Ideal para autocompletado FIM (completa mientras
escribes) y un panel de chat lateral.

Configuración (`Preferences → Settings → Twinny`):

| Ajuste | Valor |
|--------|-------|
| Ollama API hostname | `localhost` |
| Ollama API port | `11434` |
| Fill-in-middle model | `phi4-mini` |
| Chat model | `qwen3:8b` |
| API provider | `ollama` |

Atajos por defecto: `Alt+\` activa/desactiva autocompletado; `Ctrl+Shift+T` abre el chat.

---

##### Cline / Roo Code — agente de codificación

Agente que puede leer y editar ficheros, ejecutar comandos en terminal y llamar a herramientas MCP.
Requiere más tokens por operación que Twinny — usar modelos con contexto largo.

Configuración (`Cline: Open Settings`):

| Ajuste | Valor |
|--------|-------|
| API Provider | `OpenAI Compatible` |
| Base URL | `http://localhost:11434/v1` |
| API Key | `ollama` |
| Model | `qwen2.5-coder:14b` |

> **Gotcha memoria GPU**: tareas agénticas largas pueden agotar la RAM disponible. Si el
> contenedor cae con OOM, reducir el contexto del Modelfile (`num_ctx 8192` en lugar de 16384)
> o bajar `OLLAMA_NUM_CTX` en `docker-compose.yml`.

Roo Code (`RooVeterinaryInc.roo-cline`) usa la misma configuración y añade modos de rol
predefinidos (Architect, Code, Debug). Recomendado frente a Cline si se quiere un flujo
más estructurado.

---

##### CodeGPT — chat simple

Opción con menor fricción de configuración. No tiene autocompletado FIM — solo chat lateral.

Configuración (`CodeGPT: Set API Key`):

| Ajuste | Valor |
|--------|-------|
| LLM Provider | `Ollama` |
| Model | `qwen3:8b` |
| API URL | `http://localhost:11434` |

### 8.2 Open WebUI (UI de chat local)

Open WebUI tiene su propio fichero compose independiente — ciclo de vida separado del stack
de inferencia, para poder reiniciarla sin interrumpir el LLM.

```bash
# Arrancar Open WebUI (requiere el stack principal corriendo)
docker compose -f docker-compose.open-webui.yml up -d

# Ver logs
docker compose -f docker-compose.open-webui.yml logs -f

# Parar (no afecta al contenedor ipex-llm)
docker compose -f docker-compose.open-webui.yml down

# Actualizar imagen
docker compose -f docker-compose.open-webui.yml pull && \
  docker compose -f docker-compose.open-webui.yml up -d
```

Accesible en `http://localhost:3000`.

> **Nota**: `WEBUI_AUTH=false` desactiva el login — adecuado para uso local en máquina
> personal. Si expones el puerto en red, activa la autenticación eliminando esa variable.

### 8.3 API compatible con OpenAI (para scripts Python)

El endpoint de Ollama es compatible con la spec de OpenAI. Úsalo directamente con el cliente de `openai`:

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:11434/v1",
    api_key="ollama",  # Valor requerido pero ignorado por Ollama
)

response = client.chat.completions.create(
    model="qwen3:8b",
    messages=[
        {"role": "system", "content": "You are a document analysis assistant. Respond only with valid JSON."},
        {"role": "user", "content": "Extract vendor, date, and line items from the following invoice text: ..."},
    ],
    temperature=0.1,  # Bajo para extracción estructurada
)
print(response.choices[0].message.content)
```

---

## 9. Backend secundario: OpenVINO GenAI (NPU)

### 9.1 Cuándo usar el NPU (y cuándo NO)

| Escenario | NPU | iGPU (IPEX-LLM) |
|---|---|---|
| Inferencia interactiva (~20 tok/s) | ❌ Más lento que CPU | ✅ **Usa esto** |
| Background tasks de muy baja potencia | ✅ Más eficiente energéticamente | ❌ Consume más |
| Modelos <3B parámetros | ⚠️ OK (limitado) | ✅ También funciona |
| Contextos >8K tokens | ❌ Limitado por MAX_PROMPT_LEN | ✅ Sin restricción |
| Primer load (compilación de grafo estático) | ❌ 60–90 segundos | ✅ Más rápido |

**Conclusión:** para RAG, facturas (prompts largos) e inferencia interactiva, usa siempre el iGPU vía IPEX-LLM. El soporte NPU mejora con cada versión de OpenVINO — reevalúa para modelos 1B–3B si la autonomía de batería es prioritaria, pero no para el pipeline principal.

### 9.2 Setup OpenVINO GenAI (si decides experimentar con el NPU)

```bash
# Instalar en entorno virtual aislado — evitar contaminar el sistema
python3 -m venv ~/.venvs/openvino-genai
source ~/.venvs/openvino-genai/bin/activate

# Instalar OpenVINO GenAI y dependencias
pip install --pre openvino openvino-tokenizers openvino-genai \
  --extra-index-url https://storage.openvinotoolkit.org/simple/wheels/nightly

pip install optimum-intel[openvino]

# Exportar un modelo a formato OpenVINO IR con quantización NPU-compatible
# IMPORTANTE: los flags --sym --ratio 1.0 --group-size 128 son OBLIGATORIOS para NPU
# La exportación estándar sin estos flags NO funciona en NPU
optimum-cli export openvino \
  --model microsoft/Phi-3.5-mini-instruct \
  --sym \
  --ratio 1.0 \
  --group-size 128 \
  ./phi-3.5-mini-npu
```

```python
# Inferencia en NPU con OpenVINO GenAI
import openvino_genai as ov_genai

# MAX_PROMPT_LEN y MIN_RESPONSE_LEN son OBLIGATORIOS para NPU
# El NPU requiere formas estáticas — estos valores son el límite hard
config = {
    "MAX_PROMPT_LEN": 1024,
    "MIN_RESPONSE_LEN": 256,
    "GENERATE_HINT": "BEST_PERF",  # Mejor rendimiento (compilación más lenta la primera vez)
}

# Primera carga: ~60–90 segundos para compilar el grafo estático
print("Compilando grafo NPU (primera vez ~90s)...")
pipe = ov_genai.LLMPipeline("./phi-3.5-mini-npu", "NPU", config)
print("NPU listo.")

result = pipe.generate(
    "Analyze this invoice and extract the vendor name and total amount:",
    max_new_tokens=256,
)
print(result)
```

### 9.3 Modelos OpenVINO pre-optimizados para NPU de Lunar Lake

Intel mantiene una colección en HuggingFace con modelos ya convertidos y cuantizados:

```bash
# Modelos validados para NPU en Lunar Lake (Core Ultra 200V):
# - OpenVINO/Qwen3-8B-int4-cw-ov
# - OpenVINO/Phi-3.5-mini-instruct-int4-ov
# - OpenVINO/mistral-7b-instruct-v0.3-int4-ov (verificar compatibilidad con versión vigente de OpenVINO)

# Descargar modelo pre-convertido
pip install huggingface-hub
huggingface-cli download OpenVINO/Phi-3.5-mini-instruct-int4-ov \
  --local-dir ./phi-3.5-mini-npu
```

---

## 10. Troubleshooting

### El contenedor arranca pero Ollama va en CPU

```bash
# Verificar que el GPU está siendo detectado por Level Zero dentro del contenedor
docker exec ipex-llm bash -c "source /llm/scripts/ipex-llm-init --gpu --device Arc && clinfo -l"
# Si no muestra "Intel Arc" → problema de Level Zero en el host (ver sección 4)

# Verificar que los grupos render/video están activos en el host
groups $USER
# Debe incluir: render video docker

# Si los grupos no están activos después de añadirlos:
newgrp render  # Activar en la sesión actual sin cerrar sesión
```

### Error "The program was built for 1 devices"

```bash
# Causado por caché SYCL corrupta — limpiar desde el host (los directorios están montados)
rm -rf ~/.cache/ipex-llm/neo_compiler_cache/* ~/.cache/ipex-llm/libsycl_cache/*
docker restart ipex-llm
# La próxima inferencia recompilará los kernels (2-5 min) y regenerará el caché limpio
```

### OOM / el modelo no carga (Out of Memory)

```bash
# Verificar memoria disponible antes de cargar un modelo
free -h
# Si disponible < tamaño del modelo → liberar memoria

# Ver qué modelos están cargados en Ollama (consumen RAM aunque no estén en uso)
docker exec ipex-llm ollama/ollama ps

# Descargar modelos de memoria sin eliminarlos del disco
# (Ollama los descarga automáticamente tras OLLAMA_KEEP_ALIVE, por defecto 5m)
docker exec ipex-llm ollama/ollama stop qwen2.5-coder:14b
```

### Modelo ejecutándose en CPU en lugar de GPU (caída silenciosa)

El síntoma más engañoso: el modelo responde pero a 5–7 tok/s en lugar de ~19 tok/s. La inferencia cae a CPU silenciosamente cuando la GPU se queda sin VRAM.

```bash
# Diagnosticar: columna PROCESSOR debe mostrar "100% GPU", no "100% CPU"
docker compose exec ipex-llm-ollama ollama/ollama ps
# Si muestra "100% CPU" → el modelo está en CPU

# Causa más común: varios modelos en VRAM simultáneamente
# Con la config por defecto (OLLAMA_MAX_LOADED_MODELS sin definir, default = 3),
# los modelos anteriores permanecen en VRAM y el nuevo no cabe → cae a CPU

# Solución: descargar el modelo anterior antes de cargar el nuevo
curl -X POST http://localhost:11434/api/generate \
  -d '{"model": "<modelo-anterior>", "keep_alive": 0}'

# Prevención permanente: añadir al docker-compose.yml y recrear el contenedor
# OLLAMA_MAX_LOADED_MODELS: "1"
# Luego: docker compose up -d --force-recreate
```

### Cambios en docker-compose.yml no tienen efecto tras reboot

```bash
# Verificar qué variables tiene el contenedor activo
docker compose exec ipex-llm-ollama env | grep OLLAMA

# Si faltan variables que están en el compose → el contenedor es anterior a los cambios
# Causa: restart: unless-stopped reinicia el contenedor existente, no lee el compose

# Solución: recrear el contenedor explícitamente
docker compose down && docker compose up -d
# O: docker compose up -d --force-recreate
```

### Memoria RAM no se recupera tras descargar un modelo

Cuando Ollama descarga un modelo (`ollama stop` / `keep_alive: 0`), libera los pesos desde su perspectiva, pero el driver xe retiene las páginas en el pool GPU. Bajar el contenedor por completo cierra el contexto Level Zero y libera el pool; el kernel además puede retener esas páginas en el page cache hasta que se limpie explícitamente.

```bash
# Verificar uso GPU antes de liberar
xpu-smi dump -d 0 -m 5 -i 1 -n 1

# Liberar memoria sin reboot (validado 2026-06-26: de 7.6 GB disponibles → 18 GB)
docker compose down                                    # cierra contexto Level Zero
sudo sync && sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'  # libera page cache
sudo swapoff -a && sudo swapon -a                      # devuelve swap a RAM

# Verificar resultado
free -h   # MemAvailable debe haber subido significativamente
```

> **`docker compose restart` no es suficiente** — reinicia el proceso sin destruir el contexto Level Zero, el pool GPU permanece.
> **`docker compose down` + drop_caches sí funciona** — el reboot sigue siendo la opción más limpia pero no es necesario.
>
> Nota operativa: en una sesión de trabajo, usa `OLLAMA_MAX_LOADED_MODELS: "1"` para que Ollama haga el swap de modelos dentro del pool sin necesidad de liberarlo entre consultas.

### Primera inferencia tarda 2–5 minutos

Comportamiento normal. IPEX-LLM compila los kernels SYCL para el Arc 140V Xe2 en el primer uso de cada modelo. Los logs del contenedor mostrarán actividad de compilación. Una vez completada, el caché persiste en `~/.ollama/models` del host.

### Verificar que la inferencia usa GPU y no CPU

```bash
# Durante una inferencia activa, en otra terminal:
# intel_gpu_top NO funciona con el driver xe (Xe2/Lunar Lake) — usar xpu-smi:
sudo xpu-smi dump -d 0 -m 0,5,18 -i 1
# Columnas: GPU util (%), memoria usada (MB), frecuencia (MHz)
# Debes ver GPU util > 80% durante la inferencia
# Si GPU util ~0% → la inferencia está yendo por CPU
```

### Contenedor no puede acceder a /dev/dri

```bash
# Verificar permisos del dispositivo en el host
ls -la /dev/dri/
# crw-rw---- 1 root render 226,   0 ...  card1
# crw-rw---- 1 root render 226, 128 ...  renderD128

# El usuario debe estar en el grupo render (verificar después de cerrar/abrir sesión)
id $USER | grep render

# Alternativa temporal para testing sin cerrar sesión:
docker run --rm \
  --device=/dev/dri \
  --group-add=$(getent group render | cut -d: -f3) \
  intelanalytics/ipex-llm-inference-cpp-xpu:latest \
  bash -c "source /llm/scripts/ipex-llm-init --gpu --device Arc && clinfo -l"
```

---

## Quick Reference

```bash
# Arrancar servicio
cd ~/llm/ipex-llm && docker compose up -d

# Parar servicio
cd ~/llm/ipex-llm && docker compose down

# Logs en tiempo real
docker compose logs -f ipex-llm

# Pull de modelo nuevo (binario en ollama/ollama, no en PATH)
docker exec ipex-llm ollama/ollama pull <modelo>

# Re-aplicar Modelfiles (tras editar alguno o recrear el contenedor)
cd ~/llm/ipex-llm && ./modelfiles/apply.sh

# Test rápido de inferencia
curl -s http://localhost:11434/api/generate \
  -d '{"model":"qwen2.5-coder:14b","prompt":"Hello","stream":false}' | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"{d['eval_count']/(d['eval_duration']/1e9):.1f} tok/s\")"

# Ver modelos cargados en memoria
docker exec ipex-llm ollama/ollama ps

# Ver todos los modelos descargados
docker exec ipex-llm ollama/ollama list

# Estado del servicio systemd
sudo systemctl status ipex-llm-ollama.service
```
