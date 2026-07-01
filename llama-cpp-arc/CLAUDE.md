# llama-cpp-arc — llama.cpp native SYCL (Intel Arc 140V)

Successor to `../ipex-llm/`. Hardware and ecosystem context in `../CLAUDE.md`.
Full installation guide: `local-llm-yoga-slim7-ubuntu2404-llamacpp.md`

## Project structure

```
llama-cpp-arc/
├── llama.cpp/          # cloned repository — build here
│   └── build/bin/      # binaries: llama-server, llama-bench, llama-cli
├── models/             # GGUFs downloaded from Hugging Face
├── start-server.sh     # interactive launcher (activates oneAPI + launches llama-server)
├── benchmark.sh         # interactive llama-bench runner across the model catalog
├── bench-spec.sh        # speculative-decoding benchmark via /completion
└── local-llm-yoga-slim7-ubuntu2404-llamacpp.md  # full installation guide
```

## Development commands

```bash
# Before any task: activate oneAPI environment
source /opt/intel/oneapi/setvars.sh

# Verify GPU
sycl-ls

# Build (after git pull in llama.cpp/ or flag change)
cmake --build llama.cpp/build --config Release -j$(nproc) \
  --target llama-server llama-bench llama-cli

# Start server (interactive menu if no argument)
./start-server.sh
./start-server.sh Qwen3-8B-Q4_K_M.gguf   # by filename
./start-server.sh Gemma                   # by name substring

# Benchmark (interactive menu, same catalog as start-server.sh)
./benchmark.sh
```

## Stack

- **Backend**: llama.cpp compiled with `GGML_SYCL=ON` + Intel compiler `icx/icpx` (oneAPI)
- **Server**: `llama-server` — OpenAI-compatible API at `localhost:8080`
- **No Docker** — native installation
- **Models**: GGUFs from Hugging Face — trusted quantizers (bartowski, unsloth, lmstudio-community,
  deepreinforce-ai) or original publishers (Google, Qwen team/Alibaba, DeepSeek)

## Status

Validated (§1-9, §11 ✅ in the full guide): build, GPU inference, benchmarking, Flash Attention,
speculative decoding (found not viable on this hardware), model lineup, and VS Code client
integration. Only §10 (systemd autostart) remains ⚠️ — the unit file is corrected but untested
against a real reboot.

## Development notes

- oneAPI compiler packages use `apt.repos.intel.com/oneapi` — different from the GPU driver repo (`repositories.intel.com/gpu`) which does not work with Xe2
- `sycl-ls` is the first diagnostic: if it does not show the Arc 140V, the problem is the Level Zero runtime, not the compiler
