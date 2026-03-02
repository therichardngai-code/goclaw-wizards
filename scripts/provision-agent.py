#!/usr/bin/env python3
# GoClaw agent + channel provisioning via WebSocket RPC (Protocol v3).
# Python 3.8+, stdlib only. NEVER use agent_type "open". ALWAYS dm_policy "allowlist".
#
# Protocol v3 wire format (pkg/protocol/frames.go):
#   Request:  {"type": "req", "id": "<str>", "method": "<name>", "params": {...}}
#   Response: {"type": "res", "id": "<str>", "ok": bool, "payload": {...}}
#   First request MUST be method="connect" for auth.
#
# Key design constraint:
#   channels.instances.create requires agent_id as a DB UUID (uuid.Parse in server).
#   agents.create WS response only returns the agent key (not UUID).
#   Solution: after WS agents.create, fetch UUID via HTTP GET /v1/agents/{key}.
import argparse, base64, json, os, socket, struct, sys, urllib.request


class _WS:
    """Minimal RFC-6455 WebSocket client — plain TCP, localhost only."""
    def __init__(self, host, port):
        self._s = socket.create_connection((host, port), timeout=30)
        key = base64.b64encode(os.urandom(16)).decode()
        self._s.sendall((
            f"GET /ws HTTP/1.1\r\nHost: {host}:{port}\r\n"
            f"Upgrade: websocket\r\nConnection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
        ).encode())
        resp = b""
        while b"\r\n\r\n" not in resp:
            resp += self._s.recv(4096)
        if b" 101 " not in resp[:64]:
            raise ConnectionError(f"WS handshake failed: {resp[:120].decode(errors='replace')}")

    def _readn(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self._s.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("Socket closed")
            buf += chunk
        return buf

    def send(self, text):
        data = text.encode("utf-8")
        mask = os.urandom(4)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
        n = len(data)
        if   n < 126:   hdr = bytes([0x81, 0x80 | n]) + mask
        elif n < 65536: hdr = bytes([0x81, 0xFE]) + struct.pack(">H", n) + mask
        else:           hdr = bytes([0x81, 0xFF]) + struct.pack(">Q", n) + mask
        self._s.sendall(hdr + masked)

    def recv(self):
        while True:
            b0, b1 = self._readn(1)[0], self._readn(1)[0]
            op, n = b0 & 0x0F, b1 & 0x7F
            if n == 126: n = struct.unpack(">H", self._readn(2))[0]
            elif n == 127: n = struct.unpack(">Q", self._readn(8))[0]
            mkey = self._readn(4) if (b1 & 0x80) else b""
            pl = self._readn(n)
            if mkey: pl = bytes(b ^ mkey[i % 4] for i, b in enumerate(pl))
            if op == 0x9: self._s.sendall(bytes([0x8A, 0x80]) + os.urandom(4)); continue  # pong
            if op == 0x8: raise ConnectionError("Server closed WebSocket")
            return pl.decode("utf-8")

    def close(self):
        try: self._s.sendall(bytes([0x88, 0x80]) + os.urandom(4))
        except Exception: pass
        self._s.close()


class GoclawWS:
    """Protocol v3 WebSocket RPC client for GoClaw gateway."""
    def __init__(self, host, port, token):
        self._ws = _WS(host, port)
        self._id = 0
        # First request MUST be method=connect (server/gateway/router.go)
        r = self.call("connect", {"token": token, "user_id": "wizard"})
        if not r.get("ok"):
            raise RuntimeError(f"Auth failed: {r}")

    def call(self, method, params):
        self._id += 1
        # id MUST be a string — RequestFrame.ID is string in protocol v3
        self._ws.send(json.dumps({"type": "req", "id": str(self._id), "method": method, "params": params}))
        r = json.loads(self._ws.recv())
        if r.get("ok") is False:
            raise RuntimeError(f"{method} failed: {r.get('error', r)}")
        return r

    def close(self): self._ws.close()


def get_agent_uuid(host, port, token, agent_key):
    """Fetch agent DB UUID via HTTP REST GET /v1/agents/{key}.

    agents.create WS returns only the agent key. channels.instances.create
    requires a UUID (server calls uuid.Parse on agent_id). This bridges the gap.
    HTTP handleGet accepts key or UUID: tries uuid.Parse first, falls back to GetByKey.
    """
    req = urllib.request.Request(
        f"http://{host}:{port}/v1/agents/{agent_key}",
        headers={
            "Authorization": f"Bearer {token}",
            # No X-GoClaw-User-Id — empty userID bypasses CanAccess check in handleGet
        }
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read())
    except Exception as e:
        raise RuntimeError(f"Failed to fetch UUID for agent key '{agent_key}': {e}")
    agent_uuid = data.get("id")
    if not agent_uuid:
        raise RuntimeError(f"No 'id' field in agent response for key '{agent_key}': {data}")
    return str(agent_uuid)


def create_agent(ws, name, owner_ids=None):
    """Create predefined agent. Returns agent key as normalised by server.
    owner_ids: list of owner user IDs (PR #34 — makes agent visible in web UI
    for those users via agents.create WS owner_ids param).
    """
    # Note: agent_key param does NOT exist in agents.create — server derives key
    # from name via config.NormalizeAgentID(name). Use returned agentId as key.
    params = {"name": name, "agent_type": "predefined"}
    if owner_ids:
        params["owner_ids"] = owner_ids
    r = ws.call("agents.create", params)
    p = r.get("payload", {})
    return p.get("agentId") or name  # agentId = server-normalised key


def seed_files(ws, agent_key, soul, identity, user=None):
    """Seed SOUL.md, IDENTITY.md, and optionally USER.md.
    agents.files.set uses agentId = agent key (resolves via GetByKey internally).
    """
    for fname, content in [("SOUL.md", soul), ("IDENTITY.md", identity)]:
        ws.call("agents.files.set", {"agentId": agent_key, "name": fname, "content": content})
    if user:
        ws.call("agents.files.set", {"agentId": agent_key, "name": "USER.md", "content": user})


def create_channel(ws, host, port, token, agent_key, ch):
    """Create channel instance for an agent.
    Fetches agent UUID via HTTP because channels.instances.create requires UUID
    (server: uuid.Parse(params.AgentID) in channel_instances.go:handleCreate).
    """
    agent_uuid = get_agent_uuid(host, port, token, agent_key)
    ws.call("channels.instances.create", {
        "name": f"{agent_key}-{ch['type']}",
        "display_name": ch.get("display_name", f"{agent_key} ({ch['type']})"),
        "channel_type": ch["type"],
        "agent_id": agent_uuid,  # must be UUID
        "credentials": ch["credentials"],
        "config": {"dm_policy": "allowlist", "allow_from": ch.get("owner_ids", [])},
        "enabled": True,
    })


def list_channels_for_key(ws, key):
    """List channel instances whose name starts with {key}-."""
    r = ws.call("channels.instances.list", {})
    # Response: {"type":"res","ok":true,"payload":{"instances":[...]}}
    instances = r.get("payload", {}).get("instances", [])
    return [i for i in instances if i.get("name", "").startswith(f"{key}-")]


def list_channels_for_agent_uuid(ws, agent_uuid):
    """List channel instances owned by a specific agent UUID.
    Used instead of name-prefix matching when the auto-onboard names channels
    without the agent-key prefix (e.g. "telegram" instead of "default-telegram").
    """
    r = ws.call("channels.instances.list", {})
    instances = r.get("payload", {}).get("instances", [])
    return [i for i in instances if str(i.get("agent_id", "")) == agent_uuid]


def delete_agent(ws, key):
    """Delete all channel instances for agent, then delete agent.
    agents.delete uses agentId (key), not agentKey (agents.go:handleDelete).
    """
    for inst in list_channels_for_key(ws, key):
        ws.call("channels.instances.delete", {"id": str(inst["id"])})
    ws.call("agents.delete", {"agentId": key})


def purge_default_agent(ws, host, port, token):
    """Remove channel instances owned by GoClaw's auto-onboard default agent.

    Auto-onboard seeds a "default" open-agent + channel instance on container
    first-start BEFORE the wizard runs, using the same bot token the wizard
    will configure — causing duplicate routing to two agents.

    name-prefix matching (list_channels_for_key) misses these instances because
    auto-onboard names them "telegram" not "default-telegram". We must filter by
    agent_id UUID instead.

    agents.delete("default") is blocked by GoClaw ("cannot delete the default
    agent") — channel-instance deletion is the only effective cleanup.
    """
    try:
        default_uuid = get_agent_uuid(host, port, token, "default")
    except Exception:
        return  # default agent not found — nothing to purge
    try:
        for inst in list_channels_for_agent_uuid(ws, default_uuid):
            try:
                ws.call("channels.instances.delete", {"id": str(inst["id"])})
            except Exception:
                pass
    except Exception:
        pass
    # agents.delete will be rejected ("cannot delete the default agent") — silent
    try:
        ws.call("agents.delete", {"agentId": "default"})
    except Exception:
        pass


def main():
    p = argparse.ArgumentParser(description="GoClaw agent provisioning")
    p.add_argument("--action", required=True, choices=["create", "delete", "add-channel", "list-channels", "update-files"])
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--token", required=True)
    p.add_argument("--agent-name")
    p.add_argument("--agent-key")
    p.add_argument("--soul-file")
    p.add_argument("--identity-file")
    p.add_argument("--user-file")
    p.add_argument("--admin-ids", default="",
                   help="Comma-separated admin user IDs — set as agent.owner_id in DB "
                        "so the admin can edit context files in the Web Dashboard. "
                        "Separate from channel owner_ids (allow_from).")
    p.add_argument("--channels-json", default="[]")
    args = p.parse_args()

    ws = GoclawWS(args.host, args.port, args.token)
    try:
        if args.action == "create":
            soul     = open(args.soul_file).read()     if args.soul_file     else ""
            identity = open(args.identity_file).read() if args.identity_file else ""
            user     = open(args.user_file).read()     if args.user_file     else None
            # Pre-delete stale wizard agent from DB (dirty reinstall).
            # Idempotent: if agent doesn't exist, delete_agent returns NOT_FOUND — caught here.
            if args.agent_key:
                try:
                    delete_agent(ws, args.agent_key)
                except Exception:
                    pass  # expected on fresh install

            # Purge GoClaw auto-onboard default agent before creating the wizard's agent.
            # See purge_default_agent() for full explanation.
            if args.agent_key != "default":
                purge_default_agent(ws, args.host, args.port, args.token)
            # agent.owner_id = admin IDs (--admin-ids flag) so the wizard operator can
            # edit context files in the Web Dashboard (frontend: agent.owner_id === userId).
            # Channel owner_ids are used only for channel.allow_from (who can DM the bot).
            # Falls back to channel owner_ids for backward compat when --admin-ids not provided.
            channels = json.loads(args.channels_json)
            if args.admin_ids:
                admin_ids = [i.strip() for i in args.admin_ids.split(",") if i.strip()]
            else:
                # backward compat: no --admin-ids → derive from channels (old behaviour)
                admin_ids = list(dict.fromkeys(
                    oid for ch in channels
                    for oid in ch.get("owner_ids", [])
                    if oid
                ))
            # Server derives key from name via NormalizeAgentID; use returned key for all calls
            agent_key = create_agent(ws, args.agent_name, owner_ids=admin_ids or None)
            seed_files(ws, agent_key, soul, identity, user)
            for ch in channels:
                create_channel(ws, args.host, args.port, args.token, agent_key, ch)
            print(json.dumps({"ok": True, "agent_id": agent_key}))

        elif args.action == "delete":
            delete_agent(ws, args.agent_key)
            print(json.dumps({"ok": True}))

        elif args.action == "add-channel":
            for ch in json.loads(args.channels_json):
                create_channel(ws, args.host, args.port, args.token, args.agent_key, ch)
            print(json.dumps({"ok": True}))

        elif args.action == "list-channels":
            print(json.dumps({"ok": True, "channels": list_channels_for_key(ws, args.agent_key)}))

        elif args.action == "update-files":
            # Re-seed identity files for an existing agent — no delete/create, no channel changes.
            # Use agents.files.set which overwrites in-place. Agent key resolves via GetByKey.
            soul     = open(args.soul_file).read()     if args.soul_file     else ""
            identity = open(args.identity_file).read() if args.identity_file else ""
            user     = open(args.user_file).read()     if args.user_file     else None
            seed_files(ws, args.agent_key, soul, identity, user)
            print(json.dumps({"ok": True}))

    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}), file=sys.stderr)
        sys.exit(1)
    finally:
        ws.close()


if __name__ == "__main__":
    main()
