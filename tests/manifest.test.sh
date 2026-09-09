#!/usr/bin/env bash
set -euo pipefail
dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

jq -e '
  .schemaVersion == 1
  and .id == "io.github.nimbleaininja.voxclaude"
  and (.kinds | index("bar-widget"))
  and .entryPoints.barWidget == "Panel.qml"
  and .barWidget.defaultSection == "right"
  and .barWidget.category == "AI"
  and .barWidget.defaults.cwd == "~/Work"
  and .barWidget.defaults.permissionMode == "auto"
  and .barWidget.defaults.terminalWords == "terminal"
  and .barWidget.defaults.waitSeconds == 60
  and ([.barWidget.schema[].key] == ["cwd", "permissionMode", "terminalWords", "waitSeconds"])
  and ((.barWidget.schema[] | select(.key == "permissionMode") | .options) == ["auto", "acceptEdits", "bypassPermissions", "default"])
' "$dir/manifest.json" >/dev/null

[[ -f "$dir/Panel.qml" ]] || { echo "Panel.qml missing" >&2; exit 1; }
[[ -f "$dir/Model.js" ]] || { echo "Model.js missing" >&2; exit 1; }
[[ -x "$dir/bin/voxclaude" ]] || { echo "bin/voxclaude missing or not executable" >&2; exit 1; }
bash -n "$dir/bin/voxclaude"

if command -v omarchy-plugin-validate >/dev/null 2>&1; then
  omarchy-plugin-validate "$dir" >/dev/null
  echo "manifest: ok (omarchy plugin validate passed)"
else
  echo "manifest: ok (omarchy not on PATH, validate skipped)"
fi
