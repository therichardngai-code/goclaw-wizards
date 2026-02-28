#!/usr/bin/env python3
# GoClaw agent + channel provisioning via WebSocket RPC.
# Python 3.8+, stdlib only. NEVER use agent_type "open". ALWAYS dm_policy "allowlist".
import argparse, base64, json, os, socket, struct, sys


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
    """JSON-RPC over WebSocket for GoClaw gateway."""
    def __init__(self, host, port, token):
        self._ws = _WS(host, port)
        self._id = 0
        self._ws.send(json.dumps({"method": "connect", "params": {"token": token, "user_id": "wizard"}}))
        r = json.loads(self._ws.recv())
        if not r.get("ok"):
            raise RuntimeError(f"Auth failed: {r}")

    def call(self, method, params):
        self._id += 1
        self._ws.send(json.dumps({"id": self._id, "method": method, "params": params}))
        r = json.loads(self._ws.recv())
        if r.get("ok") is False:
            raise RuntimeError(f"{method} failed: {r.get('error', r)}")
        return r

    def close(self): self._ws.close()


def create_agent(ws, name, key):
    r = ws.call("agents.create", {"name": name, "agent_key": key, "agent_type": "predefined"})
    p = r.get("payload", {})
    return str(p.get("id") or p.get("agent_id") or key)

def seed_files(ws, key, soul, identity, user=None):
    for fname, content in [("SOUL.md", soul), ("IDENTITY.md", identity)]:
        ws.call("agents.files.set", {"agentId": key, "name": fname, "content": content})
    if user:
        ws.call("agents.files.set", {"agentId": key, "name": "USER.md", "content": user})

def create_channel(ws, agent_id, key, ch):
    ws.call("channels.instances.create", {
        "name": f"{key}-{ch['type']}",
        "display_name": ch.get("display_name", f"{key} ({ch['type']})"),
        "channel_type": ch["type"], "agent_id": agent_id,
        "credentials": ch["credentials"],
        "config": {"dm_policy": "allowlist", "allow_from": ch.get("owner_ids", [])},
        "enabled": True,
    })

def list_channels_for_key(ws, key):
    r = ws.call("channels.instances.list", {})
    instances = r.get("payload") or r.get("instances") or []
    return [i for i in instances if i.get("name", "").startswith(f"{key}-")]

def delete_agent(ws, key):
    for inst in list_channels_for_key(ws, key):
        ws.call("channels.instances.delete", {"id": inst["id"]})
    ws.call("agents.delete", {"agentKey": key})


def main():
    p = argparse.ArgumentParser(description="GoClaw agent provisioning")
    p.add_argument("--action", required=True, choices=["create","delete","add-channel","list-channels"])
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--token", required=True)
    p.add_argument("--agent-name"); p.add_argument("--agent-key")
    p.add_argument("--soul-file");  p.add_argument("--identity-file"); p.add_argument("--user-file")
    p.add_argument("--channels-json", default="[]")
    args = p.parse_args()

    ws = GoclawWS(args.host, args.port, args.token)
    try:
        if args.action == "create":
            soul     = open(args.soul_file).read()     if args.soul_file     else ""
            identity = open(args.identity_file).read() if args.identity_file else ""
            user     = open(args.user_file).read()     if args.user_file     else None
            agent_id = create_agent(ws, args.agent_name, args.agent_key)
            seed_files(ws, args.agent_key, soul, identity, user)
            for ch in json.loads(args.channels_json):
                create_channel(ws, agent_id, args.agent_key, ch)
            print(json.dumps({"ok": True, "agent_id": agent_id}))
        elif args.action == "delete":
            delete_agent(ws, args.agent_key)
            print(json.dumps({"ok": True}))
        elif args.action == "add-channel":
            for ch in json.loads(args.channels_json):
                create_channel(ws, args.agent_key, args.agent_key, ch)
            print(json.dumps({"ok": True}))
        elif args.action == "list-channels":
            print(json.dumps({"ok": True, "channels": list_channels_for_key(ws, args.agent_key)}))
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}), file=sys.stderr)
        sys.exit(1)
    finally:
        ws.close()

if __name__ == "__main__":
    main()
