# llama-cpp-arc — llama.cpp native SYCL (Intel Arc 140V)

Successor to `../ipex-llm/`. Hardware and ecosystem context in `../CLAUDE.md`.
Full installation guide: `local-llm-yoga-slim7-ubuntu2404-llamacpp.md`

## Project structure

```
llama-cpp-arc/
├── llama.cpp/          # cloned repository — build here
│   └── build/bin/      # binaries: llama-server, llama-bench, llama-cli
├── models/             # GGUFs downloaded from Hugging Face
├── start-server.sh     # startup script (activates oneAPI + launches llama-server)
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

# Start server
./start-server.sh                        # default model
./start-server.sh models/<name>.gguf    # specific model
```

## Stack

- **Backend**: llama.cpp compiled with `GGML_SYCL=ON` + Intel compiler `icx/icpx` (oneAPI)
- **Server**: `llama-server` — OpenAI-compatible API at `localhost:8080`
- **No Docker** — native installation
- **Models**: GGUFs from Hugging Face (bartowski, unsloth, lmstudio-community)

## Status

Project in bootstrap — compilation and validation pending.

## Development notes

- oneAPI compiler packages use `apt.repos.intel.com/oneapi` — different from the GPU driver repo (`repositories.intel.com/gpu`) which does not work with Xe2
- `sycl-ls` is the first diagnostic: if it does not show the Arc 140V, the problem is the Level Zero runtime, not the compiler
