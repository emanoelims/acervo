#!/usr/bin/env bash
# Runs inside the Sprite: installs Chromium and its system libraries, then the
# service's dependencies. Safe to run again after editing server.mjs.
set -euo pipefail
cd "$(dirname "$0")"
npm install --omit=dev --no-audit --no-fund
sudo env "PATH=$PATH" npx --yes playwright@1.63.0 install-deps chromium
PLAYWRIGHT_BROWSERS_PATH="$HOME/.cache/ms-playwright" npx --yes playwright@1.63.0 install chromium
