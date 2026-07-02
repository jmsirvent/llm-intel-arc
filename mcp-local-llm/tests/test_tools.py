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


def test_query_model_empty_content_without_reasoning():
    def handler(request):
        return httpx.Response(
            200,
            json={
                "choices": [{"message": {"content": ""}}],
                "model": "Qwen3-8B-Q4_K_M.gguf",
            },
        )

    client = _client_with_transport(handler)
    result = server._query_model("hi", client=client)
    assert result["ok"] is False
    assert "empty" in result["error"].lower()
    assert "--skip-chat-parsing" not in result["error"]


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
    assert "python" in (captured["system"] or "")


def test_second_opinion_success(monkeypatch):
    captured = {}

    def fake(prompt, system=None, max_tokens=server.DEFAULT_MAX_TOKENS, temperature=0.7):
        captured["prompt"] = prompt
        captured["system"] = system
        return {"ok": True, "content": "I'd also consider X", "model": "Ornith-1.0-9b-Q6_K.gguf"}

    monkeypatch.setattr(server, "_query_model", fake)
    result = server.second_opinion("should I use a mutex here?", context="single-writer queue")
    assert "I'd also consider X" in result
    assert "single-writer queue" in captured["prompt"] or "single-writer queue" in (captured["system"] or "")


def test_summarize_error_passthrough(monkeypatch):
    monkeypatch.setattr(server, "_query_model", _fake_query_model(ok=False, error="llama-server is not running"))
    result = server.summarize("text")
    assert "not running" in result


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


def test_switch_model_popen_launch_failure(monkeypatch, tmp_path):
    (tmp_path / "Qwen3-8B-Q4_K_M.gguf").touch()
    monkeypatch.setattr(server, "MODELS_DIR", tmp_path)
    monkeypatch.setattr(server, "_find_port_8080_pids", lambda: [])
    monkeypatch.setattr(server, "_terminate_pids", lambda pids: None)

    def fake_popen(args, **kwargs):
        raise FileNotFoundError("no such file or directory")

    monkeypatch.setattr(server.subprocess, "Popen", fake_popen)

    result = server.switch_model("Qwen3-8B-Q4_K_M.gguf")
    assert isinstance(result, str)
    assert str(server.START_SERVER_SCRIPT) in result
    assert "not found" in result.lower() or "failed to launch" in result.lower()


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
