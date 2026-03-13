#!/bin/bash
# Freedom Mission Control — Sync to GitHub
# Usage:
#   ./sync.sh                  → sync data and push
#   ./sync.sh --set-password   → change the dashboard password

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$SCRIPT_DIR/.."
DATA_DIR="$SCRIPT_DIR/data"

mkdir -p "$DATA_DIR"

# ── Set password mode ──────────────────────────────────────────────────────
if [[ "$1" == "--set-password" ]]; then
  echo -n "New password: "
  read -s NEW_PASS
  echo
  HASH=$(echo -n "$NEW_PASS" | base64)
  # Update the hash in index.html
  sed -i '' "s|const PASSWORD_HASH = '[^']*'|const PASSWORD_HASH = '$HASH'|" "$SCRIPT_DIR/index.html"
  echo "✅ Password updated. Run ./sync.sh to push the change."
  exit 0
fi

# ── Generate agent-tasks.json from active-tasks.md ────────────────────────
python3 - "$WORKSPACE/memory/active-tasks.md" "$DATA_DIR/agent-tasks.json" << 'PYEOF'
import json, re, sys
from datetime import datetime, timezone

def parse(md):
    sections = []
    current = None
    task = None
    for line in md.split('\n'):
        if line.startswith('## '):
            if current: sections.append(current)
            title = line[3:].strip()
            status = 'info'
            if 'IN PROGRESS' in title: status = 'in-progress'
            elif 'WAITING' in title: status = 'waiting'
            elif 'COMPLETED' in title: status = 'completed'
            current = {'title': title, 'status': status, 'tasks': []}
            task = None
        elif line.startswith('### ') and current:
            task = {'name': line[4:].strip(), 'notes': []}
            current['tasks'].append(task)
        elif task and re.match(r'^[-*•]\s+', line):
            note = re.sub(r'^[-*•]\s+', '', line).strip()
            if note and not note.startswith('<!--'):
                task['notes'].append(note)
    if current: sections.append(current)
    return sections

with open(sys.argv[1]) as f:
    md = f.read()

out = {'sections': parse(md), 'updatedAt': datetime.now(timezone.utc).isoformat()}
with open(sys.argv[2], 'w') as f:
    json.dump(out, f, indent=2)
PYEOF
echo "→ agent-tasks.json updated"

# ── Generate call-analyses.json ────────────────────────────────────────────
python3 - "$WORKSPACE/memory/call-analyses" "$DATA_DIR/call-analyses.json" << 'PYEOF'
import json, re, sys, os
from datetime import datetime, timezone

def parse_call(content, filename):
    lines = content.split('\n')
    contact = filename.replace('.md','').replace('_',' ')
    date = None
    business = None
    takeaways = []
    for line in lines:
        if not date and re.match(r'^Date:\s*', line):
            date = re.sub(r'^Date:\s*', '', line).strip()
        m = re.match(r'^Call:\s*(.+)', line)
        if m: contact = m.group(1).strip()
        if not business:
            if 'Nmbr' in line or 'Number' in line: business = 'Nmbr'
            elif 'Charlie' in line: business = 'Charlie'
        if re.match(r'^[-*]\s*(MUST|Key|Takeaway|Action|✅|Follow)', line, re.I) and len(takeaways) < 4:
            takeaways.append(re.sub(r'^[-*]\s*','',line).strip())
    if not date:
        m = re.search(r'(\d{4}-\d{2}-\d{2})', filename)
        if m: date = m.group(1)
    return {'contact': contact, 'date': date or 'Unknown', 'business': business or 'Unknown', 'takeaways': takeaways, 'filename': filename}

call_dir = sys.argv[1]
analyses = []
if os.path.isdir(call_dir):
    for f in sorted(os.listdir(call_dir), reverse=True):
        if f.endswith('.md'):
            with open(os.path.join(call_dir, f)) as fh:
                analyses.append(parse_call(fh.read(), f))

out = {'analyses': analyses, 'updatedAt': datetime.now(timezone.utc).isoformat()}
with open(sys.argv[2], 'w') as fh:
    json.dump(out, fh, indent=2)
PYEOF
echo "→ call-analyses.json updated"

# ── Generate documents.json with file content ──────────────────────────────
python3 - "$WORKSPACE" "$DATA_DIR/documents.json" << 'DOCSEOF'
import json, os, sys
from datetime import datetime, timezone

workspace = sys.argv[1]
out_path = sys.argv[2]
MAX_FILE_SIZE = 100 * 1024  # 100KB
EXTENSIONS = {'.md', '.txt', '.sh', '.json', '.py', '.yml', '.yaml', '.toml', '.cfg', '.conf'}
SKIP_DIRS = {'node_modules', '.git', '__pycache__', '.cache', 'dashboard/data', '.openclaw'}

import re as _re

def sanitize(text):
    # Redact tokens, keys, passwords
    patterns = [
        r'(sk-[a-zA-Z0-9_-]{20,})',
        r'(ghp_[a-zA-Z0-9]{36,})',
        r'(bot_token["\':\s]*[0-9]+:[A-Za-z0-9_-]{30,})',
        r'([0-9]+:[A-Za-z0-9_-]{35,})',
        r'(Bearer\s+[A-Za-z0-9._-]{20,})',
        r'(xoxb-[A-Za-z0-9-]+)',
        r'(AAAA[A-Za-z0-9+/=]{20,})',
        r'(GOCSPX-[A-Za-z0-9_-]+)',
        r'([0-9]+-[a-z0-9]+\.apps\.googleusercontent\.com)',
        r'("client_secret"\s*:\s*"[^"]+")',
        r'("client_id"\s*:\s*"[^"]+")',
    ]
    for p in patterns:
        text = _re.sub(p, '[REDACTED]', text)
    return text

folders = []
for root, dirs, files in os.walk(workspace):
    dirs[:] = [d for d in dirs if d not in {'node_modules', '.git', '__pycache__', '.cache'}]
    rel = os.path.relpath(root, workspace)
    if rel == '.': rel = 'root'
    if any(skip in rel for skip in SKIP_DIRS):
        continue
    folder_files = []
    for f in sorted(files):
        if f.startswith('.env') or f in {'config-hash.txt', 'openclaw.json', 'credentials.json'}:
            continue
        ext = os.path.splitext(f)[1].lower()
        if ext not in EXTENSIONS:
            continue
        fpath = os.path.join(root, f)
        try:
            size = os.path.getsize(fpath)
            if size > MAX_FILE_SIZE or size == 0:
                continue
            with open(fpath, 'r', errors='replace') as fh:
                content = fh.read()
            folder_files.append({"name": f, "content": sanitize(content)})
        except:
            folder_files.append({"name": f, "content": None})
    if folder_files:
        folders.append({"name": rel, "files": folder_files})

with open(out_path, 'w') as fh:
    json.dump({"folders": folders}, fh)
print(f"→ documents.json updated ({len(folders)} folders)")
DOCSEOF

# ── Sync docs.json ─────────────────────────────────────────────────────────
if [ -f "$SCRIPT_DIR/docs.json" ]; then
  cp "$SCRIPT_DIR/docs.json" "$DATA_DIR/docs.json"
  echo "→ docs.json synced"
fi

# ── Git commit and push ────────────────────────────────────────────────────
cd "$SCRIPT_DIR"
git add data/ docs.json index.html
git diff --cached --quiet && echo "→ Nothing changed, skipping push" && exit 0

TIMESTAMP=$(date '+%Y-%m-%d %H:%M')
git commit -m "sync: $TIMESTAMP"
git push origin main
echo ""
echo "✅ Mission Control synced → https://control.drewmillington.com"
