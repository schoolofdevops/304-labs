#!/usr/bin/env python3
"""Lightweight LLM inference simulator for M9 lab.

Simulates an OpenAI-compatible /v1/completions endpoint with:
- Token-by-token SSE streaming
- Simulated TTFT proportional to prompt length (prefill)
- Constant inter-token latency (decode)
- KV cache tracking
- Prometheus-format /metrics endpoint
- Configurable concurrency limit with request queuing

Deploy via ConfigMap + Deployment on core-internals.
No GPU, no model weights — pure simulation of inference behavior.
"""

import http.server
import json
import os
import threading
import time
import random
import string
from collections import deque
from urllib.parse import urlparse

MODEL_NAME = os.environ.get("MODEL_NAME", "sim-llm-7b")
MAX_TOKENS = int(os.environ.get("MAX_TOKENS", "256"))
BASE_TTFT_MS = int(os.environ.get("BASE_TTFT_MS", "80"))
TTFT_PER_TOKEN_MS = float(os.environ.get("TTFT_PER_TOKEN_MS", "0.5"))
ITL_MS = int(os.environ.get("ITL_MS", "25"))
KV_CACHE_SLOTS = int(os.environ.get("KV_CACHE_SLOTS", "32"))
CONCURRENCY_LIMIT = int(os.environ.get("CONCURRENCY_LIMIT", "4"))
PORT = int(os.environ.get("PORT", "8080"))

lock = threading.Lock()
metrics = {
    "requests_total": 0,
    "requests_active": 0,
    "requests_queued": 0,
    "tokens_generated_total": 0,
    "ttft_sum_seconds": 0.0,
    "ttft_count": 0,
    "itl_sum_seconds": 0.0,
    "itl_count": 0,
    "kv_cache_used": 0,
    "kv_cache_total": KV_CACHE_SLOTS,
    "errors_total": 0,
}

active_semaphore = threading.Semaphore(CONCURRENCY_LIMIT)
queue_cv = threading.Condition(lock)


def estimate_prompt_tokens(prompt):
    return max(1, len(prompt.split()))


def generate_word():
    length = random.randint(2, 8)
    return "".join(random.choices(string.ascii_lowercase, k=length))


def generate_response_tokens(max_tokens):
    count = min(max_tokens, random.randint(max_tokens // 2, max_tokens))
    tokens = []
    for i in range(count):
        if i % 6 == 0 and i > 0:
            tokens.append(". " + generate_word().capitalize())
        elif i % 12 == 0 and i > 0:
            tokens.append(".\n" + generate_word().capitalize())
        else:
            tokens.append(" " + generate_word())
    return tokens


class InferenceHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/metrics":
            self.send_metrics()
        elif path == "/health" or path == "/healthz":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"status": "ok", "model": MODEL_NAME}).encode())
        elif path == "/v1/models":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({
                "data": [{"id": MODEL_NAME, "object": "model"}]
            }).encode())
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        path = urlparse(self.path).path
        if path == "/v1/completions":
            self.handle_completions()
        elif path == "/v1/chat/completions":
            self.handle_chat_completions()
        else:
            self.send_response(404)
            self.end_headers()

    def handle_completions(self):
        try:
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length)) if length > 0 else {}
        except (json.JSONDecodeError, ValueError):
            self.send_response(400)
            self.end_headers()
            return

        prompt = body.get("prompt", "Hello")
        max_tok = min(body.get("max_tokens", MAX_TOKENS), MAX_TOKENS)
        stream = body.get("stream", False)

        self._do_inference(prompt, max_tok, stream, is_chat=False)

    def handle_chat_completions(self):
        try:
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length)) if length > 0 else {}
        except (json.JSONDecodeError, ValueError):
            self.send_response(400)
            self.end_headers()
            return

        messages = body.get("messages", [{"role": "user", "content": "Hello"}])
        prompt = " ".join(m.get("content", "") for m in messages)
        max_tok = min(body.get("max_tokens", MAX_TOKENS), MAX_TOKENS)
        stream = body.get("stream", False)

        self._do_inference(prompt, max_tok, stream, is_chat=True)

    def _do_inference(self, prompt, max_tok, stream, is_chat):
        prompt_tokens = estimate_prompt_tokens(prompt)
        cache_slots_needed = max(1, prompt_tokens // 8)

        with lock:
            metrics["requests_total"] += 1
            metrics["requests_queued"] += 1

        acquired = active_semaphore.acquire(timeout=30)
        with lock:
            metrics["requests_queued"] = max(0, metrics["requests_queued"] - 1)

        if not acquired:
            with lock:
                metrics["errors_total"] += 1
            self.send_response(503)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({
                "error": {"message": "Server overloaded", "type": "server_error"}
            }).encode())
            return

        with lock:
            metrics["requests_active"] += 1
            allocated = min(cache_slots_needed, metrics["kv_cache_total"] - metrics["kv_cache_used"])
            metrics["kv_cache_used"] += allocated

        try:
            ttft = (BASE_TTFT_MS + prompt_tokens * TTFT_PER_TOKEN_MS) / 1000.0
            itl = ITL_MS / 1000.0

            time.sleep(ttft)
            with lock:
                metrics["ttft_sum_seconds"] += ttft
                metrics["ttft_count"] += 1

            response_tokens = generate_response_tokens(max_tok)

            if stream:
                self._stream_response(response_tokens, itl, prompt_tokens, is_chat)
            else:
                self._batch_response(response_tokens, itl, prompt_tokens, is_chat)

        finally:
            with lock:
                metrics["requests_active"] -= 1
                metrics["kv_cache_used"] = max(0, metrics["kv_cache_used"] - allocated)
            active_semaphore.release()

    def _stream_response(self, tokens, itl, prompt_tokens, is_chat):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()

        req_id = f"sim-{int(time.time()*1000)}"
        for i, tok in enumerate(tokens):
            time.sleep(itl)
            with lock:
                metrics["tokens_generated_total"] += 1
                metrics["itl_sum_seconds"] += itl
                metrics["itl_count"] += 1

            if is_chat:
                chunk = {
                    "id": req_id,
                    "object": "chat.completion.chunk",
                    "model": MODEL_NAME,
                    "choices": [{"index": 0, "delta": {"content": tok}, "finish_reason": None}],
                }
            else:
                chunk = {
                    "id": req_id,
                    "object": "text_completion",
                    "model": MODEL_NAME,
                    "choices": [{"index": 0, "text": tok, "finish_reason": None}],
                }

            if i == len(tokens) - 1:
                chunk["choices"][0]["finish_reason"] = "stop"
                chunk["usage"] = {
                    "prompt_tokens": prompt_tokens,
                    "completion_tokens": len(tokens),
                    "total_tokens": prompt_tokens + len(tokens),
                }

            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
            self.wfile.flush()

        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

    def _batch_response(self, tokens, itl, prompt_tokens, is_chat):
        total_text = ""
        for tok in tokens:
            time.sleep(itl)
            total_text += tok
            with lock:
                metrics["tokens_generated_total"] += 1
                metrics["itl_sum_seconds"] += itl
                metrics["itl_count"] += 1

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()

        if is_chat:
            resp = {
                "id": f"sim-{int(time.time()*1000)}",
                "object": "chat.completion",
                "model": MODEL_NAME,
                "choices": [{"index": 0, "message": {"role": "assistant", "content": total_text.strip()}, "finish_reason": "stop"}],
                "usage": {"prompt_tokens": prompt_tokens, "completion_tokens": len(tokens), "total_tokens": prompt_tokens + len(tokens)},
            }
        else:
            resp = {
                "id": f"sim-{int(time.time()*1000)}",
                "object": "text_completion",
                "model": MODEL_NAME,
                "choices": [{"index": 0, "text": total_text.strip(), "finish_reason": "stop"}],
                "usage": {"prompt_tokens": prompt_tokens, "completion_tokens": len(tokens), "total_tokens": prompt_tokens + len(tokens)},
            }

        self.wfile.write(json.dumps(resp).encode())

    def send_metrics(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.end_headers()

        with lock:
            m = dict(metrics)
            avg_ttft = m["ttft_sum_seconds"] / m["ttft_count"] if m["ttft_count"] > 0 else 0
            avg_itl = m["itl_sum_seconds"] / m["itl_count"] if m["itl_count"] > 0 else 0
            cache_pct = m["kv_cache_used"] / m["kv_cache_total"] if m["kv_cache_total"] > 0 else 0

        lines = [
            f'# HELP inference_requests_total Total inference requests received.',
            f'# TYPE inference_requests_total counter',
            f'inference_requests_total {m["requests_total"]}',
            f'# HELP inference_requests_active Currently processing requests.',
            f'# TYPE inference_requests_active gauge',
            f'inference_requests_active {m["requests_active"]}',
            f'# HELP inference_queue_depth Requests waiting for a processing slot.',
            f'# TYPE inference_queue_depth gauge',
            f'inference_queue_depth {m["requests_queued"]}',
            f'# HELP inference_tokens_generated_total Total tokens generated.',
            f'# TYPE inference_tokens_generated_total counter',
            f'inference_tokens_generated_total {m["tokens_generated_total"]}',
            f'# HELP inference_ttft_seconds Average time to first token.',
            f'# TYPE inference_ttft_seconds gauge',
            f'inference_ttft_seconds {avg_ttft:.4f}',
            f'# HELP inference_itl_seconds Average inter-token latency.',
            f'# TYPE inference_itl_seconds gauge',
            f'inference_itl_seconds {avg_itl:.4f}',
            f'# HELP inference_kv_cache_utilization KV cache utilization (0-1).',
            f'# TYPE inference_kv_cache_utilization gauge',
            f'inference_kv_cache_utilization {cache_pct:.4f}',
            f'# HELP inference_kv_cache_used_slots KV cache slots currently in use.',
            f'# TYPE inference_kv_cache_used_slots gauge',
            f'inference_kv_cache_used_slots {m["kv_cache_used"]}',
            f'# HELP inference_kv_cache_total_slots Total KV cache slots.',
            f'# TYPE inference_kv_cache_total_slots gauge',
            f'inference_kv_cache_total_slots {m["kv_cache_total"]}',
            f'# HELP inference_errors_total Total errors (503s, timeouts).',
            f'# TYPE inference_errors_total counter',
            f'inference_errors_total {m["errors_total"]}',
            "",
        ]
        self.wfile.write("\n".join(lines).encode())


class ThreadedHTTPServer(http.server.HTTPServer):
    allow_reuse_address = True

    def process_request(self, request, client_address):
        t = threading.Thread(target=self.process_request_thread, args=(request, client_address))
        t.daemon = True
        t.start()

    def process_request_thread(self, request, client_address):
        try:
            self.finish_request(request, client_address)
        except Exception:
            self.handle_error(request, client_address)
        finally:
            self.shutdown_request(request)


if __name__ == "__main__":
    server = ThreadedHTTPServer(("0.0.0.0", PORT), InferenceHandler)
    print(f"Inference simulator started: model={MODEL_NAME} port={PORT} "
          f"concurrency={CONCURRENCY_LIMIT} kv_slots={KV_CACHE_SLOTS} "
          f"ttft_base={BASE_TTFT_MS}ms itl={ITL_MS}ms")
    server.serve_forever()
