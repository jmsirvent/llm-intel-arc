# mcp-local-llm — Local Models as MCP Tools

FastMCP stdio server exposing the local llama-server (`~/llm/llama-cpp-arc/`)
as six Claude Code tools. Hardware and ecosystem context: `../CLAUDE.md`.
Design rationale: `docs/superpowers/specs/2026-07-02-local-models-mcp-design.md`.

## Project structure

```
mcp-local-llm/
├── server.py           # FastMCP server — all six tools
├── requirements.txt    # mcp, httpx
├── .venv/              # native venv (gitignored)
└── tests/
    └── test_tools.py   # pytest + httpx.MockTransport smoke tests
```

## Development commands

```bash
# Setup
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/pip install pytest   # dev only

# Run tests
.venv/bin/pytest tests/ -v

# Run the server directly (for manual/inspector debugging)
.venv/bin/python server.py

# Debug the MCP handshake
npx @modelcontextprotocol/inspector .venv/bin/python server.py
```

## Tools

| Tool | Purpose |
|---|---|
| `summarize` | Condense text/logs |
| `draft_code` | First-draft code from a spec |
| `second_opinion` | Independent review of a solution/decision |
| `ask_local_model` | Generic fallback for anything else |
| `local_model_status` | Loaded model, server health, on-disk GGUF catalog |
| `switch_model` | Change the served GGUF (non-blocking, 2-5 min) |

## Notes

- Talks to `localhost:8080/v1` — the fixed client-facing convention from
  `~/llm/CLAUDE.md`. Backend-agnostic: works unchanged if `llama-cpp-arc`
  is later replaced by `vllm-arc`.
- Purpose tools never pick a model — they use whatever is loaded and report
  it in every response (single-active-model hardware constraint).
- `switch_model` requires `lsof` on `PATH` to find and stop whatever is
  currently bound to port 8080 before launching the new instance.
