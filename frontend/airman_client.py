"""
Minimal MCP Streamable HTTP client for pg-airman-mcp.

Why this exists instead of the official `mcp` Python SDK: that SDK requires
Python 3.10+, but this app's venv runs 3.9 (frontend/.venv), and upgrading
the interpreter would risk the four existing demo steps. The Streamable
HTTP transport is just JSON-RPC 2.0 over HTTP, so this talks to it directly
with `requests` (already a dependency) -- no new interpreter, no risk to
anything else in the app.

One AirmanClient instance = one MCP session = one governance "session
token". Create exactly one per Streamlit browser session (see
get_airman_client() in app.py) so every tool call in that session shows up
under the same `airman:<purpose>/<session-short>` application_name in
pg_stat_activity -- that consistency is the whole point of the governance
demo.
"""
import json
import uuid

import requests


MCP_URL = "http://localhost:8011/mcp"


class AirmanMCPError(RuntimeError):
    """Raised for any failure talking to the pg-airman-mcp server, or any
    error the server itself reports -- callers should catch this and show
    st.error() rather than letting Streamlit render a raw traceback."""


class AirmanClient:
    def __init__(self, base_url: str = MCP_URL):
        self.base_url = base_url
        self.session_token = str(uuid.uuid4())
        self._http = requests.Session()
        self._mcp_session_id = None
        self._initialized = False

    def _headers(self):
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        }
        if self._mcp_session_id:
            headers["Mcp-Session-Id"] = self._mcp_session_id
        return headers

    @staticmethod
    def _parse(resp):
        ctype = resp.headers.get("content-type", "")
        if "application/json" in ctype:
            return resp.json()
        # Streamable HTTP may reply with an SSE stream even for a single
        # response; each event's payload is a "data: {...}" line.
        lines = [ln[len("data: "):] for ln in resp.text.splitlines() if ln.startswith("data: ")]
        if not lines:
            raise AirmanMCPError(
                f"Unexpected response ({resp.status_code}, content-type={ctype}): "
                f"{resp.text[:300]}"
            )
        return json.loads(lines[-1])

    def _post(self, payload):
        try:
            return self._http.post(self.base_url, headers=self._headers(), json=payload, timeout=30)
        except requests.exceptions.RequestException as e:
            raise AirmanMCPError(
                f"Could not reach the pg-airman-mcp server at {self.base_url} -- "
                f"is the airman-mcp container running? ({e})"
            ) from e

    def _ensure_initialized(self):
        if self._initialized:
            return
        init_req = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "dpw-mcp-gateway-demo", "version": "1.0"},
                "_meta": {"sessionId": self.session_token},
            },
        }
        resp = self._post(init_req)
        if resp.status_code != 200:
            raise AirmanMCPError(f"initialize failed: HTTP {resp.status_code} -- {resp.text[:300]}")
        self._mcp_session_id = resp.headers.get("mcp-session-id")
        body = self._parse(resp)
        if "error" in body:
            raise AirmanMCPError(f"initialize returned an error: {body['error']}")
        # Required handshake notification; response is fire-and-forget (202).
        self._post({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})
        self._initialized = True

    def call_tool(self, name: str, arguments: dict):
        """Call an MCP tool and return its text content (joined if the
        server split it into multiple text blocks)."""
        self._ensure_initialized()
        req = {
            "jsonrpc": "2.0",
            "id": str(uuid.uuid4()),
            "method": "tools/call",
            "params": {
                "name": name,
                "arguments": arguments,
                "_meta": {"sessionId": self.session_token},
            },
        }
        resp = self._post(req)
        if resp.status_code != 200:
            raise AirmanMCPError(f"{name} failed: HTTP {resp.status_code} -- {resp.text[:300]}")
        body = self._parse(resp)
        if "error" in body:
            raise AirmanMCPError(f"{name} returned an error: {body['error']}")
        result = body.get("result", {})
        if result.get("isError"):
            raise AirmanMCPError(f"{name} reported a tool-level error: {result}")
        texts = [c.get("text", "") for c in result.get("content", []) if c.get("type") == "text"]
        return "\n".join(texts)

    @property
    def session_short(self):
        """Matches the 8-char short-hash Airman uses in application_name."""
        return self.session_token.replace("-", "")[:8]
