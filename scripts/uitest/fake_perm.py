import json, socket, sys, time

SOCK = "/tmp/claude-island.sock"
session = sys.argv[1]
keep = float(sys.argv[2]) if len(sys.argv) > 2 else 12.0


def send(state, wait=0.0):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(keep + 5)
    s.connect(SOCK)
    s.sendall(json.dumps(state).encode())
    if wait:
        try:
            r = s.recv(4096)
            print("PERMISSION RESPONSE:", r.decode()[:200], flush=True)
        except socket.timeout:
            print("PERMISSION TIMEOUT (no response)", flush=True)
    s.close()


base = {"session_id": session, "cwd": "/tmp/fake-project", "pid": 99995, "tty": None, "transcript_path": None}
ti = {"command": "echo hello", "description": "test command"}

send({**base, "event": "UserPromptSubmit", "status": "processing"})
time.sleep(0.3)
send({**base, "event": "PreToolUse", "status": "running_tool", "tool": "Bash",
      "tool_input": ti, "tool_use_id": "toolu_" + session[-6:]})
time.sleep(0.3)
send({**base, "event": "PermissionRequest", "status": "waiting_for_approval",
      "tool": "Bash", "tool_input": ti, "has_permission_suggestions": True}, wait=keep)
send({**base, "event": "SessionEnd", "status": "ended"})
print("done", flush=True)
