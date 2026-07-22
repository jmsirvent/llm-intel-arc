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

**Spike complete — no remaining technical gap.** 6/6 non-multimodal catalog models
benchmarked for speed AND quality against the `llama-cpp-arc` SYCL baseline (no systematic
quality winner — each engine has its own model-specific bugs); vision validated via a
non-Gemma4 model after the whole Gemma-4 family turned out blocked by an upstream bug.
Long-context/multi-turn behavior (2026-07-22, `context-test.sh`): OVMS resolves the SYCL
pain point of per-turn slowdown in a growing agentic session (prefix caching absorbs the
repeated-history cost, marginal rate doesn't decay up to ~22K tokens); even OVMS's cold/
no-caching worst case (213.6 tok/s at 24.5K tokens) beats SYCL's best case (177 tok/s at
2K tokens). **No production decision made yet** — that's a separate call, not a technical
blocker anymore.
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
