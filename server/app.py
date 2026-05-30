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
        "last_result": None,
        "map_size": 0,
        "has_scanner": False,
    },
    "base": {
        "connected": False,
        "last_seen": 0.0,
        "base_pos": {"x": 0, "y": 0, "z": 0},
        "entities": [],
        "player": {},
    },
}

# Persistent world map: "x,y,z" -> {name, x, y, z}
# Populated by block_delta from the turtle and base station.
_world_map: dict[str, dict] = {}

_command_queue: deque[dict] = deque()
_command_log: deque[dict] = deque(maxlen=50)


def _alive(last_seen: float, timeout: float = 10.0) -> bool:
    return (time.time() - last_seen) < timeout


def _merge_block_delta(delta: list[dict]) -> None:
    """Merge a block delta list into the world map (call under _lock)."""
    for block in delta:
        key = f"{block['x']},{block['y']},{block['z']}"
        if block.get("air"):
            _world_map.pop(key, None)
        elif block.get("name"):
            _world_map[key] = {
                "name": block["name"],
                "x": block["x"],
                "y": block["y"],
                "z": block["z"],
            }


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
            "entities", "last_result", "map_size",
            "has_scanner", "has_sensor",
        ):
            if key in data:
                _state["turtle"][key] = data[key]

        if "block_delta" in data and isinstance(data["block_delta"], list):
            _merge_block_delta(data["block_delta"])

        cmd = _command_queue.popleft() if _command_queue else None

    return jsonify({"command": cmd})


# ── Base-station endpoints ────────────────────────────────────────────────────

@app.route("/api/base/poll", methods=["POST"])
def base_poll():
    """Base station POSTs scanner block data (already in world coordinates)."""
    data = request.get_json(silent=True) or {}
    with _lock:
        _state["base"]["last_seen"] = time.time()
        _state["base"]["connected"] = True

        if "base_pos" in data:
            _state["base"]["base_pos"] = data["base_pos"]
        if "entities" in data:
            _state["base"]["entities"] = data["entities"]
        if "player" in data:
            _state["base"]["player"] = data["player"]

        if "block_delta" in data and isinstance(data["block_delta"], list):
            _merge_block_delta(data["block_delta"])

    return jsonify({"ok": True})


# ── UI endpoints ──────────────────────────────────────────────────────────────

@app.route("/api/state")
def api_state():
    """Full system snapshot for the web UI (no world map — use /api/worldmap)."""
    with _lock:
        s = copy.deepcopy(_state)
        queue_len = len(_command_queue)

    now = time.time()
    s["turtle"]["connected"] = _alive(s["turtle"]["last_seen"])
    s["base"]["connected"]   = _alive(s["base"]["last_seen"])
    s["queue_length"] = queue_len
    s["world_map_size"] = len(_world_map)
    return jsonify(s)


@app.route("/api/worldmap")
def api_worldmap():
    """
    Return blocks from the world map near the turtle's current position.
    Optional query params: cx,cy,cz (center), radius (default 32).
    """
    cx = int(request.args.get("cx", 0))
    cy = int(request.args.get("cy", 0))
    cz = int(request.args.get("cz", 0))
    radius = int(request.args.get("radius", 32))

    with _lock:
        # Use turtle position as default center
        tp = _state["turtle"]["position"]
        if not request.args.get("cx"):
            cx, cy, cz = tp.get("x", 0), tp.get("y", 0), tp.get("z", 0)
        blocks = [
            b for b in _world_map.values()
            if abs(b["x"] - cx) <= radius
            and abs(b["y"] - cy) <= radius
            and abs(b["z"] - cz) <= radius
        ]

    return jsonify(blocks)


@app.route("/api/worldmap/clear", methods=["POST"])
def api_worldmap_clear():
    """Wipe the server-side world map."""
    with _lock:
        _world_map.clear()
    return jsonify({"ok": True})


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
    with _lock:
        _command_queue.clear()
    return jsonify({"ok": True})


# ── Static files ──────────────────────────────────────────────────────────────

@app.route("/")
def index():
    return send_from_directory(_STATIC, "index.html")

@app.route("/<path:path>")
def static_catch(path):
    return send_from_directory(_STATIC, path)
