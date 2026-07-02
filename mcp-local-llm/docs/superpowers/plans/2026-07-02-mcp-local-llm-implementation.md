# mcp-local-llm Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `mcp-local-llm`, a stdio FastMCP server exposing six tools (`summarize`, `draft_code`, `second_opinion`, `ask_local_model`, `local_model_status`, `switch_model`) that let Claude Code delegate bounded subtasks to the local llama-server on `localhost:8080/v1`.

**Architecture:** Single-file FastMCP server (`server.py`) per the approved design's project layout. A shared `_query_model()` helper wraps the OpenAI-compatible `/v1/chat/completions` call with error normalization (connection refused, 503-loading, timeout, empty `content`/`reasoning_content`); the three purpose tools and the generic fallback all call it with different system prompts/temperature. `local_model_status` reads `/v1/models` for the loaded model and globs the on-disk GGUF directory for the catalog. `switch_model` validates against that same catalog, SIGTERMs whatever is bound to port 8080, and launches `start-server.sh <file>` detached — non-blocking, per the design's timeout-avoidance requirement.

**Tech Stack:** Python 3.12 (system, native venv), `mcp` (official SDK, FastMCP), `httpx` for the sync HTTP client, `pytest` + `httpx.MockTransport` for tests. No Docker.

## Global Constraints

- **No Docker** — native venv only (`~/llm/CLAUDE.md` architecture decision).
- **Transport is `stdio` only** for this plan — no HTTP transport (future work, see design §Migration path).
- **Port `8080`, `/v1` OpenAI-compatible surface** is the fixed backend convention (`~/llm/CLAUDE.md`); never hardcode `11434` or any Ollama-specific path.
- **No privileged operations** — no `sudo`, no systemd, no HKLM/registry equivalents. `switch_model` acts only as the invoking user, via SIGTERM and a normal subprocess launch of the existing `start-server.sh`.
- **Every tool result must be agent-readable text, never a raw traceback** — all failure paths return a string explaining what happened and what to do next.
- **Bounded generation by default:** `max_tokens` defaults to 1024 across all tools unless the caller overrides it, to prevent a runaway local generation.
- **Inference HTTP timeout: 300 seconds** (generous — ~10 tok/s is the expected steady state on this hardware, not a bug).
- **Every purpose-tool response reports which model answered** (from `/v1/models`), since the tools cannot pick a model themselves (single-active-model hardware constraint).
- **Docs in English** (`~/llm/CLAUDE.md` docs-language rule) — `CLAUDE.md`, `README.md`, code comments.
- **Do not implement HTTP/streamable transport or systemd units in this plan** — explicitly out of scope per the design's Migration path (future work).

---

## File Structure

```
mcp-local-llm/
├── server.py               # FastMCP server: all six tools + shared helpers (Tasks 1-5)
├── requirements.txt        # mcp, httpx; pytest as a dev-only extra (Task 1)
├── .venv/                  # native venv, gitignored (Task 1)
├── tests/
│   └── test_tools.py       # pytest + httpx.MockTransport smoke tests (Tasks 2-5)
├── CLAUDE.md                # stack-specific agent instructions (Task 6)
├── README.md                 # setup, registration, usage (Task 6)
└── docs/superpowers/
    ├── specs/2026-07-02-local-models-mcp-design.md   # already exists
    └── plans/2026-07-02-mcp-local-llm-implementation.md  # this file
```

`server.py` stays a single file because the design's own "Project layout" section specifies exactly this shape (six tools is small enough to hold in context at once, and FastMCP tool registration reads best co-located with the helper it calls).

---

### Task 1: Project scaffolding — venv, dependencies, FastMCP skeleton

**Files:**
- Create: `mcp-local-llm/requirements.txt`
- Create: `mcp-local-llm/server.py`
- Create: `mcp-local-llm/tests/__init__.py` (empty, makes `tests` a package for pytest discovery)

**Interfaces:**
- Produces: module-level `mcp = FastMCP("local-llm")` instance in `server.py`, importable as `from server import mcp`. Later tasks add `@mcp.tool()`-decorated functions to this same instance.
- Produces: module-level constants later tasks rely on: `MODELS_DIR: Path`, `START_SERVER_SCRIPT: Path`, `LLAMA_SERVER_BASE_URL: str = "http://localhost:8080"`, `DEFAULT_MAX_TOKENS: int = 1024`, `INFERENCE_TIMEOUT: float = 300.0`.

- [ ] **Step 1: Create the requirements file**

```text
mcp>=1.2.0
httpx>=0.27
```

Write this to `mcp-local-llm/requirements.txt`. `pytest` is installed separately in the dev venv (Step 2) — it is not a runtime dependency of the shipped server.

- [ ] **Step 2: Create the venv and install dependencies**

Run:
```bash
cd ~/llm/mcp-local-llm
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/pip install pytest
```
Expected: no errors; `.venv/bin/python -c "import mcp, httpx; print('ok')"` prints `ok`.

- [ ] **Step 3: Write the server skeleton**

Create `mcp-local-llm/server.py`:

```python
"""mcp-local-llm — FastMCP stdio server for delegating bounded subtasks
to the local llama-server (Intel Arc 140V, OpenAI-compatible /v1 surface)."""

from pathlib import Path

from mcp.server.fastmcp import FastMCP

REPO_ROOT = Path(__file__).resolve().parent.parent
MODELS_DIR = REPO_ROOT / "llama-cpp-arc" / "models"
START_SERVER_SCRIPT = REPO_ROOT / "llama-cpp-arc" / "start-server.sh"
LLAMA_SERVER_BASE_URL = "http://localhost:8080"
DEFAULT_MAX_TOKENS = 1024
INFERENCE_TIMEOUT = 300.0

mcp = FastMCP("local-llm")


if __name__ == "__main__":
    mcp.run(transport="stdio")
```

- [ ] **Step 4: Create the empty tests package**

Create `mcp-local-llm/tests/__init__.py` with empty content.

- [ ] **Step 5: Verify the skeleton imports and the server starts**

Run:
```bash
cd ~/llm/mcp-local-llm
.venv/bin/python -c "from server import mcp; print(mcp.name)"
```
Expected: prints `local-llm`.

- [ ] **Step 6: Commit**

```bash
cd ~/llm
git add mcp-local-llm/requirements.txt mcp-local-llm/server.py mcp-local-llm/tests/__init__.py mcp-local-llm/.gitignore 2>/dev/null
git add mcp-local-llm/requirements.txt mcp-local-llm/server.py mcp-local-llm/tests/__init__.py
git commit -m "feat(mcp-local-llm): scaffold FastMCP stdio server skeleton"
```

---

### Task 2: Shared inference helper + `local_model_status` tool

**Files:**
- Modify: `mcp-local-llm/server.py`
- Test: `mcp-local-llm/tests/test_tools.py` (create)

**Interfaces:**
- Consumes: `mcp`, `LLAMA_SERVER_BASE_URL`, `MODELS_DIR`, `INFERENCE_TIMEOUT` from Task 1.
- Produces: `_query_model(prompt: str, system: str | None = None, max_tokens: int = DEFAULT_MAX_TOKENS, temperature: float = 0.7, client: httpx.Client | None = None) -> dict` — the shared inference helper every later tool (Tasks 3, 4) calls. Returns a dict with either `{"ok": True, "content": str, "model": str}` or `{"ok": False, "error": str}`. Never raises for expected failure modes (connection refused, timeout, 503, HTTP error, empty content).
- Produces: `_get_loaded_model(client: httpx.Client | None = None) -> str | None` — queries `/v1/models`, returns the loaded model id or `None` if unreachable. Reused by `local_model_status` (this task) and by every purpose tool to report "answered by".
- Produces: `@mcp.tool() local_model_status() -> str` tool.

- [ ] **Step 1: Write the failing tests for `_query_model` and `_get_loaded_model`**

Create `mcp-local-llm/tests/test_tools.py`:

```python
import httpx
import pytest

import server


def _client_with_transport(handler):
    return httpx.Client(base_url=server.LLAMA_SERVER_BASE_URL, transport=httpx.MockTransport(handler))


def test_get_loaded_model_returns_id_when_server_up():
    def handler(request):
        assert request.url.path == "/v1/models"
        return httpx.Response(200, json={"data": [{"id": "Qwen3-8B-Q4_K_M.gguf"}]})

    client = _client_with_transport(handler)
    assert server._get_loaded_model(client=client) == "Qwen3-8B-Q4_K_M.gguf"


def test_get_loaded_model_returns_none_when_connection_refused():
    def handler(request):
        raise httpx.ConnectError("refused", request=request)

    client = _client_with_transport(handler)
    assert server._get_loaded_model(client=client) is None


def test_query_model_success():
    def handler(request):
        assert request.url.path == "/v1/chat/completions"
        return httpx.Response(
            200,
            json={
                "choices": [{"message": {"content": "hello"}}],
                "model": "Qwen3-8B-Q4_K_M.gguf",
            },
        )

    client = _client_with_transport(handler)
    result = server._query_model("hi", client=client)
    assert result == {"ok": True, "content": "hello", "model": "Qwen3-8B-Q4_K_M.gguf"}


def test_query_model_connection_refused():
    def handler(request):
        raise httpx.ConnectError("refused", request=request)

    client = _client_with_transport(handler)
    result = server._query_model("hi", client=client)
    assert result["ok"] is False
    assert "not running" in result["error"]
    assert "switch_model" in result["error"]


def test_query_model_timeout():
    def handler(request):
        raise httpx.TimeoutException("timed out", request=request)

    client = _client_with_transport(handler)
    result = server._query_model("hi", client=client)
    assert result["ok"] is False
    assert "timed out" in result["error"]


def test_query_model_503_loading():
    def handler(request):
        return httpx.Response(503, json={"error": "loading model"})

    client = _client_with_transport(handler)
    result = server._query_model("hi", client=client)
    assert result["ok"] is False
    assert "loading" in result["error"] or "compiling" in result["error"]


def test_query_model_empty_content_with_reasoning():
    def handler(request):
        return httpx.Response(
            200,
            json={
                "choices": [
                    {
                        "message": {
                            "content": "",
                            "reasoning_content": "thinking about it...",
                        }
                    }
                ],
                "model": "Qwen3-8B-Q4_K_M.gguf",
            },
        )

    client = _client_with_transport(handler)
    result = server._query_model("hi", client=client)
    assert result["ok"] is False
    assert "reasoning_content" in result["error"]
    assert "--skip-chat-parsing" in result["error"]
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ~/llm/mcp-local-llm && .venv/bin/pytest tests/test_tools.py -v`
Expected: `FAIL` / `ERROR` — `AttributeError: module 'server' has no attribute '_query_model'` (and `_get_loaded_model`).

- [ ] **Step 3: Implement `_get_loaded_model` and `_query_model`**

Add to `mcp-local-llm/server.py` (after the constants, before the `if __name__` block):

```python
import httpx


def _get_loaded_model(client: httpx.Client | None = None) -> str | None:
    owns_client = client is None
    client = client or httpx.Client(base_url=LLAMA_SERVER_BASE_URL, timeout=10.0)
    try:
        response = client.get("/v1/models")
        response.raise_for_status()
        data = response.json().get("data", [])
        return data[0]["id"] if data else None
    except (httpx.HTTPError, KeyError, IndexError, ValueError):
        return None
    finally:
        if owns_client:
            client.close()


def _query_model(
    prompt: str,
    system: str | None = None,
    max_tokens: int = DEFAULT_MAX_TOKENS,
    temperature: float = 0.7,
    client: httpx.Client | None = None,
) -> dict:
    owns_client = client is None
    client = client or httpx.Client(base_url=LLAMA_SERVER_BASE_URL, timeout=INFERENCE_TIMEOUT)

    messages = []
    if system:
        messages.append({"role": "system", "content": system})
    messages.append({"role": "user", "content": prompt})

    try:
        response = client.post(
            "/v1/chat/completions",
            json={"messages": messages, "max_tokens": max_tokens, "temperature": temperature},
        )
    except httpx.ConnectError:
        return {
            "ok": False,
            "error": "llama-server is not running — start it with start-server.sh or call switch_model",
        }
    except httpx.TimeoutException:
        return {"ok": False, "error": f"Request to llama-server timed out after {INFERENCE_TIMEOUT}s"}
    finally:
        if owns_client:
            client.close()

    if response.status_code == 503:
        return {"ok": False, "error": "llama-server is loading/compiling, retry shortly"}

    try:
        response.raise_for_status()
    except httpx.HTTPStatusError as exc:
        return {"ok": False, "error": f"llama-server returned {exc.response.status_code}: {exc.response.text[:200]}"}

    body = response.json()
    message = body["choices"][0]["message"]
    model = body.get("model", "unknown")
    content = message.get("content") or ""

    if not content and message.get("reasoning_content"):
        return {
            "ok": False,
            "error": (
                "the active model returned its answer in reasoning_content with an empty "
                "content field — restart it with --skip-chat-parsing to get plain content"
            ),
        }

    return {"ok": True, "content": content, "model": model}
```

Note: the `finally: client.close()` under the `try/except` for the POST call only fires on the exception paths in this structure — move it to wrap the whole function body correctly. Use this corrected version instead:

```python
def _query_model(
    prompt: str,
    system: str | None = None,
    max_tokens: int = DEFAULT_MAX_TOKENS,
    temperature: float = 0.7,
    client: httpx.Client | None = None,
) -> dict:
    owns_client = client is None
    client = client or httpx.Client(base_url=LLAMA_SERVER_BASE_URL, timeout=INFERENCE_TIMEOUT)
    try:
        messages = []
        if system:
            messages.append({"role": "system", "content": system})
        messages.append({"role": "user", "content": prompt})

        try:
            response = client.post(
                "/v1/chat/completions",
                json={"messages": messages, "max_tokens": max_tokens, "temperature": temperature},
            )
        except httpx.ConnectError:
            return {
                "ok": False,
                "error": "llama-server is not running — start it with start-server.sh or call switch_model",
            }
        except httpx.TimeoutException:
            return {"ok": False, "error": f"Request to llama-server timed out after {INFERENCE_TIMEOUT}s"}

        if response.status_code == 503:
            return {"ok": False, "error": "llama-server is loading/compiling, retry shortly"}

        try:
            response.raise_for_status()
        except httpx.HTTPStatusError as exc:
            return {
                "ok": False,
                "error": f"llama-server returned {exc.response.status_code}: {exc.response.text[:200]}",
            }

        body = response.json()
        message = body["choices"][0]["message"]
        model = body.get("model", "unknown")
        content = message.get("content") or ""

        if not content and message.get("reasoning_content"):
            return {
                "ok": False,
                "error": (
                    "the active model returned its answer in reasoning_content with an empty "
                    "content field — restart it with --skip-chat-parsing to get plain content"
                ),
            }

        return {"ok": True, "content": content, "model": model}
    finally:
        if owns_client:
            client.close()
```

Add `import httpx` near the top of the file with the other imports (not inline inside the function).

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ~/llm/mcp-local-llm && .venv/bin/pytest tests/test_tools.py -v`
Expected: all 7 tests `PASS`.

- [ ] **Step 5: Write the failing test for `local_model_status`**

Append to `mcp-local-llm/tests/test_tools.py`:

```python
def test_local_model_status_server_up(monkeypatch, tmp_path):
    (tmp_path / "Qwen3-8B-Q4_K_M.gguf").touch()
    (tmp_path / "Gemma-4-12B.gguf").touch()
    monkeypatch.setattr(server, "MODELS_DIR", tmp_path)

    def handler(request):
        return httpx.Response(200, json={"data": [{"id": "Qwen3-8B-Q4_K_M.gguf"}]})

    monkeypatch.setattr(
        server, "_get_loaded_model", lambda client=None: server._get_loaded_model.__wrapped__(client)
        if hasattr(server._get_loaded_model, "__wrapped__") else "Qwen3-8B-Q4_K_M.gguf"
    )

    result = server.local_model_status()
    assert "Qwen3-8B-Q4_K_M.gguf" in result
    assert "Gemma-4-12B.gguf" in result


def test_local_model_status_server_down(monkeypatch, tmp_path):
    monkeypatch.setattr(server, "MODELS_DIR", tmp_path)
    monkeypatch.setattr(server, "_get_loaded_model", lambda: None)

    result = server.local_model_status()
    assert "not running" in result
```

- [ ] **Step 6: Run tests to verify they fail**

Run: `cd ~/llm/mcp-local-llm && .venv/bin/pytest tests/test_tools.py -v -k local_model_status`
Expected: `FAIL` — `AttributeError: module 'server' has no attribute 'local_model_status'`.

- [ ] **Step 7: Implement `local_model_status`**

Add to `mcp-local-llm/server.py`, after `_query_model`:

```python
@mcp.tool()
def local_model_status() -> str:
    """Report whether the local llama-server is running, which GGUF is
    currently loaded, and which GGUFs are available on disk to switch to."""
    loaded = _get_loaded_model()
    catalog = sorted(p.name for p in MODELS_DIR.glob("*.gguf")) if MODELS_DIR.exists() else []
    catalog_text = "\n".join(f"  - {name}" for name in catalog) or "  (none found)"

    if loaded is None:
        return (
            "llama-server is not running on localhost:8080 — "
            "start it with start-server.sh or call switch_model.\n\n"
            f"On-disk GGUF catalog:\n{catalog_text}"
        )

    return f"llama-server is running. Loaded model: {loaded}\n\nOn-disk GGUF catalog:\n{catalog_text}"
```

Simplify the Step 5 test's awkward monkeypatch — replace it with a direct `monkeypatch.setattr(server, "_get_loaded_model", lambda: "Qwen3-8B-Q4_K_M.gguf")` for the "up" case. Edit `test_local_model_status_server_up` to:

```python
def test_local_model_status_server_up(monkeypatch, tmp_path):
    (tmp_path / "Qwen3-8B-Q4_K_M.gguf").touch()
    (tmp_path / "Gemma-4-12B.gguf").touch()
    monkeypatch.setattr(server, "MODELS_DIR", tmp_path)
    monkeypatch.setattr(server, "_get_loaded_model", lambda: "Qwen3-8B-Q4_K_M.gguf")

    result = server.local_model_status()
    assert "Qwen3-8B-Q4_K_M.gguf" in result
    assert "Gemma-4-12B.gguf" in result
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `cd ~/llm/mcp-local-llm && .venv/bin/pytest tests/test_tools.py -v`
Expected: all tests `PASS` (9 total).

- [ ] **Step 9: Commit**

```bash
cd ~/llm
git add mcp-local-llm/server.py mcp-local-llm/tests/test_tools.py
git commit -m "feat(mcp-local-llm): add _query_model helper and local_model_status tool"
```

---

### Task 3: `ask_local_model` generic fallback tool

**Files:**
- Modify: `mcp-local-llm/server.py`
- Test: `mcp-local-llm/tests/test_tools.py`

**Interfaces:**
- Consumes: `_query_model(prompt, system, max_tokens, temperature) -> dict` from Task 2.
- Produces: `@mcp.tool() ask_local_model(prompt: str, system: str | None = None, max_tokens: int = DEFAULT_MAX_TOKENS, temperature: float = 0.7) -> str`. Later purpose tools (Task 4) follow the same response-formatting pattern this tool establishes: `"{content}\n\n(answered by {model})"` on success, `result["error"]` verbatim on failure.

- [ ] **Step 1: Write the failing tests**

Append to `mcp-local-llm/tests/test_tools.py`:

```python
def test_ask_local_model_success(monkeypatch):
    monkeypatch.setattr(
        server, "_query_model",
        lambda prompt, system=None, max_tokens=server.DEFAULT_MAX_TOKENS, temperature=0.7: {
            "ok": True, "content": "42", "model": "Qwen3-8B-Q4_K_M.gguf",
        },
    )
    result = server.ask_local_model("what is the answer?")
    assert "42" in result
    assert "Qwen3-8B-Q4_K_M.gguf" in result


def test_ask_local_model_error_passthrough(monkeypatch):
    monkeypatch.setattr(
        server, "_query_model",
        lambda prompt, system=None, max_tokens=server.DEFAULT_MAX_TOKENS, temperature=0.7: {
            "ok": False, "error": "llama-server is not running — start it with start-server.sh or call switch_model",
        },
    )
    result = server.ask_local_model("anything")
    assert "not running" in result
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ~/llm/mcp-local-llm && .venv/bin/pytest tests/test_tools.py -v -k ask_local_model`
Expected: `FAIL` — `AttributeError: module 'server' has no attribute 'ask_local_model'`.

- [ ] **Step 3: Implement `ask_local_model`**

Add to `mcp-local-llm/server.py`, after `local_model_status`:

```python
@mcp.tool()
def ask_local_model(
    prompt: str,
    system: str | None = None,
    max_tokens: int = DEFAULT_MAX_TOKENS,
    temperature: float = 0.7,
) -> str:
    """Generic fallback: send any prompt to the local model. Use this when
    the task doesn't fit summarize/draft_code/second_opinion — e.g. a
    privacy-sensitive question that must not leave this machine, or a
    one-off request that doesn't warrant a dedicated tool."""
    result = _query_model(prompt, system=system, max_tokens=max_tokens, temperature=temperature)
    if not result["ok"]:
        return result["error"]
    return f"{result['content']}\n\n(answered by {result['model']})"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ~/llm/mcp-local-llm && .venv/bin/pytest tests/test_tools.py -v`
Expected: all tests `PASS` (11 total).

- [ ] **Step 5: Commit**

```bash
cd ~/llm
git add mcp-local-llm/server.py mcp-local-llm/tests/test_tools.py
git commit -m "feat(mcp-local-llm): add ask_local_model generic fallback tool"
```

---

### Task 4: `summarize`, `draft_code`, `second_opinion` purpose tools

**Files:**
- Modify: `mcp-local-llm/server.py`
- Test: `mcp-local-llm/tests/test_tools.py`

**Interfaces:**
- Consumes: `_query_model` from Task 2; the response-formatting pattern from Task 3's `ask_local_model`.
- Produces: `@mcp.tool() summarize(text: str, focus: str | None = None) -> str`, `@mcp.tool() draft_code(spec: str, language: str | None = None) -> str`, `@mcp.tool() second_opinion(question: str, context: str | None = None) -> str`.

- [ ] **Step 1: Write the failing tests**

Append to `mcp-local-llm/tests/test_tools.py`:

```python
def _fake_query_model(**overrides):
    base = {"ok": True, "content": "result text", "model": "Qwen3-8B-Q4_K_M.gguf"}
    base.update(overrides)
    return lambda prompt, system=None, max_tokens=server.DEFAULT_MAX_TOKENS, temperature=0.7: base


def test_summarize_success(monkeypatch):
    captured = {}

    def fake(prompt, system=None, max_tokens=server.DEFAULT_MAX_TOKENS, temperature=0.7):
        captured["system"] = system
        captured["temperature"] = temperature
        captured["prompt"] = prompt
        return {"ok": True, "content": "short summary", "model": "Qwen3-8B-Q4_K_M.gguf"}

    monkeypatch.setattr(server, "_query_model", fake)
    result = server.summarize("a long piece of text", focus="key decisions")
    assert "short summary" in result
    assert captured["temperature"] == 0.4
    assert "key decisions" in captured["prompt"] or "key decisions" in (captured["system"] or "")


def test_draft_code_success(monkeypatch):
    captured = {}

    def fake(prompt, system=None, max_tokens=server.DEFAULT_MAX_TOKENS, temperature=0.7):
        captured["system"] = system
        captured["temperature"] = temperature
        return {"ok": True, "content": "def f(): pass", "model": "Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf"}

    monkeypatch.setattr(server, "_query_model", fake)
    result = server.draft_code("a function that returns nothing", language="python")
    assert "def f(): pass" in result
    assert captured["temperature"] == 0.2


def test_second_opinion_success(monkeypatch):
    def fake(prompt, system=None, max_tokens=server.DEFAULT_MAX_TOKENS, temperature=0.7):
        return {"ok": True, "content": "I'd also consider X", "model": "Ornith-1.0-9b-Q6_K.gguf"}

    monkeypatch.setattr(server, "_query_model", fake)
    result = server.second_opinion("should I use a mutex here?", context="single-writer queue")
    assert "I'd also consider X" in result


def test_summarize_error_passthrough(monkeypatch):
    monkeypatch.setattr(server, "_query_model", _fake_query_model(ok=False, error="llama-server is not running"))
    result = server.summarize("text")
    assert "not running" in result
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ~/llm/mcp-local-llm && .venv/bin/pytest tests/test_tools.py -v -k "summarize or draft_code or second_opinion"`
Expected: `FAIL` — `AttributeError: module 'server' has no attribute 'summarize'` (and the other two).

- [ ] **Step 3: Implement the three purpose tools**

Add to `mcp-local-llm/server.py`, after `ask_local_model`:

```python
@mcp.tool()
def summarize(text: str, focus: str | None = None) -> str:
    """Summarize or condense text or logs using the local model. Use for
    long output (build logs, diffs, articles) where only the gist matters."""
    system = "You are a precise summarizer. Produce a concise summary of the user's text."
    prompt = text
    if focus:
        system += f" Focus specifically on: {focus}."
        prompt = f"Focus on {focus}.\n\n{text}"
    result = _query_model(prompt, system=system, temperature=0.4)
    if not result["ok"]:
        return result["error"]
    return f"{result['content']}\n\n(answered by {result['model']})"


@mcp.tool()
def draft_code(spec: str, language: str | None = None) -> str:
    """Produce a first draft of code or a script from a spec, using the
    local model. Use for boilerplate or a starting point to refine, not
    for final production code."""
    system = "You are a careful programmer. Write a first-draft implementation for the given spec."
    if language:
        system += f" Write it in {language}."
    result = _query_model(spec, system=system, temperature=0.2)
    if not result["ok"]:
        return result["error"]
    return f"{result['content']}\n\n(answered by {result['model']})"


@mcp.tool()
def second_opinion(question: str, context: str | None = None) -> str:
    """Get a second opinion on a solution, design, or piece of reasoning
    from the local model — useful as an independent sanity check."""
    system = "You are a skeptical reviewer. Give a direct second opinion, noting any risks or alternatives."
    prompt = question
    if context:
        prompt = f"Context: {context}\n\nQuestion: {question}"
    result = _query_model(prompt, system=system, temperature=0.4)
    if not result["ok"]:
        return result["error"]
    return f"{result['content']}\n\n(answered by {result['model']})"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ~/llm/mcp-local-llm && .venv/bin/pytest tests/test_tools.py -v`
Expected: all tests `PASS` (15 total).

- [ ] **Step 5: Commit**

```bash
cd ~/llm
git add mcp-local-llm/server.py mcp-local-llm/tests/test_tools.py
git commit -m "feat(mcp-local-llm): add summarize, draft_code, second_opinion purpose tools"
```

---

### Task 5: `switch_model` tool

**Files:**
- Modify: `mcp-local-llm/server.py`
- Test: `mcp-local-llm/tests/test_tools.py`

**Interfaces:**
- Consumes: `MODELS_DIR`, `START_SERVER_SCRIPT` from Task 1.
- Produces: `@mcp.tool() switch_model(model: str) -> str`. Produces `_find_port_8080_pids() -> list[int]` and `_terminate_pids(pids: list[int]) -> None` as internal helpers, kept separate so tests can monkeypatch subprocess/os interaction without touching the public tool's validation logic.

- [ ] **Step 1: Write the failing tests**

Append to `mcp-local-llm/tests/test_tools.py`:

```python
def test_switch_model_rejects_unknown_gguf(monkeypatch, tmp_path):
    (tmp_path / "Qwen3-8B-Q4_K_M.gguf").touch()
    monkeypatch.setattr(server, "MODELS_DIR", tmp_path)

    result = server.switch_model("Nonexistent-Model.gguf")
    assert "not found" in result.lower()
    assert "Qwen3-8B-Q4_K_M.gguf" in result


def test_switch_model_launches_start_server(monkeypatch, tmp_path):
    (tmp_path / "Qwen3-8B-Q4_K_M.gguf").touch()
    monkeypatch.setattr(server, "MODELS_DIR", tmp_path)
    monkeypatch.setattr(server, "_find_port_8080_pids", lambda: [1234])

    terminated = []
    monkeypatch.setattr(server, "_terminate_pids", lambda pids: terminated.extend(pids))

    launched = {}

    class FakePopen:
        def __init__(self, args, **kwargs):
            launched["args"] = args
            launched["kwargs"] = kwargs

    monkeypatch.setattr(server.subprocess, "Popen", FakePopen)

    result = server.switch_model("Qwen3-8B-Q4_K_M.gguf")
    assert terminated == [1234]
    assert launched["args"] == [str(server.START_SERVER_SCRIPT), "Qwen3-8B-Q4_K_M.gguf"]
    assert launched["kwargs"]["start_new_session"] is True
    assert "switch started" in result.lower()
    assert "local_model_status" in result


def test_switch_model_skips_terminate_when_nothing_bound(monkeypatch, tmp_path):
    (tmp_path / "Gemma-4-12B.gguf").touch()
    monkeypatch.setattr(server, "MODELS_DIR", tmp_path)
    monkeypatch.setattr(server, "_find_port_8080_pids", lambda: [])

    terminated = []
    monkeypatch.setattr(server, "_terminate_pids", lambda pids: terminated.extend(pids))
    monkeypatch.setattr(server.subprocess, "Popen", lambda args, **kwargs: None)

    result = server.switch_model("Gemma-4-12B.gguf")
    assert terminated == []
    assert "switch started" in result.lower()
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ~/llm/mcp-local-llm && .venv/bin/pytest tests/test_tools.py -v -k switch_model`
Expected: `FAIL` — `AttributeError: module 'server' has no attribute 'switch_model'`.

- [ ] **Step 3: Implement the helpers and the tool**

Add `import subprocess` and `import signal` near the top of `mcp-local-llm/server.py` with the other imports. Then add, after `second_opinion`:

```python
def _find_port_8080_pids() -> list[int]:
    try:
        output = subprocess.run(
            ["lsof", "-t", "-i:8080"], capture_output=True, text=True, timeout=5
        ).stdout
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return []
    return [int(pid) for pid in output.split() if pid.strip().isdigit()]


def _terminate_pids(pids: list[int]) -> None:
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass


@mcp.tool()
def switch_model(model: str) -> str:
    """Switch which GGUF llama-server is serving. Validates against the
    on-disk catalog, stops the current server, and starts the new one in
    the background — this does NOT block, because loading a model takes
    2-5 minutes (JIT kernel recompilation on this hardware). Poll
    local_model_status to see when the new model is ready."""
    catalog = sorted(p.name for p in MODELS_DIR.glob("*.gguf")) if MODELS_DIR.exists() else []
    if model not in catalog:
        catalog_text = "\n".join(f"  - {name}" for name in catalog) or "  (none found)"
        return f"'{model}' not found in the on-disk catalog. Available GGUFs:\n{catalog_text}"

    pids = _find_port_8080_pids()
    if pids:
        _terminate_pids(pids)

    subprocess.Popen(
        [str(START_SERVER_SCRIPT), model],
        start_new_session=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    return f"Switch started for '{model}' — this takes 2-5 minutes. Poll local_model_status to check readiness."
```

Add `import os` near the top of the file if not already present (it is not, from Task 1-4).

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ~/llm/mcp-local-llm && .venv/bin/pytest tests/test_tools.py -v`
Expected: all tests `PASS` (18 total).

- [ ] **Step 5: Commit**

```bash
cd ~/llm
git add mcp-local-llm/server.py mcp-local-llm/tests/test_tools.py
git commit -m "feat(mcp-local-llm): add switch_model tool with catalog validation and detached launch"
```

---

### Task 6: Docs (`CLAUDE.md`, `README.md`) and full-suite verification

**Files:**
- Create: `mcp-local-llm/CLAUDE.md`
- Create: `mcp-local-llm/README.md`

**Interfaces:**
- Consumes: nothing new — this task only documents the finished tool surface from Tasks 1-5.
- Produces: nothing consumed by later tasks (Task 7 is manual/human-gated).

- [ ] **Step 1: Write `mcp-local-llm/CLAUDE.md`**

```markdown
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
```

- [ ] **Step 2: Write `mcp-local-llm/README.md`**

```markdown
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
```

- [ ] **Step 3: Run the full test suite one final time**

Run: `cd ~/llm/mcp-local-llm && .venv/bin/pytest tests/ -v`
Expected: all 18 tests `PASS`, no warnings about unregistered marks.

- [ ] **Step 4: Commit**

```bash
cd ~/llm
git add mcp-local-llm/CLAUDE.md mcp-local-llm/README.md
git commit -m "docs(mcp-local-llm): add CLAUDE.md and README.md"
```

---

### Task 7: Manual end-to-end validation (human-gated, not subagent-executable)

This task registers the server into the user's **global** Claude Code config
(`claude mcp add --scope user`) and exercises it against the real
`llama-server`. Both are user-scoped, real-environment actions — per this
project's operating rules, present this as a proposal and wait for explicit
confirmation before running the registration command. Do not dispatch this
task to a subagent; run it in the main session with the user present.

**Files:** none (no code changes — verification only).

- [ ] **Step 1: Confirm `llama-server` is running**

Run: `curl -s localhost:8080/v1/models`
Expected: JSON with a `data` array containing the loaded GGUF. If it fails,
start one first: `~/llm/llama-cpp-arc/start-server.sh <model>`.

- [ ] **Step 2: Ask the user for confirmation, then register the server**

State plainly: "This will run `claude mcp add local-llm --scope user -- ...`,
which adds an entry to your global Claude Code MCP config." Wait for a yes
before running:

```bash
claude mcp add local-llm --scope user -- ~/llm/mcp-local-llm/.venv/bin/python ~/llm/mcp-local-llm/server.py
```

- [ ] **Step 3: Verify registration**

Run: `claude mcp list`
Expected: `local-llm` appears in the list.

- [ ] **Step 4: From a live Claude Code session, exercise each tool once**

Manually invoke, in order: `local_model_status`, `ask_local_model`,
`summarize`, `draft_code`, `second_opinion`. Confirm each returns real model
output (not an error) and reports the answering model's name. Then invoke
`switch_model` with a different on-disk GGUF, confirm the immediate
"switch started" response, and poll `local_model_status` every ~30s until
the new model shows as loaded (2-5 minutes).

- [ ] **Step 5: Record the result**

If all six tools behave as expected, this plan is complete — no commit
needed (no code changed in this task). If anything fails, return to the
relevant task above, fix, and re-verify with the mechanism closest to
runtime (this same manual flow), per this project's diagnosis-and-verification
rule: investigate the root cause rather than patching around it.

---

## Self-Review Notes

- **Spec coverage:** all six tools (Task 2-5), error handling for connection-refused/503/timeout/empty-reasoning-content (Task 2's `_query_model`), non-blocking `switch_model` with port-8080 termination (Task 5), automated smoke tests with `httpx.MockTransport` (Tasks 2-5), real end-to-end validation and MCP Inspector mention (Task 7/CLAUDE.md), project layout and docs (Task 1, Task 6), user-scope registration command (Task 7, README). The "Migration path to multi-client" and "Relationship to vllm-arc" sections of the design are explicitly future work / already satisfied by the backend-agnostic `localhost:8080/v1` design — no task needed, noted in Global Constraints and CLAUDE.md.
- **Placeholder scan:** no TBD/TODO markers; every step has literal code or literal commands.
- **Type consistency:** `_query_model` return shape (`{"ok": bool, "content"/"error", "model"}`) is defined once in Task 2 and consumed identically in Tasks 3-4. `_find_port_8080_pids`/`_terminate_pids` names introduced in Task 5 match their test monkeypatches exactly.
