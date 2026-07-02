# Design: `mcp-local-llm` — Local Models as MCP Tools for Claude Code

**Date:** 2026-07-02
**Status:** Approved (brainstorming session 2026-07-02)
**Location:** `~/llm/mcp-local-llm/` (new monorepo subproject)

## Problem

Claude Code cannot use a local model as its main model, but it can delegate
bounded subtasks to one. Today that delegation happens ad hoc (`curl` against
`localhost:8080/v1`, or the `agy` CLI). There is no discoverable, schema-typed
surface that tells Claude *when and how* to delegate, no first-class view of
which model is loaded, and no safe path to switch models.

## Goals

1. **Delegation** (primary): let Claude Code send bounded subtasks (summaries,
   code drafts, second opinions, privacy-sensitive content that must not leave
   the machine) to the local llama-server and receive the result as a tool result.
2. **Stack awareness/management** (secondary): status of the running server and
   human-confirmed model switching.
3. Keep the door open to **multi-client access** (Claude Desktop, others) without
   rewriting anything.

**Non-goals (for now):**
- Serving multiple models concurrently (hardware constraint: one active model,
  see `~/llm/CLAUDE.md`).
- HTTP transport / shared daemon (future point 2; see Migration below).
- Replacing Claude Code's main model.

## Architecture

```
Claude Code ──stdio──▶ mcp-local-llm (Python, FastMCP)
                          │
                          ├─ httpx ──▶ localhost:8080/v1   (inference: active model)
                          └─ subprocess ──▶ start-server.sh <gguf>   (switch_model only)
```

- **Stack:** system Python 3.12 + native venv (`.venv/`); dependencies `mcp`
  (official SDK, FastMCP) and `httpx`. No Docker (monorepo architecture decision).
- **Transport:** `stdio`. Claude Code spawns the process per session — no new
  ports, no daemons.
- **Registration:** user scope, so delegation is available from any project:
  `claude mcp add local-llm --scope user -- ~/llm/mcp-local-llm/.venv/bin/python ~/llm/mcp-local-llm/server.py`
- **No privileged operations.** The server talks to the existing `/v1` endpoint
  and, for switching, invokes the same `start-server.sh` the user runs manually,
  as the user's own account. No systemd, no sudo.
- Assumes the client-facing API convention already decided in `~/llm/CLAUDE.md`:
  port `8080`, OpenAI-compatible `/v1`, whichever backend is serving.

## Tool surface

| Tool | Purpose | Key parameters |
|---|---|---|
| `summarize` | Summarize/condense text or logs | `text`, `focus?` |
| `draft_code` | First draft of code or a script | `spec`, `language?` |
| `second_opinion` | Review/contrast a solution or reasoning | `question`, `context?` |
| `ask_local_model` | **Generic fallback** for anything that doesn't fit above | `prompt`, `system?`, `max_tokens?`, `temperature?` |
| `local_model_status` | Loaded model, server health, GGUF catalog on disk | — |
| `switch_model` | Change the served GGUF (2–5 min cost, non-blocking) | `model` |

Decisions:

- **Purpose tools do not pick a model** (single-active-model constraint). They
  use whatever is loaded, and **every response reports which model answered**,
  so Claude can judge reliability or propose a switch. Each purpose tool ships
  a task-tuned system prompt and temperature (code ≈ 0.2, summaries ≈ 0.4).
- **Purpose-specific tools are additive.** New ones (or retiring old ones) are
  ~10 lines each and require no client-side migration — MCP clients rediscover
  tools via `tools/list` each session. Tool descriptions are the contract that
  teaches Claude *when* to delegate; invest in them.
- **`switch_model` is non-blocking:** it validates the requested GGUF against
  the on-disk catalog, gracefully terminates any llama-server already bound to
  port 8080 (SIGTERM; required — otherwise the new instance fails to bind;
  verify during implementation whether `start-server.sh` already does this),
  launches `start-server.sh` detached, and returns immediately with "switch
  started — poll `local_model_status`". Blocking 2–5
  minutes (JIT kernel recompilation on every start, `SYCL_CACHE_PERSISTENT=0`
  workaround) would collide with client-side MCP tool timeouts. Claude Code's
  permission prompt on this tool is the agreed human confirmation gate (hybrid
  model-switching policy).
- **Reasoning-model gotcha (known from llama-cpp-arc §9.2):** if the active
  model is Qwen3/Ornith/DeepSeek-R1 served without `--skip-chat-parsing`, the
  answer may land in `reasoning_content` with an empty `content`. The server
  extracts `content` and, when it is empty, says so explicitly in the tool
  result instead of returning a silent empty string.

## Error handling

Every tool returns an agent-readable result — never a raw traceback:

- **Server down** (connection refused on 8080): explicit message — *"llama-server
  is not running — start it with start-server.sh or call switch_model"*. Most
  likely day-to-day failure.
- **Server starting** (503 on `/health` during JIT compilation): distinguished
  from "down" — *"server is loading/compiling, retry shortly"* — so Claude does
  not propose restarting something that is already starting.
- **Inference timeout:** generous httpx timeout (300 s) because ~10 tok/s is slow
  by nature; bounded default `max_tokens` (1024) so a delegation cannot run away.
- **Empty `content` from a reasoning model:** detected and explained (see above).
- **`switch_model` with a nonexistent GGUF:** validated against the disk catalog
  *before* launching anything.

## Testing

- **Automated smoke tests** (`pytest`, `httpx.MockTransport` mocking `/v1`):
  contracts of all six tools, including error paths (refused, 503,
  `reasoning_content`).
- **Real end-to-end validation:** register the MCP server and, from a live
  Claude Code session, delegate one task per tool against the running
  llama-server (verification with the mechanism closest to runtime).
- **MCP Inspector** (`npx @modelcontextprotocol/inspector`) as the manual
  debugging tool for handshake issues.

## Migration path to multi-client (future, point 2)

- Tool code: zero changes (FastMCP separates tools from transport).
- Swap `mcp.run(transport="stdio")` for `mcp.run(transport="streamable-http")`
  on a dedicated port (e.g. 8765 — must not collide with inference on 8080),
  re-register clients by URL. Both transports can coexist behind a flag.
- Real cost is operational, not code: a persistent process (systemd *user*
  unit) instead of client-spawned lifecycles.

## Relationship to the vllm-arc evaluation (future)

Evaluated 2026-07-02: the planned vLLM evaluation does **not** block this
project, because the MCP server is backend-agnostic by design — it talks to
`localhost:8080/v1`, the client-facing convention documented in `~/llm/CLAUDE.md`
precisely so backends can change without touching clients.

- **Survives a backend change:** all delegation tools (`summarize`,
  `draft_code`, `second_opinion`, `ask_local_model`) and `local_model_status`'s
  health/loaded-model reporting.
- **At risk (and cheap):** `switch_model` (~30 lines, additive/removable
  without client migration) and the on-disk GGUF catalog logic, which are
  llama.cpp-specific.
- **Facts that framed the decision:** a vLLM process serves a single model
  (multi-model = multiple instances, each holding full memory; no
  Ollama-style load/unload) and prefers FP16/AWQ/GPTQ weights (~16 GB for an
  8B FP16 vs ~4.7 GB Q4_K_M GGUF) — a tight fit for ~20 GB of available
  unified memory. The 2–5 min model-start cost is machine-level (JIT kernel
  recompilation, `SYCL_CACHE_PERSISTENT=0`), so any on-demand
  loading/swapping orchestrator pays it equally.
- **For the vllm-arc phase:** also evaluate **llama-swap** (proxy that routes
  on the request's `model` field and starts/stops llama-server instances on
  demand) as the lightweight path to Ollama-style swapping on the current
  stack; if either lands on port 8080, retire `switch_model` accordingly.

## Project layout

```
mcp-local-llm/
├── server.py           # FastMCP server — all six tools
├── requirements.txt    # mcp, httpx (pytest for dev)
├── .venv/              # native venv (gitignored)
├── tests/
│   └── test_tools.py
├── CLAUDE.md           # stack-specific agent instructions (English)
├── README.md           # setup + registration + usage (English)
└── docs/superpowers/specs/2026-07-02-local-models-mcp-design.md
```
