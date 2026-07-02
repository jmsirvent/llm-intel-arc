"""mcp-local-llm — FastMCP stdio server for delegating bounded subtasks
to the local llama-server (Intel Arc 140V, OpenAI-compatible /v1 surface)."""

import os
import signal
import subprocess
from pathlib import Path

import httpx
from mcp.server.fastmcp import FastMCP

REPO_ROOT = Path(__file__).resolve().parent.parent
MODELS_DIR = REPO_ROOT / "llama-cpp-arc" / "models"
START_SERVER_SCRIPT = REPO_ROOT / "llama-cpp-arc" / "start-server.sh"
LLAMA_SERVER_BASE_URL = "http://localhost:8080"
DEFAULT_MAX_TOKENS = 1024
INFERENCE_TIMEOUT = 300.0

mcp = FastMCP("local-llm")


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
        except httpx.HTTPError as exc:
            return {
                "ok": False,
                "error": f"request to llama-server failed: {type(exc).__name__}: {exc}",
            }

        if response.status_code == 503:
            return {"ok": False, "error": "llama-server is loading/compiling, retry shortly"}

        try:
            response.raise_for_status()
        except httpx.HTTPStatusError as exc:
            return {
                "ok": False,
                "error": f"llama-server returned {exc.response.status_code}: {exc.response.text[:200]}",
            }

        try:
            body = response.json()
            message = body["choices"][0]["message"]
        except (ValueError, KeyError, IndexError, TypeError) as exc:
            return {
                "ok": False,
                "error": (
                    "llama-server returned a malformed response "
                    f"({type(exc).__name__}: {exc}); body: {response.text[:200]}"
                ),
            }
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


if __name__ == "__main__":
    mcp.run(transport="stdio")
