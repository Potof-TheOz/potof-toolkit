#!/usr/bin/env bash
set -euo pipefail

# Installe le hook de notifications Claude (hooks/claude-notify.js) depuis ce repo
# vers son emplacement standard ~/.claude/hooks/, et câble les events Notification +
# Stop dans ~/.claude/settings.json. Idempotent, avec backup de settings.json.
#
# Le hook reste à son emplacement standard (indépendant du repo) : il notifie TOUTES
# tes sessions Claude, y compris hors Potof Toolkit (iTerm2 → terminal-notifier).
# Le repo n'en est que la source de vérité / sauvegarde. Voir docs/NOTIFICATIONS.md.
#
# Usage : ./Scripts/install-hook.sh

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_DIR/hooks/claude-notify.js"
CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
DEST="$HOOKS_DIR/claude-notify.js"
SETTINGS="$CLAUDE_DIR/settings.json"

[ -f "$SRC" ] || { echo "❌ Introuvable : $SRC"; exit 1; }

mkdir -p "$HOOKS_DIR"
cp "$SRC" "$DEST"
chmod +x "$DEST"
echo "✅ Hook copié → $DEST"

# Câblage settings.json (idempotent, avec backup horodaté).
python3 - "$SETTINGS" "$DEST" <<'PY'
import json, os, sys, shutil
from datetime import datetime

settings_path, hook_cmd = sys.argv[1], sys.argv[2]

data = {}
if os.path.exists(settings_path):
    with open(settings_path) as f:
        try:
            data = json.load(f)
        except Exception as e:
            print(f"⚠️  settings.json illisible ({e}).")
            print("   Câble manuellement les events Notification + Stop vers :")
            print(f"   {hook_cmd}")
            sys.exit(0)

hooks = data.setdefault("hooks", {})

def ensure(event, matcher):
    """Ajoute une entrée pointant vers hook_cmd sous `event` si absente."""
    arr = hooks.setdefault(event, [])
    for entry in arr:
        for h in entry.get("hooks", []):
            if h.get("command") == hook_cmd:
                return False  # déjà présent
    entry = {"hooks": [{"type": "command", "command": hook_cmd}]}
    if matcher is not None:
        entry = {"matcher": matcher, "hooks": [{"type": "command", "command": hook_cmd}]}
    arr.append(entry)
    return True

changed = False
if ensure("Notification", "permission_prompt|idle_prompt|agent_needs_input"):
    changed = True
if ensure("Stop", None):
    changed = True

if changed:
    if os.path.exists(settings_path):
        bak = settings_path + ".bak." + datetime.now().strftime("%Y%m%d%H%M%S")
        shutil.copy2(settings_path, bak)
        print(f"🗄  Backup : {bak}")
    os.makedirs(os.path.dirname(settings_path), exist_ok=True)
    with open(settings_path, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print("✅ Hooks Notification + Stop câblés dans settings.json")
else:
    print("✅ Hooks déjà câblés (rien à faire)")
PY

echo "🎉 Terminé. Les nouvelles sessions Claude notifieront Potof Toolkit (et iTerm2 hors app)."
