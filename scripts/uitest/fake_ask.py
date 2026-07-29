import json, socket, sys, time

SOCK = "/tmp/claude-island.sock"
session = sys.argv[1] if len(sys.argv) > 1 else "test-click-e2e-0002"
keep = float(sys.argv[2]) if len(sys.argv) > 2 else 20.0


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


base = {"session_id": session, "cwd": "/tmp/fake-project", "pid": 99996, "tty": None, "transcript_path": None}
q = {"questions": [{"question": "クリックテスト", "header": "t", "multiSelect": False,
     "options": [{"label": "AAAA", "description": "a"}, {"label": "BBBB", "description": "b"}]}]}

send({**base, "event": "UserPromptSubmit", "status": "processing"})
time.sleep(0.3)
send({**base, "event": "PreToolUse", "status": "running_tool", "tool": "AskUserQuestion",
      "tool_input": q, "tool_use_id": "toolu_" + session[-6:]})
time.sleep(0.3)
send({**base, "event": "PermissionRequest", "status": "waiting_for_approval",
      "tool": "AskUserQuestion", "tool_input": q, "has_permission_suggestions": False}, wait=keep)

# cleanup
send({**base, "event": "SessionEnd", "status": "ended"})
print("done", flush=True)
