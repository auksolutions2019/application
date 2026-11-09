#!/usr/bin/env bash
# Cloudflare Pages "build": copies only the app's own files into dist/.
# Nothing is compiled. docs/, tests/, supabase/, prototype/ and tools/ are not published.
set -euo pipefail
rm -rf dist
mkdir dist
cp index.html app.js config.js manifest.webmanifest sw.js dist/
cp -r css assets lib api ui views dist/
# keep the browser from holding on to an old config.js or service worker
cat > dist/_headers <<'H'
/config.js
  Cache-Control: no-cache
/sw.js
  Cache-Control: no-cache
/index.html
  Cache-Control: no-cache
H
echo "dist/ ready: $(find dist -type f | wc -l) files"
