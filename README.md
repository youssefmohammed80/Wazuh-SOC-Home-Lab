#!/usr/bin/env bash
# fix_repo.sh — run from the ROOT of your Wazuh-SOC-Home-Lab clone.
#   1) renames screenshots to meaningful names (git mv, history kept)
#   2) updates every image link in README.md
#   3) removes all references to docs/
#   4) syncs the "Repository Structure" tree with reality
#   5) sets the GitHub description + topics (needs `gh`, optional)
set -euo pipefail

[[ -f README.md && -d screenshots ]] || { echo "Run this from the repo root."; exit 1; }

# ---------- 1) rename screenshots ----------
declare -A MAP=(
  ["Screenshot 2026-09-28 185101.png"]="wazuh-server-network.png"
  ["Screenshot 2026-09-28 184734.png"]="wazuh-dashboard.png"
  ["Screenshot 2026-09-28 184827.png"]="ubuntu-server-agent.png"
  ["Screenshot 2026-09-28 184753.png"]="wazuh-agents.png"
  ["Screenshot 2026-09-28 184804.png"]="kali-attack-simulator.png"
  ["Screenshot 2026-09-28 185159.png"]="windows-failed-logon.png"
  ["Screenshot 2026-09-28 185131.png"]="wazuh-events.png"
  ["Screenshot 2026-09-28 185145.png"]="alert-details.png"
  ["Screenshot 2026-09-28 185038.png"]="source-host-evidence.png"
)

for old in "${!MAP[@]}"; do
  new="${MAP[$old]}"
  if [[ -f "screenshots/$old" ]]; then
    git mv "screenshots/$old" "screenshots/$new"
    old_enc="${old// /%20}"
    sed -i "s#screenshots/${old_enc}#screenshots/${new}#g" README.md
    echo "renamed: $old -> $new"
  else
    echo "skip (not found): $old"
  fi
done

# ---------- 2+3+4) README: remove docs/, fix tree ----------
python3 - <<'PY'
import re, pathlib
p = pathlib.Path("README.md")
t = p.read_text(encoding="utf-8")

# remove the sentence pointing to docs/
t = re.sub(r"\n*Detailed investigation notes and commands are available in the `docs/` directory\.\n", "\n", t)

# rebuild the repository-structure block
tree = """```text
Wazuh-SOC-Home-Lab/
│
├── README.md
├── LICENSE
│
├── scripts/
│   └── wazuh_lab_attack_simulator.sh
│
└── screenshots/
    ├── wazuh-server-network.png
    ├── wazuh-dashboard.png
    ├── wazuh-agents.png
    ├── ubuntu-server-agent.png
    ├── kali-attack-simulator.png
    ├── windows-failed-logon.png
    ├── wazuh-events.png
    ├── alert-details.png
    └── source-host-evidence.png
```

The README provides the project overview and investigation walkthrough, `scripts/` contains the attack simulator, and `screenshots/` holds the lab evidence."""

t = re.sub(
    r"```text\nWazuh-SOC-Home-Lab/.*?```\n\nThe README provides the project overview, while the `docs/` directory contains the detailed technical procedures and test plans\.",
    lambda m: tree, t, flags=re.S)

p.write_text(t, encoding="utf-8")
PY

if grep -n "docs/" README.md; then
  echo "WARNING: leftover docs/ references above — check manually."
else
  echo "README: no docs/ references left."
fi

# ---------- 5) GitHub description + topics ----------
DESC="Wazuh SIEM SOC home lab: attack simulation, detection, investigation and MITRE ATT&CK mapping (Windows + Linux agents, Kali)"
TOPICS="wazuh,siem,soc,mitre-attack,blue-team,home-lab,threat-detection,incident-response,cybersecurity"

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  gh repo edit --description "$DESC"
  IFS=',' read -ra T <<< "$TOPICS"
  for topic in "${T[@]}"; do gh repo edit --add-topic "$topic"; done
  echo "GitHub description + topics updated."
else
  echo
  echo "gh CLI not available/logged in. Set manually (repo page -> About -> gear icon):"
  echo "  Description: $DESC"
  echo "  Topics:      ${TOPICS//,/ }"
fi

echo
git status --short
echo
echo "Next:  git add -A && git commit -m 'Organize repo: rename screenshots, remove docs references, sync structure' && git push"
