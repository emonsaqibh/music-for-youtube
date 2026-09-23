#!/bin/bash
# Builds and launches the dev build. Never touches the installed beta.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
pkill -f 'Music for YouTube Dev.app/Contents/MacOS/YouTubeMusic' 2>/dev/null || true
open "build/Music for YouTube Dev.app"
