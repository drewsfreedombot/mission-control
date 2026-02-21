#!/bin/bash
# Freedom Mission Control — Local Server
# Starts the dashboard at http://localhost:3000

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo ""
echo "🦅 Freedom Mission Control"
echo "   Starting at http://localhost:3000"
echo "   Press Ctrl+C to stop"
echo ""

node "$SCRIPT_DIR/server.js"
