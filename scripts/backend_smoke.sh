#!/usr/bin/env bash
#
# Smoke test for the TestKit backend: start it, drive it over TCP (as the TestKit
# harness does) and check the response names.
set -euo pipefail
cd "$(dirname "$0")/.."

export TESTKIT_BACKEND_PORT="${TESTKIT_BACKEND_PORT:-9876}"

python3 - <<'PYEOF'
import json
import os
import socket
import subprocess
import time

port = int(os.environ.get("TESTKIT_BACKEND_PORT", "9876"))
subprocess.run(["dune", "build"], check=True, capture_output=True)
backend = subprocess.Popen(
    ["./_build/default/testkitbackend/testkitbackend.exe"],
    cwd=".",
)
try:
    conn = None
    for _ in range(100):
        try:
            conn = socket.create_connection(("127.0.0.1", port), timeout=1)
            break
        except OSError:
            time.sleep(0.1)
    if conn is None:
        raise SystemExit("FAIL: backend did not start")

    def request(name, data):
        conn.sendall(
            ("#request begin\n" + json.dumps({"name": name, "data": data})
             + "\n#request end\n").encode())

    def read_response():
        lines = []
        in_resp = False
        while True:
            data = conn.recv(4096).decode()
            if not data:
                raise SystemExit("FAIL: backend closed the connection")
            for part in data.split("\n"):
                if part == "#response begin":
                    in_resp = True
                elif part == "#response end":
                    return json.loads("".join(lines))
                elif in_resp:
                    lines.append(part)

    request("StartTest", {"testName": "smoke"})
    assert read_response()["name"] == "RunTest", "expected RunTest"
    request("GetFeatures", {})
    assert read_response()["name"] == "FeatureList", "expected FeatureList"
    request(
        "NewDriver",
        {
            "uri": "bolt://localhost:7687",
            "userAgent": "test-agent",
            "authorizationToken": {
                "name": "AuthorizationToken",
                "data": {
                    "scheme": "basic",
                    "principal": "neo4j",
                    "credentials": "pass",
                },
            },
        },
    )
    driver = read_response()
    assert driver["name"] == "Driver", "expected Driver"
    driver_id = driver["data"]["id"]
    request("NewSession", {"driverId": driver_id, "database": None, "accessMode": None})
    session = read_response()
    assert session["name"] == "Session", "expected Session"
    session_id = session["data"]["id"]
    request("SessionClose", {"sessionId": session_id})
    assert read_response()["name"] == "Session", "expected Session"
    request("DriverClose", {"driverId": driver_id})
    assert read_response()["name"] == "Driver", "expected Driver"
    request("NoSuchCommand", {})
    assert read_response()["name"] == "BackendError", "expected BackendError"
    print("backend smoke ok")
finally:
    backend.terminate()
    backend.wait()
PYEOF
