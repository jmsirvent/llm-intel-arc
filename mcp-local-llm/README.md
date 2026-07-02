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

## Manual validation

After registering, confirm the server actually works end to end:

1. Confirm `llama-server` is up (see `../llama-cpp-arc/README.md` for how to
   start/manage it):
   ```bash
   curl -s localhost:8080/v1/models
   ```
   Expect a JSON body with a `data` array containing the loaded GGUF.

2. Registering with `claude mcp add --scope user` adds an entry to your
   **global** Claude Code config, not just this project — confirm that's
   what you want before running it.

3. Verify the registration:
   ```bash
   claude mcp list
   ```
   `local-llm` should appear.

4. From a live Claude Code session, invoke each tool once: `local_model_status`,
   `ask_local_model`, `summarize`, `draft_code`, `second_opinion`. Each should
   return real model output (not an error) and report which model answered.

5. Invoke `switch_model` with a different on-disk GGUF, confirm the immediate
   "switch started" response, then poll `local_model_status` every ~30s until
   the new model shows as loaded (2-5 minutes).

If any tool misbehaves, fix the root cause and re-run this checklist — don't
treat a partial pass as done.

## Testing

```bash
.venv/bin/pip install pytest
.venv/bin/pytest tests/ -v
```

Manual handshake debugging:

```bash
npx @modelcontextprotocol/inspector .venv/bin/python server.py
```
