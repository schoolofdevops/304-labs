"""
Lightweight MCP tool server for Kubernetes — M10 Agentic Kubernetes lab.

Implements a simplified MCP protocol (JSON-RPC 2.0 over HTTP) backed by the
pod's mounted ServiceAccount token. Read-only RBAC means get/list succeed
and create/delete return 403 Forbidden — exactly what the lab demonstrates.

Deploy via ConfigMap + python:3.12-slim Deployment.
"""

import json
import os
import ssl
import sys
import urllib.error
import urllib.request
from http.server import HTTPServer, BaseHTTPRequestHandler

SA_TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"
SA_CA_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
SA_NS_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/namespace"
K8S_API = "https://kubernetes.default.svc"
PORT = int(os.environ.get("PORT", "8080"))
SERVER_NAME = os.environ.get("SERVER_NAME", "k8s-mcp-readonly")
SERVER_VERSION = os.environ.get("SERVER_VERSION", "0.1.0")


def _load_sa():
    with open(SA_TOKEN_PATH) as f:
        token = f.read().strip()
    with open(SA_NS_PATH) as f:
        namespace = f.read().strip()
    ctx = ssl.create_default_context(cafile=SA_CA_PATH)
    return token, namespace, ctx


TOKEN, SA_NAMESPACE, SSL_CTX = None, None, None


def _ensure_sa():
    global TOKEN, SA_NAMESPACE, SSL_CTX
    if TOKEN is None:
        TOKEN, SA_NAMESPACE, SSL_CTX = _load_sa()


def k8s_request(path, method="GET", body=None):
    _ensure_sa()
    url = f"{K8S_API}{path}"
    headers = {
        "Authorization": f"Bearer {TOKEN}",
        "Accept": "application/json",
    }
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, context=SSL_CTX) as resp:
            return json.loads(resp.read()), resp.status
    except urllib.error.HTTPError as e:
        try:
            err_body = json.loads(e.read())
        except Exception:
            err_body = {"message": e.reason}
        return err_body, e.code


TOOLS = [
    {
        "name": "list_namespaces",
        "description": "List all namespaces in the cluster",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "list_pods",
        "description": "List pods in a namespace",
        "inputSchema": {
            "type": "object",
            "properties": {
                "namespace": {
                    "type": "string",
                    "description": "Kubernetes namespace (default: all namespaces)",
                }
            },
        },
    },
    {
        "name": "get_pod",
        "description": "Get details of a specific pod",
        "inputSchema": {
            "type": "object",
            "properties": {
                "namespace": {"type": "string", "description": "Pod namespace"},
                "name": {"type": "string", "description": "Pod name"},
            },
            "required": ["namespace", "name"],
        },
    },
    {
        "name": "list_nodes",
        "description": "List cluster nodes with status",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "list_events",
        "description": "List recent events in a namespace",
        "inputSchema": {
            "type": "object",
            "properties": {
                "namespace": {
                    "type": "string",
                    "description": "Namespace (default: all namespaces)",
                }
            },
        },
    },
    {
        "name": "create_pod",
        "description": "Create a pod (requires write permissions)",
        "inputSchema": {
            "type": "object",
            "properties": {
                "namespace": {"type": "string", "description": "Target namespace"},
                "name": {"type": "string", "description": "Pod name"},
                "image": {
                    "type": "string",
                    "description": "Container image",
                    "default": "nginx:alpine",
                },
            },
            "required": ["namespace", "name"],
        },
    },
    {
        "name": "delete_pod",
        "description": "Delete a pod (requires write permissions)",
        "inputSchema": {
            "type": "object",
            "properties": {
                "namespace": {"type": "string", "description": "Pod namespace"},
                "name": {"type": "string", "description": "Pod name"},
            },
            "required": ["namespace", "name"],
        },
    },
]


def tool_list_namespaces(_args):
    data, code = k8s_request("/api/v1/namespaces")
    if code != 200:
        return False, json.dumps(data, indent=2)
    ns_list = [
        {"name": ns["metadata"]["name"], "status": ns["status"]["phase"]}
        for ns in data.get("items", [])
    ]
    return True, json.dumps(ns_list, indent=2)


def tool_list_pods(args):
    ns = args.get("namespace")
    path = f"/api/v1/namespaces/{ns}/pods" if ns else "/api/v1/pods"
    data, code = k8s_request(path)
    if code != 200:
        return False, json.dumps(data, indent=2)
    pods = []
    for pod in data.get("items", []):
        m = pod["metadata"]
        phase = pod.get("status", {}).get("phase", "Unknown")
        pods.append({"namespace": m["namespace"], "name": m["name"], "phase": phase})
    return True, json.dumps(pods, indent=2)


def tool_get_pod(args):
    ns = args.get("namespace", "default")
    name = args.get("name")
    if not name:
        return False, "missing required argument: name"
    data, code = k8s_request(f"/api/v1/namespaces/{ns}/pods/{name}")
    if code != 200:
        return False, json.dumps(data, indent=2)
    m = data["metadata"]
    s = data.get("status", {})
    result = {
        "name": m["name"],
        "namespace": m["namespace"],
        "phase": s.get("phase", "Unknown"),
        "nodeName": s.get("nodeName", "unscheduled"),
        "containers": [
            {
                "name": c["name"],
                "image": c["image"],
                "ready": any(
                    cs.get("ready", False)
                    for cs in s.get("containerStatuses", [])
                    if cs["name"] == c["name"]
                ),
            }
            for c in data.get("spec", {}).get("containers", [])
        ],
        "conditions": [
            {"type": c["type"], "status": c["status"]}
            for c in s.get("conditions", [])
        ],
    }
    return True, json.dumps(result, indent=2)


def tool_list_nodes(_args):
    data, code = k8s_request("/api/v1/nodes")
    if code != 200:
        return False, json.dumps(data, indent=2)
    nodes = []
    for node in data.get("items", []):
        m = node["metadata"]
        conditions = node.get("status", {}).get("conditions", [])
        ready = next(
            (c["status"] for c in conditions if c["type"] == "Ready"), "Unknown"
        )
        roles = [
            l.replace("node-role.kubernetes.io/", "")
            for l in m.get("labels", {})
            if l.startswith("node-role.kubernetes.io/")
        ]
        nodes.append(
            {"name": m["name"], "ready": ready, "roles": roles or ["worker"]}
        )
    return True, json.dumps(nodes, indent=2)


def tool_list_events(args):
    ns = args.get("namespace")
    path = f"/api/v1/namespaces/{ns}/events" if ns else "/api/v1/events"
    data, code = k8s_request(path)
    if code != 200:
        return False, json.dumps(data, indent=2)
    events = []
    for ev in data.get("items", [])[-20:]:
        events.append(
            {
                "type": ev.get("type", "Normal"),
                "reason": ev.get("reason", ""),
                "message": ev.get("message", ""),
                "involvedObject": ev.get("involvedObject", {}).get("name", ""),
                "count": ev.get("count", 1),
            }
        )
    return True, json.dumps(events, indent=2)


def tool_create_pod(args):
    ns = args.get("namespace", "default")
    name = args.get("name")
    image = args.get("image", "nginx:alpine")
    if not name:
        return False, "missing required argument: name"
    pod_manifest = {
        "apiVersion": "v1",
        "kind": "Pod",
        "metadata": {"name": name, "namespace": ns},
        "spec": {"containers": [{"name": "main", "image": image}]},
    }
    data, code = k8s_request(f"/api/v1/namespaces/{ns}/pods", method="POST", body=pod_manifest)
    if code in (200, 201):
        return True, json.dumps({"created": name, "namespace": ns})
    return False, json.dumps(data, indent=2)


def tool_delete_pod(args):
    ns = args.get("namespace", "default")
    name = args.get("name")
    if not name:
        return False, "missing required argument: name"
    data, code = k8s_request(f"/api/v1/namespaces/{ns}/pods/{name}", method="DELETE")
    if code == 200:
        return True, json.dumps({"deleted": name, "namespace": ns})
    return False, json.dumps(data, indent=2)


TOOL_HANDLERS = {
    "list_namespaces": tool_list_namespaces,
    "list_pods": tool_list_pods,
    "get_pod": tool_get_pod,
    "list_nodes": tool_list_nodes,
    "list_events": tool_list_events,
    "create_pod": tool_create_pod,
    "delete_pod": tool_delete_pod,
}


def handle_initialize(_params):
    return {
        "protocolVersion": "2025-03-26",
        "capabilities": {"tools": {"listChanged": False}},
        "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
    }


def handle_tools_list(_params):
    return {"tools": TOOLS}


def handle_tools_call(params):
    name = params.get("name")
    args = params.get("arguments", {})
    handler = TOOL_HANDLERS.get(name)
    if not handler:
        return {"content": [{"type": "text", "text": f"unknown tool: {name}"}], "isError": True}
    success, text = handler(args)
    return {"content": [{"type": "text", "text": text}], "isError": not success}


MCP_METHODS = {
    "initialize": handle_initialize,
    "tools/list": handle_tools_list,
    "tools/call": handle_tools_call,
}


class MCPHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"ok")
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        if self.path != "/mcp":
            self.send_response(404)
            self.end_headers()
            return
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        try:
            req = json.loads(raw)
        except json.JSONDecodeError:
            self._jsonrpc_error(None, -32700, "Parse error")
            return

        method = req.get("method")
        req_id = req.get("id")
        params = req.get("params", {})

        handler = MCP_METHODS.get(method)
        if not handler:
            self._jsonrpc_error(req_id, -32601, f"Method not found: {method}")
            return

        result = handler(params)
        self._jsonrpc_result(req_id, result)

    def _jsonrpc_result(self, req_id, result):
        resp = {"jsonrpc": "2.0", "id": req_id, "result": result}
        body = json.dumps(resp).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _jsonrpc_error(self, req_id, code, message):
        resp = {"jsonrpc": "2.0", "id": req_id, "error": {"code": code, "message": message}}
        body = json.dumps(resp).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        sys.stderr.write(f"[mcp-server] {fmt % args}\n")


if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", PORT), MCPHandler)
    print(f"MCP tool server listening on :{PORT} (SA namespace: pending)", flush=True)
    server.serve_forever()
