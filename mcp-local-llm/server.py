"""mcp-local-llm — FastMCP stdio server for delegating bounded subtasks
to the local llama-server (Intel Arc 140V, OpenAI-compatible /v1 surface)."""

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


if __name__ == "__main__":
    mcp.run(transport="stdio")
