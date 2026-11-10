#!/usr/bin/env python3
"""vc-bridge — local bridge between the Vesktop Vencord plugin and noctalia.

The Vencord userplugin (`VesktopVCBridge`) connects to this daemon over a
WebSocket and pushes voice-channel snapshots + heartbeats. The daemon keeps a
public state file (`~/.cache/vc-bridge/state.json`) for the noctalia bar
widget, caches member avatars, and forwards control commands back to the
plugin (mute, deafen, start/stop screen share).

Run it with `vcb serve` (or the `vc-bridge.service` systemd user unit).
"""
from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import os
import time
from pathlib import Path

TABLER_FONT = "/usr/share/noctalia/assets/fonts/noctalia-tabler.ttf"
TABLER_JSON = "/usr/share/noctalia/assets/fonts/tabler.json"
AVATAR_SIZE = 128


def load_tabler_codepoints() -> dict[str, int]:
    try:
        data = json.load(open(TABLER_JSON, "r", encoding="utf-8"))
        out = {}
        for name, info in data.items():
            cp = info.get("codepoint") if isinstance(info, dict) else None
            if not cp:
                continue
            try:
                out[name] = int(cp.replace("U+", ""), 16)
            except ValueError:
                continue
        return out
    except OSError:
        return {}


TABLER_CODEPOINTS = load_tabler_codepoints()

from aiohttp import ClientSession, ClientTimeout, web

CACHE_DIR = Path(os.path.expanduser("~/.cache/vc-bridge"))
STATE_FILE = CACHE_DIR / "state.json"
AVATAR_DIR = CACHE_DIR / "avatars"
LOG_FILE = Path(os.path.expanduser("~/.local/state/vc-bridge/bridge.log"))

SPEAKING_STICKY_SECONDS = 1.6
LEVEL_FRESH_SECONDS = 0.6
LEVEL_HISTORY = 8
PLUGIN_STALE_SECONDS = 20.0
ALLOWED_COMMANDS = {"toggle_mute", "toggle_deafen", "start_stream", "stop_stream", "local_mute", "local_volume", "debug_eval"}


def log(message: str) -> None:
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} {message}"
    print(line, flush=True)
    try:
        LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        with LOG_FILE.open("a", encoding="utf-8") as fh:
            fh.write(line + "\n")
        if LOG_FILE.stat().st_size > 2 * 1024 * 1024:
            os.replace(LOG_FILE, str(LOG_FILE) + ".1")
    except OSError:
        pass


def now() -> float:
    return time.time()


class Bridge:
    def __init__(self) -> None:
        self.plugin_ws: web.WebSocketResponse | None = None
        self.plugin_last_msg = 0.0
        self.last_snapshot: dict = {}
        self.speaking_until: dict[str, float] = {}
        self.level_last: dict[str, tuple[float, float]] = {}
        self.level_history: dict[str, list[float]] = {}
        self.last_write = 0.0
        self.avatar_urls: dict[str, str] = {}
        self.avatar_tasks: dict[str, asyncio.Task] = {}
        self.public: dict = {}
        self.public_serialized = ""
        self.http: ClientSession | None = None
        self.command_seq = 0
        self.last_result: dict = {}

    # -- plugin connection -------------------------------------------------

    async def handle_plugin(self, request: web.Request) -> web.WebSocketResponse:
        ws = web.WebSocketResponse(heartbeat=30)
        await ws.prepare(request)
        self.plugin_ws = ws
        self.plugin_last_msg = now()
        log("plugin connected")
        await self.publish(force=True)

        try:
            async for message in ws:
                if message.type != web.WSMsgType.TEXT:
                    continue
                self.plugin_last_msg = now()
                try:
                    payload = json.loads(message.data)
                except ValueError:
                    continue
                await self.on_plugin_message(payload)
        finally:
            if self.plugin_ws is ws:
                self.plugin_ws = None
            log("plugin disconnected")
            self.speaking_until.clear()
            await self.publish(force=True)
        return ws

    async def on_plugin_message(self, payload: dict) -> None:
        kind = payload.get("type")
        if kind == "ping":
            return
        if kind == "levels":
            for user_id, raw in (payload.get("levels") or {}).items():
                try:
                    value = max(0.0, min(1.0, float(raw)))
                except (TypeError, ValueError):
                    continue
                self.level_last[user_id] = (value, now())
                history = self.level_history.setdefault(user_id, [])
                history.append(round(value, 3))
                del history[:-LEVEL_HISTORY]
            await self.publish()
            return

        if kind == "state":
            self.last_snapshot = payload
            for member in [*(payload.get("members") or []), payload.get("self") or {}]:
                user_id = member.get("userId")
                if not user_id:
                    continue
                if member.get("speaking"):
                    self.speaking_until[user_id] = now() + SPEAKING_STICKY_SECONDS
            await self.publish()
        elif kind == "cmd_result":
            self.last_result = dict(payload, received_at=now())
            log(f"plugin cmd_result {payload.get('cmd')}: ok={payload.get('ok')} {payload.get('error', '')}")

    # -- public state ------------------------------------------------------

    def build_public(self) -> dict:
        snapshot = self.last_snapshot or {}
        now_ts = now()
        plugin_connected = self.plugin_ws is not None and (now_ts - self.plugin_last_msg) < PLUGIN_STALE_SECONDS

        self.speaking_until = {k: v for k, v in self.speaking_until.items() if v > now_ts}

        def decorate(member: dict) -> dict:
            user_id = member.get("userId", "")
            out = dict(member)
            out["speaking"] = bool(member.get("speaking")) or user_id in self.speaking_until
            url = out.get("avatar")
            path = self.avatar_urls.get(user_id)
            if path and not os.path.exists(path):
                self.avatar_urls.pop(user_id, None)
                path = None
            out["avatar_path"] = path if url else None
            level, seen = self.level_last.get(user_id, (0.0, 0.0))
            if now_ts - seen > LEVEL_FRESH_SECONDS:
                level = 0.0
            out["level"] = round(level, 3)
            out["levels"] = list(self.level_history.get(user_id, []))
            return out

        self_member = decorate(snapshot.get("self") or {}) if snapshot.get("self") else None
        members = [decorate(m) for m in (snapshot.get("members") or []) if m.get("userId")]

        channel = snapshot.get("channel")
        connected = bool(plugin_connected and channel and self_member and self_member.get("userId"))

        return {
            "ok": True,
            "connected": connected,
            "plugin": {
                "connected": self.plugin_ws is not None,
                "last_msg_at": self.plugin_last_msg,
            },
            "channel": channel if connected else None,
            "self": self_member,
            "members": members if connected else [],
            "speaking": [m["userId"] for m in members if m.get("speaking")],
            "updated_at": now_ts,
        }

    async def publish(self, force: bool = False) -> None:
        public = self.build_public()
        public["updated_at"] = public["updated_at"] if not force else public["updated_at"]
        serialized = json.dumps(public, sort_keys=True)
        if not force and serialized == self.public_serialized:
            return
        if not force and now() - self.last_write < 0.12:
            return
        self.last_write = now()
        self.public = public
        self.public_serialized = serialized
        self.write_state(public)

    def write_state(self, public: dict) -> None:
        try:
            CACHE_DIR.mkdir(parents=True, exist_ok=True)
            tmp = CACHE_DIR / f".state-{os.getpid()}.json"
            tmp.write_text(json.dumps(public), encoding="utf-8")
            os.replace(tmp, STATE_FILE)
        except OSError as exc:
            log(f"could not write state: {exc}")

    # -- avatars -----------------------------------------------------------

    async def refresh_avatars(self) -> None:
        snapshot = self.last_snapshot or {}
        pending = [snapshot.get("self") or {}, *(snapshot.get("members") or [])]
        for member in pending:
            user_id = member.get("userId")
            url = member.get("avatar")
            if not user_id or not url:
                continue
            target = AVATAR_DIR / self.avatar_filename(user_id, url, member)
            if self.avatar_urls.get(user_id) == str(target) and target.exists():
                continue
            if user_id in self.avatar_tasks and not self.avatar_tasks[user_id].done():
                continue
            self.avatar_tasks[user_id] = asyncio.create_task(self.download_avatar(user_id, url, member))

    @staticmethod
    def avatar_state_key(member: dict) -> str:
        flags = (
            member.get("mute"),
            member.get("deaf"),
            member.get("serverMute"),
            member.get("serverDeaf"),
            member.get("streaming"),
        )
        return "".join("1" if flag else "0" for flag in flags)

    @classmethod
    def avatar_filename(cls, user_id: str, url: str, member: dict) -> str:
        digest = hashlib.sha1(url.encode()).hexdigest()[:8]
        return f"{user_id}-{digest}-{cls.avatar_state_key(member)}.png"

    @staticmethod
    def raw_avatar_filename(user_id: str, url: str) -> str:
        digest = hashlib.sha1(url.encode()).hexdigest()[:8]
        return f"{user_id}-{digest}.raw"

    @staticmethod
    def compose_avatar(raw_path: Path, target_path: Path, member: dict) -> bool:
        """Draw the mute/deafen/streaming badges onto the bottom of the pfp."""
        try:
            from PIL import Image, ImageDraw, ImageFont
        except Exception:  # noqa: BLE001
            return False

        badges = []
        if member.get("serverMute"):
            badges.append(("microphone-off", (235, 87, 87, 255)))
        elif member.get("mute"):
            badges.append(("microphone-off", (230, 230, 230, 255)))
        if member.get("serverDeaf"):
            badges.append(("headphones-off", (235, 87, 87, 255)))
        elif member.get("deaf"):
            badges.append(("headphones-off", (230, 230, 230, 255)))
        if not badges and member.get("streaming"):
            badges.append(("screen-share", (130, 200, 255, 255)))

        try:
            image = Image.open(raw_path).convert("RGBA")
        except Exception:  # noqa: BLE001
            return False
        image = image.resize((AVATAR_SIZE, AVATAR_SIZE), Image.LANCZOS)

        if badges:
            count = len(badges)
            diameter = 54 if count <= 2 else 40
            gap = 4
            total = count * diameter + (count - 1) * gap
            x0 = AVATAR_SIZE - total - 2
            y0 = AVATAR_SIZE - diameter - 2
            draw = ImageDraw.Draw(image)
            try:
                font = ImageFont.truetype(TABLER_FONT, int(diameter * 0.72))
            except OSError:
                font = None
            for index, (name, color) in enumerate(badges):
                cx = x0 + index * (diameter + gap) + diameter / 2
                cy = y0 + diameter / 2
                draw.ellipse(
                    [cx - diameter / 2, cy - diameter / 2, cx + diameter / 2, cy + diameter / 2],
                    fill=(18, 18, 20, 235),
                )
                codepoint = TABLER_CODEPOINTS.get(name)
                if font is not None and codepoint:
                    draw.text((cx, cy), chr(codepoint), font=font, fill=color, anchor="mm")

        try:
            image.save(target_path, "PNG")
            return True
        except OSError:
            return False

    async def download_avatar(self, user_id: str, url: str, member: dict) -> None:
        filename = self.avatar_filename(user_id, url, member)
        target = AVATAR_DIR / filename
        raw = AVATAR_DIR / self.raw_avatar_filename(user_id, url)
        try:
            AVATAR_DIR.mkdir(parents=True, exist_ok=True)
            if not raw.exists():
                assert self.http is not None
                async with self.http.get(url) as resp:
                    if resp.status != 200:
                        log(f"avatar {user_id}: HTTP {resp.status}")
                        return
                    data = await resp.read()
                tmp = raw.with_suffix(".tmp")
                tmp.write_bytes(data)
                os.replace(tmp, raw)

            composed = await asyncio.to_thread(self.compose_avatar, raw, target, member)
            if not composed:
                tmp = target.with_suffix(".tmp")
                tmp.write_bytes(raw.read_bytes())
                os.replace(tmp, target)

            self.avatar_urls[user_id] = str(target)
            # prune this user's older composed avatars
            for old in AVATAR_DIR.glob(f"{user_id}-*.png"):
                if old.name != filename:
                    old.unlink(missing_ok=True)
            await self.publish(force=True)
        except Exception as exc:  # noqa: BLE001 - avatars must never take the daemon down
            log(f"avatar {user_id} failed: {exc}")

    # -- commands ----------------------------------------------------------

    async def send_command(self, cmd: str, args: dict | None = None) -> tuple[int, dict]:
        if self.plugin_ws is None:
            return 409, {"ok": False, "error": "vesktop plugin not connected"}
        self.command_seq += 1
        payload = {"type": "cmd", "cmd": cmd, "id": self.command_seq, **(args or {})}
        try:
            await self.plugin_ws.send_json(payload)
        except Exception as exc:  # noqa: BLE001
            return 500, {"ok": False, "error": str(exc)}
        log(f"sent command {cmd}")
        return 200, {"ok": True, "cmd": cmd, "id": self.command_seq}


BRIDGE = Bridge()


async def ws_handler(request: web.Request) -> web.WebSocketResponse:
    return await BRIDGE.handle_plugin(request)


async def status_handler(_request: web.Request) -> web.Response:
    return web.json_response(BRIDGE.build_public())


async def health_handler(_request: web.Request) -> web.Response:
    return web.json_response(
        {
            "ok": True,
            "plugin": BRIDGE.plugin_ws is not None,
            "last_msg_at": BRIDGE.plugin_last_msg,
        }
    )


async def cmd_handler(request: web.Request) -> web.Response:
    action = request.match_info.get("action", "")
    if action not in ALLOWED_COMMANDS:
        return web.json_response({"ok": False, "error": f"unknown action {action}"}, status=404)
    args = {}
    try:
        if request.can_read_body:
            body = await request.json()
            if isinstance(body, dict):
                args = body
    except ValueError:
        pass
    status, body = await BRIDGE.send_command(action, args)
    return web.json_response(body, status=status)


async def result_handler(_request: web.Request) -> web.Response:
    return web.json_response(BRIDGE.last_result or {"ok": False, "error": "no result yet"})


async def startup(app: web.Application) -> None:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    AVATAR_DIR.mkdir(parents=True, exist_ok=True)
    BRIDGE.http = ClientSession(timeout=ClientTimeout(total=15))
    log(f"vc-bridge starting on {app['host']}:{app['port']}")
    await BRIDGE.publish(force=True)
    asyncio.create_task(ticker())


async def ticker() -> None:
    while True:
        try:
            now_ts = now()
            for user_id, (_value, seen) in list(BRIDGE.level_last.items()):
                if now_ts - seen > LEVEL_FRESH_SECONDS:
                    BRIDGE.level_last.pop(user_id, None)
                    history = BRIDGE.level_history.setdefault(user_id, [])
                    history.append(0.0)
                    del history[:-LEVEL_HISTORY]
            await BRIDGE.publish()
            await BRIDGE.refresh_avatars()
        except Exception as exc:  # noqa: BLE001
            log(f"ticker error: {exc}")
        await asyncio.sleep(0.5)


async def cleanup(_app: web.Application) -> None:
    if BRIDGE.http is not None:
        await BRIDGE.http.close()


def serve(host: str, port: int) -> None:
    app = web.Application()
    app["host"] = host
    app["port"] = port
    app.router.add_get("/plugin", ws_handler)
    app.router.add_get("/status", status_handler)
    app.router.add_get("/health", health_handler)
    app.router.add_post("/cmd/{action}", cmd_handler)
    app.router.add_get("/result", result_handler)
    app.on_startup.append(startup)
    app.on_cleanup.append(cleanup)
    web.run_app(app, host=host, port=port, print=lambda *args: None, access_log=None)


def main() -> int:
    parser = argparse.ArgumentParser(prog="vc-bridge")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=6475)
    parser.add_argument("--foreground", action="store_true", help="unused; serve always runs in the foreground")
    args = parser.parse_args()
    serve(args.host, args.port)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
