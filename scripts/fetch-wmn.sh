#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
curl -fsSL https://raw.githubusercontent.com/WebBreacher/WhatsMyName/main/wmn-data.json -o TiesCore/Sources/TiesCore/Resources/wmn-data.json
echo "WhatsMyName data (c) Micah Hoffman, CC BY-SA 4.0 — https://github.com/WebBreacher/WhatsMyName" > TiesCore/Sources/TiesCore/Resources/WMN-LICENSE.txt
