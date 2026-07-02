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


def test_query_model_malformed_response():
    def handler(request):
        return httpx.Response(200, json={"model": "Qwen3-8B-Q4_K_M.gguf"})

    client = _client_with_transport(handler)
    result = server._query_model("hi", client=client)
    assert result["ok"] is False
    assert "malformed" in result["error"]


def test_query_model_read_error():
    def handler(request):
        raise httpx.ReadError("connection reset", request=request)

    client = _client_with_transport(handler)
    result = server._query_model("hi", client=client)
    assert result["ok"] is False
    assert "error" in result


def test_local_model_status_server_up(monkeypatch, tmp_path):
    (tmp_path / "Qwen3-8B-Q4_K_M.gguf").touch()
    (tmp_path / "Gemma-4-12B.gguf").touch()
    monkeypatch.setattr(server, "MODELS_DIR", tmp_path)
    monkeypatch.setattr(server, "_get_loaded_model", lambda: "Qwen3-8B-Q4_K_M.gguf")

    result = server.local_model_status()
    assert "Qwen3-8B-Q4_K_M.gguf" in result
    assert "Gemma-4-12B.gguf" in result


def test_local_model_status_server_down(monkeypatch, tmp_path):
    monkeypatch.setattr(server, "MODELS_DIR", tmp_path)
    monkeypatch.setattr(server, "_get_loaded_model", lambda: None)

    result = server.local_model_status()
    assert "not running" in result
