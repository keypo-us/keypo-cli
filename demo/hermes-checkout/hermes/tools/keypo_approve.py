"""
Keypo Approve Tool — Hermes agent tool for the Keypo checkout approval flow.

Communicates with keypo-approvald over a Unix domain socket to stage, confirm,
or cancel checkout requests. The daemon handles biometric authentication and
vault exec; the agent never sees card data.
"""

import json
import os
import socket
import uuid


TOOL_NAME = "keypo_approve"
TOOL_DESCRIPTION = (
    "Manage checkout purchase requests through the Keypo approval daemon. "
    "Supports three actions: 'request' (stage a purchase), 'confirm' (execute "
    "with biometric auth), and 'cancel' (abort a staged request)."
)
TOOL_PARAMETERS = {
    "type": "object",
    "properties": {
        "action": {
            "type": "string",
            "enum": ["request", "confirm", "cancel"],
            "description": "The action to perform",
        },
        "request_id": {
            "type": "string",
            "description": "UUID of the request (auto-generated for 'request' action, required for 'confirm'/'cancel')",
        },
        "vault_label": {
            "type": "string",
            "description": "Vault tier to use (e.g., 'biometric'). Required for 'request'.",
        },
        "bio_reason": {
            "type": "string",
            "description": "Text shown in the biometric prompt (e.g., 'Approve purchase: Cookies $39'). Required for 'request'.",
        },
        "manifest": {
            "type": "object",
            "description": "Checkout manifest with product_url, quantity, max_price. Required for 'request'.",
            "properties": {
                "product_url": {"type": "string"},
                "quantity": {"type": "integer"},
                "max_price": {"type": "number"},
            },
        },
    },
    "required": ["action"],
}

DEFAULT_SOCKET_PATH = "/tmp/keypo-approvald.sock"


def run(action: str, request_id: str = None, vault_label: str = None,
        bio_reason: str = None, manifest: dict = None) -> dict:
    """Execute the keypo_approve tool."""
    socket_path = os.environ.get("KEYPO_DAEMON_SOCKET", DEFAULT_SOCKET_PATH)

    # Validate parameters
    if action == "request":
        if not vault_label:
            return {"status": "error", "error": "missing required parameter: vault_label"}
        if not bio_reason:
            return {"status": "error", "error": "missing required parameter: bio_reason"}
        if not manifest:
            return {"status": "error", "error": "missing required parameter: manifest"}
        if not request_id:
            request_id = str(uuid.uuid4())
    elif action in ("confirm", "cancel"):
        if not request_id:
            return {"status": "error", "error": "missing required parameter: request_id"}
    else:
        return {"status": "error", "error": f"unknown action: {action}"}

    # Build message
    message = {"action": action, "request_id": request_id}
    if action == "request":
        message["vault_label"] = vault_label
        message["bio_reason"] = bio_reason
        message["manifest"] = manifest

    # Connect and send
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(300)  # 5 minute timeout for biometric + checkout
        sock.connect(socket_path)
    except FileNotFoundError:
        return {
            "status": "error",
            "error": f"daemon socket not found at {socket_path}. Is keypo-approvald running?",
        }
    except ConnectionRefusedError:
        return {
            "status": "error",
            "error": f"connection refused at {socket_path}. Is keypo-approvald running?",
        }
    except Exception as e:
        return {"status": "error", "error": f"connection failed: {e}"}

    try:
        # Send newline-delimited JSON
        payload = json.dumps(message) + "\n"
        sock.sendall(payload.encode("utf-8"))

        # Read response
        data = b""
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            data += chunk
            if b"\n" in data:
                break

        sock.close()

        if not data.strip():
            return {"status": "error", "error": "empty response from daemon"}

        response = json.loads(data.strip())
        return response

    except socket.timeout:
        sock.close()
        return {"status": "error", "error": "timeout waiting for daemon response"}
    except json.JSONDecodeError as e:
        sock.close()
        return {"status": "error", "error": f"invalid JSON from daemon: {e}"}
    except Exception as e:
        sock.close()
        return {"status": "error", "error": f"communication error: {e}"}
