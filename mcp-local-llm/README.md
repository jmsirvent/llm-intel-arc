# mcp-local-llm

MCP server that lets Claude Code delegate bounded subtasks (summaries, code
drafts, second opinions, privacy-sensitive prompts) to a local LLM served by
`llama-cpp-arc`, instead of ad hoc `curl`/`agy` calls.

## Setup

```bash
cd ~/llm/mcp-local-llm
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

## Register with Claude Code

```bash
claude mcp add local-llm --scope user -- ~/llm/mcp-local-llm/.venv/bin/python ~/llm/mcp-local-llm/server.py
```

User scope makes delegation available from any project, not just this repo.

## Prerequisites

- `llama-server` running on `localhost:8080` (see `../llama-cpp-arc/README.md`
  or run `../llama-cpp-arc/start-server.sh`).
- `lsof` on `PATH` (used by `switch_model` to find what's bound to port 8080).

## Tools

See `CLAUDE.md` for the full tool table and design notes.

## Testing

```bash
.venv/bin/pip install pytest
.venv/bin/pytest tests/ -v
```

Manual handshake debugging:

```bash
npx @modelcontextprotocol/inspector .venv/bin/python server.py
```
