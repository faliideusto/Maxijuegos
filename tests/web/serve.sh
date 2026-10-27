#!/usr/bin/env bash
# Sirve build/web para tests/web/online_test.js: copia la exportación a tests/logs/web, hace que index.html
# lea los argumentos de DevCli de la URL (?args=--host --log ...) y arranca un PeerJS local en el puerto 9000.
# Necesita node con los paquetes `peer` y `playwright` (npm i peer playwright).
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT=tests/logs/web
rm -rf "$OUT" && mkdir -p "$OUT" && cp -r build/web/. "$OUT/"
sed -i 's/"args":\[\]/"args":["--"].concat((new URLSearchParams(location.search).get("args")||"").split(" ").filter(Boolean))/' "$OUT/index.html"
node -e "require('peer').PeerServer({port: 9000, host: '127.0.0.1', key: 'peerjs', path: '/'})" &
trap 'kill %1' EXIT
python3 -m http.server 8765 --directory "$OUT"
