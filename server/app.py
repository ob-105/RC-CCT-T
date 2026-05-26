"""Flask REST API for RC-CCT-T turtle remote control."""
from __future__ import annotations

import copy
import os
import threading
import time
from collections import deque
from typing import Any

from flask import Flask, jsonify, request, send_from_directory
from flask_cors import CORS

_STATIC = os.path.join(os.path.dirname(__file__), "static")
app = Flask(__name__, static_folder=_STATIC)
CORS(app)

# ── Shared state ──────────────────────────────────────────────────────────────

_lock = threading.Lock()

_state: dict[str, Any] = {
    "turtle": {
        "connected": False,
        "last_seen": 0.0,
        "position": {"x": 0, "y": 0, "z": 0},
        "facing": "north",
        "fuel": 0,
        "fuel_limit": 0,
        "inventory": [None] * 16,
        "selected_slot": 1,
        "surroundings": {"front": None, "up": None, "down": None},
        "scan": [],
        "last_result": None,
    },
    "base": {
        "connected": False,
        "last_seen": 0.0,
        "player": {
            "name": "",
            "uuid": "",
            "rotation": {"yaw": 0.0, "pitch": 0.0},
            "inventory": [],
            "ender": [],
            "equipment": {},
        },
        "entities": [],
        "blocks": [],
    },
}

_command_queue: deque[dict] = deque()
_command_log: deque[dict] = deque(maxlen=50)


def _alive(last_seen: float, timeout: float = 10.0) -> bool:
    return (time.time() - last_seen) < timeout


# ── Turtle endpoints ──────────────────────────────────────────────────────────

@app.route("/api/turtle/poll", methods=["POST"])
def turtle_poll():
    """Turtle POSTs its current status, receives the next queued command."""
    data = request.get_json(silent=True) or {}
    with _lock:
        _state["turtle"]["last_seen"] = time.time()
        _state["turtle"]["connected"] = True

        for key in (
            "position", "facing", "fuel", "fuel_limit",
            "inventory", "selected_slot", "surroundings",
            "scan", "last_result",
        ):
            if key in data:
                _state["turtle"][key] = data[key]

        cmd = _command_queue.popleft() if _command_queue else None

    return jsonify({"command": cmd})


# ── Base-station endpoints ────────────────────────────────────────────────────

@app.route("/api/base/poll", methods=["POST"])
def base_poll():
    """Base station POSTs introspection / sensor data."""
    data = request.get_json(silent=True) or {}
    with _lock:
        _state["base"]["last_seen"] = time.time()
        _state["base"]["connected"] = True

        if "player" in data:
            _state["base"]["player"].update(data["player"])
        if "entities" in data:
            _state["base"]["entities"] = data["entities"]
        if "blocks" in data:
            _state["base"]["blocks"] = data["blocks"]

    return jsonify({"ok": True})


# ── UI endpoints ──────────────────────────────────────────────────────────────

@app.route("/api/state")
def api_state():
    """Full system snapshot for the web UI."""
    with _lock:
        s = copy.deepcopy(_state)
        queue_len = len(_command_queue)

    now = time.time()
    s["turtle"]["connected"] = _alive(s["turtle"]["last_seen"])
    s["base"]["connected"] = _alive(s["base"]["last_seen"])
    s["queue_length"] = queue_len
    return jsonify(s)


@app.route("/api/command", methods=["POST"])
def api_command():
    """UI enqueues a turtle command."""
    data = request.get_json(silent=True)
    if not data or "action" not in data:
        return jsonify({"error": "missing 'action'"}), 400

    with _lock:
        _command_queue.append(data)
        _command_log.append({"ts": time.time(), **data})
        q = len(_command_queue)

    return jsonify({"ok": True, "queued": q})


@app.route("/api/command/clear", methods=["POST"])
def api_command_clear():
    """Clear all pending commands."""
    with _lock:
        _command_queue.clear()
    return jsonify({"ok": True})


@app.route("/api/command/log")
def api_command_log():
    with _lock:
        log = list(_command_log)
    return jsonify(log)


# ── Static files ──────────────────────────────────────────────────────────────

@app.route("/")
def index():
    return send_from_directory(_STATIC, "index.html")


@app.route("/<path:path>")
def static_catch(path):
    return send_from_directory(_STATIC, path)
