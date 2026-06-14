#!/usr/bin/env python3
"""Generate a synthetic UI-grounding SFT dataset for ShakeSight.

Each row is a chat: system instruction + a user turn listing on-screen elements
(label + pixel center) and a natural-language instruction, and an assistant turn
replying with strict JSON {"action","id","text"} selecting the element.

Reproducible (seeded). Output: JSONL with a "messages" column (standard SFT shape).

Usage:  python3 tools/gen_grounding_dataset.py --n 2000 --out hf_dataset/train.jsonl
"""
import argparse, json, os, random

SYSTEM = (
    "You are a UI grounding model. Given a numbered list of on-screen elements "
    "(label + pixel center) and an instruction, pick the single best element. "
    'Reply with ONLY JSON: {"action":"click"|"type","id":<int>,"text":<string if typing>}. '
    'If nothing matches, reply {"action":"none"}.'
)

# Per-"app" pools of (role, label) controls and instruction templates.
APPS = {
    "browser": {
        "controls": [("Button", "Go back"), ("Button", "Go forward"), ("Button", "Reload"),
                     ("Button", "Bookmark"), ("Button", "New tab"), ("Button", "Downloads"),
                     ("Link", "Docs"), ("Link", "Pricing"), ("Link", "Sign in"), ("Button", "Run inference"),
                     ("SearchField", "Search or enter address"), ("Button", "Extensions")],
        "templates": {"Go back": ["go back", "previous page", "take me back", "navigate back"],
                      "Reload": ["refresh the page", "reload"], "Sign in": ["log in", "sign in", "i want to log in"],
                      "Docs": ["open the docs", "show documentation", "go to docs"]},
    },
    "settings": {
        "controls": [("CheckBox", "Wi-Fi"), ("CheckBox", "Bluetooth"), ("CheckBox", "Do Not Disturb"),
                     ("Button", "Network"), ("Button", "Displays"), ("Button", "Sound"),
                     ("Button", "Privacy & Security"), ("Slider", "Brightness"), ("PopUpButton", "Appearance")],
        "templates": {"Wi-Fi": ["toggle wifi", "turn on wi-fi", "enable wifi"],
                      "Bluetooth": ["turn off bluetooth", "toggle bluetooth"],
                      "Privacy & Security": ["open privacy settings", "go to privacy and security"]},
    },
    "login": {
        "controls": [("TextField", "Email"), ("TextField", "Password"), ("Button", "Sign in"),
                     ("Button", "Create account"), ("Link", "Forgot password"), ("CheckBox", "Remember me")],
        "templates": {"Sign in": ["log in", "submit the login", "sign in"],
                      "Forgot password": ["i forgot my password", "reset password"],
                      "Create account": ["make a new account", "sign up"]},
    },
    "editor": {
        "controls": [("Button", "Save"), ("Button", "Open"), ("Button", "New File"), ("Button", "Run"),
                     ("Button", "Find"), ("Button", "Format"), ("Button", "Commit"), ("Button", "Terminal"),
                     ("TextField", "Search files")],
        "templates": {"Save": ["save the file", "save"], "Run": ["run the code", "execute"],
                      "Commit": ["commit my changes", "make a commit"], "Find": ["find in file", "search"]},
    },
    "shop": {
        "controls": [("Button", "Add to cart"), ("Button", "Buy now"), ("Button", "Checkout"),
                     ("Button", "Wishlist"), ("SearchField", "Search products"), ("Link", "Account"),
                     ("Button", "Filters")],
        "templates": {"Add to cart": ["add this to my cart", "add to cart"],
                      "Checkout": ["check out", "go to checkout", "proceed to payment"],
                      "Search products": ["search for something", "find a product"]},
    },
    "media": {
        "controls": [("Button", "Play"), ("Button", "Pause"), ("Button", "Next"), ("Button", "Previous"),
                     ("Slider", "Volume"), ("Button", "Shuffle"), ("Button", "Fullscreen")],
        "templates": {"Play": ["play", "start playback"], "Next": ["skip to next track", "next song"],
                      "Fullscreen": ["go fullscreen", "make it full screen"]},
    },
}

TYPE_VALUES = {"Email": "alex@example.com", "Password": "hunter2", "Search products": "wireless headphones",
               "Search files": "main.swift", "Search or enter address": "pioneer.ai", "Search": "invoice"}


def rand_center(rng):
    return (rng.randint(40, 1880), rng.randint(40, 1040))


def make_example(rng):
    app = rng.choice(list(APPS))
    pool = APPS[app]["controls"][:]
    rng.shuffle(pool)
    k = rng.randint(5, min(12, len(pool)))
    chosen = pool[:k]
    elements = [{"id": i, "role": r, "label": l, "center": rand_center(rng)} for i, (r, l) in enumerate(chosen)]

    listing = "\n".join(f'[{e["id"]}] {e["role"]} "{e["label"]}" center=({e["center"][0]},{e["center"][1]})'
                        for e in elements)

    # 10% no-match negatives.
    if rng.random() < 0.10:
        instr = rng.choice(["delete my account permanently", "order a pizza", "call mom",
                            "translate this to french", "what time is it"])
        answer = {"action": "none"}
    else:
        target = rng.choice(elements)
        templates = APPS[app]["templates"].get(target["label"])
        if templates and rng.random() < 0.7:
            instr = rng.choice(templates)
        else:
            verb = "type into" if target["role"] in ("TextField", "SearchField") else rng.choice(["click", "press", "select", "tap"])
            instr = f'{verb} {target["label"].lower()}'
        if target["role"] in ("TextField", "SearchField"):
            answer = {"action": "type", "id": target["id"], "text": TYPE_VALUES.get(target["label"], "test")}
        else:
            answer = {"action": "click", "id": target["id"]}

    return {"messages": [
        {"role": "system", "content": SYSTEM},
        {"role": "user", "content": f"Elements:\n{listing}\n\nInstruction: {instr}"},
        {"role": "assistant", "content": json.dumps(answer, separators=(",", ":"))},
    ]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=2000)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--out", default="hf_dataset/train.jsonl")
    args = ap.parse_args()

    rng = random.Random(args.seed)
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w") as f:
        for _ in range(args.n):
            f.write(json.dumps(make_example(rng)) + "\n")
    print(f"wrote {args.n} examples to {args.out}")


if __name__ == "__main__":
    main()
