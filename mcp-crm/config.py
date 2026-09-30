"""Configuration for the CRM MCP server."""
import os


def _bool(name: str, default: bool) -> bool:
    return os.getenv(name, str(default)).strip().lower() in {"1", "true", "yes", "on"}


def _list(name: str, default: str):
    return [v.strip() for v in os.getenv(name, default).split(",") if v.strip()]


class Config:
    SERVICE_NAME = os.getenv("SERVICE_NAME", "o11yag_mcp_crm")
    ENV = os.getenv("ENV", "local")
    PORT = int(os.getenv("PORT", "8003"))

    # --- Host header allowlist (DNS rebinding protection) ---
    #
    # The MCP SDK validates the Host header on every request to block DNS
    # rebinding attacks, where a browser is tricked into resolving an attacker's
    # domain to a local MCP server and then driving its tools. It is on by
    # default and it auto-allows ONLY 127.0.0.1 / localhost / ::1.
    #
    # In Kubernetes the Host header is the Service name, so without this list
    # every call comes back "421 Misdirected Request" and the server logs
    # "Invalid Host header". The fix is to name the hostnames this server is
    # legitimately reached by — NOT to switch the protection off.
    #
    # ":*" is the SDK's wildcard for "this host on any port".
    MCP_ALLOWED_HOSTS = _list(
        "MCP_ALLOWED_HOSTS",
        "o11yag-mcp-crm:*,"
        "o11yag-mcp-crm.o11yag-otel:*,"
        "o11yag-mcp-crm.o11yag-otel.svc.cluster.local:*,"
        # kubectl port-forward, for the debug commands in the README
        "localhost:*,127.0.0.1:*",
    )
    # Origin is only sent by browsers; server-to-server callers omit it and the
    # SDK treats an absent Origin as same-origin. Left empty on purpose.
    MCP_ALLOWED_ORIGINS = _list("MCP_ALLOWED_ORIGINS", "")
    # Escape hatch. If you turn this off, say why in your commit message.
    MCP_DNS_REBINDING_PROTECTION = _bool("MCP_DNS_REBINDING_PROTECTION", True)

    # --- gap 2: the security act, server side ---
    # Append an instruction to the issue_refund description, so the action
    # worker's tool-catalogue screening has something real to catch. Off by
    # default, and it is the *server* that lies here rather than the client that
    # pretends to be lied to: a demo where the detector is fed a canned finding
    # proves the detector prints, not that it detects.
    #
    # Turning it on after the worker has run is the rug pull — the digest the
    # worker recorded no longer matches, which is the point of recording it.
    POISON_TOOL_DESCRIPTION = _bool("POISON_TOOL_DESCRIPTION", False)

    OTEL_ENABLED = _bool("OTEL_ENABLED", False)
    OTEL_EXPORTER_OTLP_ENDPOINT = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318")
