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
├── quality-test.sh      # 5-prompt quality battery — save/diff baselines per model, regression + candidate comparison
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

Validated (§1-11 ✅ in the full guide): build, GPU inference, benchmarking, Flash Attention,
speculative decoding (found not viable on this hardware), model lineup, and VS Code client
integration. Systemd autostart was considered and dropped — `start-server.sh` already covers
starting the server, and every use case so far switches between models interactively.

**Settled as the production backend (2026-07-22)** — the OVMS evaluation (`../ovms-arc/`)
closed without a switch: OVMS won every raw performance metric tested, but `Ornith-1.0-9B`
and `Gemma-4-12B` (this stack's production models) have no OVMS conversion, and Hermes
Agent's own ≥64K-context requirement ruled out every OVMS-covered alternative that could
otherwise stand in. Full rationale: `../ovms-arc/CLAUDE.md` Status section.

**Development still paused (since 2026-07-21) — waiting on upstream**, independent of the
above: no further spikes/features planned here until upstream llama.cpp ships something
worth re-testing (see `TODO.md` for the specific reopen conditions already tracked per item:
SYCL cache-crash fix, Xe2 Flash Attention kernels). Day-to-day use (Hermes Agent, VS Code
clients) is unaffected either way.

## Development notes

- oneAPI compiler packages use `apt.repos.intel.com/oneapi` — different from the GPU driver repo (`repositories.intel.com/gpu`) which does not work with Xe2
- `sycl-ls` is the first diagnostic: if it does not show the Arc 140V, the problem is the Level Zero runtime, not the compiler
- ⚠️ Never run two model-loading processes at once (e.g. `llama-server` left running while also starting `benchmark.sh`/`start-server.sh`/`llama-bench` on another model) — confirmed to hang the `xe` driver and require a hard reboot, not just OOM. Stop the resident process and confirm `free -h` shows recovered memory before loading another model. Detail: guide §7 "Memory budget"
