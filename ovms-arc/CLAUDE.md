# ovms-arc — OpenVINO Model Server (Intel Arc 140V)

Candidate 3 of the inference-engine spike (after llama.cpp Vulkan and Ollama, both ruled
out). Hardware and ecosystem context in `../CLAUDE.md`.
Full guide: `local-llm-yoga-slim7-ubuntu2404-ovms.md`

## Project structure

```
ovms-arc/
├── ovms_ubuntu24_2026.2.1_python_on.tar.gz   # official release tarball (checksum-verified)
├── ovms/
│   ├── bin/ovms                # the server binary
│   ├── lib/                    # bundled shared libs + lib/python/ (pyovms module)
│   └── models/OpenVINO/<repo>/ # models pulled via --source_model, kept between sessions
├── start-server.sh             # interactive launcher — validated catalog, per-model flags, no separate download step
├── quality-test.sh             # 5-prompt quality battery, ported from ../llama-cpp-arc/ for OVMS's /v3/ API
├── quality-baselines/          # saved battery outputs per model, diff against ../llama-cpp-arc/quality-baselines/
├── context-test.sh             # long-context/multi-turn prefill probe — cold degradation curve + growing-session test
└── local-llm-yoga-slim7-ubuntu2404-ovms.md  # full install guide + benchmark tables, gotchas, verdicts
```

No systemd unit, no Docker — native binary, self-contained, isolated from `../llama-cpp-arc/`.

## Development commands

```bash
# Interactive launcher (menu, or by name/repo) — validated catalog, correct per-model flags
./start-server.sh
./start-server.sh Qwen3-8B
./start-server.sh OpenVINO/Qwen3-VL-8B-Instruct-int4-ov

# Manual equivalent, if you need flags not in start-server.sh's catalog
cd ovms-arc/ovms
export LD_LIBRARY_PATH="$(pwd)/lib:${LD_LIBRARY_PATH:-}"
export PYTHONPATH="$(pwd)/lib/python:${PYTHONPATH:-}"

./bin/ovms --source_model OpenVINO/<model>-int4-ov \
  --model_repository_path ./models --target_device GPU --task text_generation \
  --rest_port 9000
  # add --tool_parser hermes3 for Qwen3-family tool-calling (see reference.md for other
  # families); add --enable_prefix_caching false only when benchmarking, see Gotchas below

# Verify
curl http://127.0.0.1:9000/v3/models
```

Port `9000` is this project's convention — distinct from `llama-cpp-arc`'s `8080` and the
now-deleted `ollama-arc` spike's `11500`.

## Stack

- **Backend**: OpenVINO Model Server 2026.2.1, native binary (`ovms_ubuntu24_..._python_on.tar.gz`), no Docker
- **Server**: `ovms` — OpenAI-compatible API (`/v3/chat/completions`, `/v3/models`) on the configured `--rest_port`
- **GPU plugin**: reuses the system's existing `intel-opencl-icd` (installed for the `xe`/Level Zero stack) — no extra driver work needed
- **Models**: pre-converted OpenVINO IR from the official `OpenVINO` HF org (`*-int4-ov`) — no local `optimum-intel` conversion needed for the models that have one

## Status

**Closed (2026-07-22) — decision: stay on `llama-cpp-arc`, not because of performance.**
6/6 non-multimodal catalog models benchmarked for speed AND quality against the SYCL
baseline (no systematic quality winner — each engine has its own model-specific bugs);
vision validated via a non-Gemma4 model; long-context/multi-turn behavior tested with
`context-test.sh` and found to resolve SYCL's per-turn-slowdown pain point outright (even
OVMS's cold/no-caching worst case, 213.6 tok/s at 24.5K tokens, beats SYCL's best case, 177
tok/s at 2K tokens). **On every raw engine metric, OVMS won.** The decision to close this
spike without switching came from a different, later check: fitting OVMS to the actual
production client (Hermes Agent), not to a synthetic benchmark. Three disqualifying facts,
in the order they were found:

1. **No OVMS conversion exists for `Ornith-1.0-9B`** (current production default) or
   `Gemma-4-12B` (production vision/tool-calling model) — this was known from day one of
   the spike (see §"Model coverage" below) but wasn't treated as decision-ending until the
   Hermes-fit check ran.
2. **Hermes Agent hard-requires ≥64,000 tokens of context** on any model — a product-level
   check, not configurable around. `Qwen3-8B`/`Qwen3-14B` (40,960) and the Qwen2.5-Coder
   pair (32,768) all fail it regardless of backend.
3. Of the OVMS models that do clear 64K, tool-calling reliability ruled out the rest:
   `Qwen2.5-VL-7B-Instruct` has no matching `--tool_parser`; `DeepSeek-R1-Distill-Qwen-7B`,
   given a real tool schema, skipped the tool entirely and fabricated a plausible-looking
   fake result instead of calling it (confirmed via direct request, not assumed). Only
   `Qwen3-VL-8B-Instruct` clears both context and tool-calling — but it was only ever
   validated for the vision/tool-calling role, never as a general daily-driver model, so
   betting the whole production default on it was judged not worth it against an
   already-proven, already-in-production alternative (`Ornith-1.0-9B` + `Gemma-4-12B` on
   `llama-cpp-arc`).

**What carries forward:** the client/agent-tool question this raised (what should pair with
OVMS, or with a future backend, for lighter task profiles that don't need Hermes's full
feature set) moved to its own project —
[`llm-tooling-landscape`](https://github.com/jmsirvent/llm-tooling-landscape) — since it's
no longer specific to this machine or this backend.
Full results and verdicts: `local-llm-yoga-slim7-ubuntu2404-ovms.md`.

## Gotchas (found the hard way — not obvious from official docs)

- **`python_on` builds need `PYTHONPATH` set to `lib/python/`** or every launch fails with
  `ModuleNotFoundError: No module named 'pyovms'` and exits looking like a clean shutdown
  in the log (scroll up for the real `error` line). `LD_LIBRARY_PATH=./lib` is also
  required — the binary bundles its own `libopenvino_intel_gpu_plugin.so`, `libOpenCL.so`,
  etc., and won't find them otherwise.
- **`--enable_prefix_caching` defaults to `true`.** A second identical request returns
  near-instantly — that's a cache hit, not real throughput. Always pass
  `--enable_prefix_caching false` for benchmarking, or use a unique prompt per measurement.
- **`--source_model` regenerates `graph.pbtxt` on every launch**, silently overwriting any
  manual edit to that file. To serve from a pre-downloaded model without triggering a
  re-pull/regeneration, use `--model_path <dir>` instead (no `--source_model`).
- **VLM pipeline detection can't be overridden.** If the model directory contains
  vision-embedding files, OVMS forces `pipeline_type: VLM` — passing `--pipeline_type LM`
  (or editing it into `graph.pbtxt` by hand) fails with "Models directory content
  indicates VLM pipeline, but pipeline type is set to non-VLM type", every time.
- **Tool-calling requires the right `--tool_parser`, and not every model family has one.**
  Supported: `hermes3` (also covers Qwen3), `llama3`, `phi4`, `mistral`, `devstral`,
  `gptoss`, `qwen3coder`, `lfm2`, `gemma4`. **No parser exists for Qwen2.5** (base or VL) —
  the model generates a well-formed tool call as raw text, but OVMS can't extract it into
  `tool_calls` (stays `[]`). Confirmed via `docs/llm/reference.md` in the upstream repo.
- **The entire Gemma4 family is broken in this OVMS release for anything beyond a load
  check.** Two different failure modes hit (E2B: inference-time shape-mismatch crash on
  every request, with or without an image; E4B: load-time `SDPAToPagedAttention`
  failure, no workaround found) — tracked upstream in
  [model_server#4178](https://github.com/openvinotoolkit/model_server/issues/4178).
  Don't re-attempt Gemma-4-anything on OVMS until that issue closes.
- ⚠️ Same `xe` driver risk as `llama-cpp-arc`: never run two model-loading processes at
  once. Always verify with `pgrep -fa "bin/ovms"` / `ss -ltnp` before starting a new one —
  and kill by PID, never by `kill %N` job-control syntax (doesn't survive across separate
  shell invocations).
- 14B-class models push swap to 4.7-6.2 GiB during load; smaller models are fine. Run the
  full remediation (`sync; echo 3 > /proc/sys/vm/drop_caches; swapoff -a; swapon -a`)
  after stopping a large model, same as documented for `llama-cpp-arc`.
- **Swap pressure isn't just a 14B-class thing.** Sustained long-context traffic (many
  requests with large/growing KV-cache allocations, e.g. `context-test.sh`) pushed swap to
  7.9/8.0 GiB on an 8B model — the short-prompt load-and-benchmark cycle that produced the
  "smaller models are fine" finding above doesn't exercise this path. Check swap during any
  extended real session, not just at model load.
