#!/usr/bin/env python3
"""Zero-shot UI-grounding test against Pioneer (OpenAI-compatible).

Reads the accessibility dump (/tmp/a11y.txt produced by the `dump` chat command)
plus an instruction, asks a Pioneer base model which element to act on, and
prints the model's choice. No fine-tuning — this checks if grounding works
zero-shot before spending credits on training.

Usage:
  PIONEER_API_KEY=... python3 tools/ground_test.py "click the submit button"
  PIONEER_API_KEY=... MODEL=claude-sonnet-4-6 python3 tools/ground_test.py "log in"
"""
import os, sys, json, ssl, urllib.request

# python.org Python often lacks the system CA bundle; use certifi's bundle for
# proper TLS verification.
import certifi
_ctx = ssl.create_default_context(cafile=certifi.where())

API_URL = os.environ.get("PIONEER_API_URL", "https://api.pioneer.ai").rstrip("/")
API_KEY = os.environ.get("PIONEER_API_KEY")
MODEL = os.environ.get("MODEL", "google/gemma-4-12B-it")
DUMP = os.environ.get("DUMP", "/tmp/a11y.txt")

if not API_KEY:
    sys.exit("Set PIONEER_API_KEY (your Pioneer key).")
if len(sys.argv) < 2:
    sys.exit('Usage: ground_test.py "<instruction>"')
instruction = " ".join(sys.argv[1:])

try:
    elements = open(DUMP).read().strip()
except FileNotFoundError:
    sys.exit(f"No dump at {DUMP}. In the app: shake -> type 'dump' first.")

system = (
    "You are a UI grounding model. You are given a numbered list of on-screen "
    "elements (each with a label and pixel center) and a user instruction. "
    "Pick the single best element to act on. Reply with ONLY JSON: "
    '{"action":"click"|"type","id":<int>,"text":<string-if-typing>}. '
    'If no element matches, reply {"action":"none"}.'
)
user = f"Elements:\n{elements}\n\nInstruction: {instruction}"

body = json.dumps({
    "model": MODEL,
    "messages": [{"role": "system", "content": system},
                 {"role": "user", "content": user}],
    "temperature": 0,
    "max_tokens": 200,
}).encode()

req = urllib.request.Request(
    f"{API_URL}/v1/chat/completions", data=body,
    headers={"Content-Type": "application/json", "Authorization": f"Bearer {API_KEY}"},
)
try:
    resp = json.load(urllib.request.urlopen(req, timeout=180, context=_ctx))
except urllib.error.HTTPError as e:
    sys.exit(f"HTTP {e.code}: {e.read().decode()[:500]}")

reply = resp["choices"][0]["message"]["content"].strip()
print(f"model:  {MODEL}")
print(f"reply:  {reply}")

# Map the chosen id back to the element line for a human-readable result.
try:
    choice = json.loads(reply[reply.index("{"):reply.rindex("}") + 1])
    cid = choice.get("id")
    if cid is not None:
        for line in elements.splitlines():
            if line.startswith(f"[{cid}]"):
                print(f"target: {line}")
                break
except Exception:
    pass
