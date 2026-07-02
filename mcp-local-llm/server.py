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
