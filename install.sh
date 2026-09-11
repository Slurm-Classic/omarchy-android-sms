#!/bin/bash
# install.sh — install omarchy-android-sms.
# Usage: ./install.sh [--bar]   (--bar also adds the widget to the omarchy bar)
set -euo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"

echo "==> binaries -> ~/.local/bin"
mkdir -p ~/.local/bin
for f in "$REPO"/bin/*; do
  [[ -f "$f" ]] || continue  # skip __pycache__/ and other dirs
  cp "$f" ~/.local/bin/
  chmod +x ~/.local/bin/"$(basename "$f")"
done

echo "==> plugin -> ~/.config/omarchy/plugins/android.sms"
mkdir -p ~/.config/omarchy/plugins
rm -rf ~/.config/omarchy/plugins/android.sms
cp -r "$REPO/plugins/android.sms" ~/.config/omarchy/plugins/

echo "==> systemd user units"
mkdir -p ~/.config/systemd/user
cp "$REPO/systemd/"*.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now android-sms-tether-watch.service
systemctl --user enable --now sms-reply-watch.service

echo "==> rescan omarchy plugins"
omarchy-shell shell rescanPlugins 2>/dev/null || true

if [[ "${1:-}" == "--bar" ]]; then
  echo "==> adding android.sms to the bar"
  python3 - "$HOME/.config/omarchy/shell.json" <<'EOF'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
layout = cfg.setdefault("bar", {}).setdefault("layout", {})
right = layout.setdefault("right", [])
if not any(w.get("id") == "android.sms" for w in right):
    names = [w.get("id") for w in right]
    try:
        i = names.index("omarchy.tailscale") + 1
    except ValueError:
        i = len(right)
    right.insert(i, {"id": "android.sms"})
    json.dump(cfg, open(p, "w"), indent=2)
    print("added android.sms to bar > right")
else:
    print("android.sms already in bar")
EOF
fi

echo
echo "Done. If the bar icon is missing, add {\"id\": \"android.sms\"} to the"
echo "right section of ~/.config/omarchy/shell.json (or re-run with --bar)."
echo "Pair your phone in KDE Connect, allow SMS + Contacts, and plug it in."
