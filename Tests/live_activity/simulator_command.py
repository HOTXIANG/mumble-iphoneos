#!/usr/bin/env python3
"""Send one Live Activity fixture command to the DEBUG iOS Simulator app."""

import argparse
import json
from pathlib import Path
import sys
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Scripts"))
from mumble_agent_probe import StdlibWebSocket


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("start", "update", "end", "list"))
    parser.add_argument("params", nargs="?", default="{}", help="JSON object")
    parser.add_argument("--url", default="ws://localhost:54296")
    args = parser.parse_args()
    params = json.loads(args.params)
    if not isinstance(params, dict):
        parser.error("params must be a JSON object")
    request_id = str(uuid.uuid4())
    ws = StdlibWebSocket(args.url, timeout=10)
    ws.connect()
    try:
        ws.send_json({"id": request_id, "action": f"liveActivity.{args.command}", "params": params})
        while True:
            response = ws.recv_json()
            if response.get("id") == request_id:
                print(json.dumps(response, ensure_ascii=False, indent=2))
                return 0 if response.get("success") else 1
    finally:
        ws.close()


if __name__ == "__main__":
    sys.exit(main())
