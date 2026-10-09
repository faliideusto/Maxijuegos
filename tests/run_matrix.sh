#!/usr/bin/env bash
# Ejecuta la matriz completa de pruebas online (tarda varios minutos).
# Uso: GODOT=/ruta/a/godot tests/run_matrix.sh
cd "$(dirname "$0")/.."
CONFIGS=(
  "2 12 0 normal"
  "4 12 0 normal"
  "8 12 0 normal"
  "4 12 4 normal"
  "4 12 0 kill_in_lobby"
  "4 12 0 kill_in_game"
  "4 12 0 kill_in_parallel"
  "8 12 0 kill_in_parallel"
  "4 12 0 kill_host"
  "3 12 0 late_join"
)
PASS=0; FAIL=0
for cfg in "${CONFIGS[@]}"; do
  out=$(bash tests/online_test.sh $cfg 2>&1)
  if echo "$out" | grep -q "^ONLINE TEST OK"; then
    PASS=$((PASS+1)); echo "OK     $cfg"
  else
    FAIL=$((FAIL+1)); echo "FALLÓ  $cfg"; echo "$out" | grep -E "✗|ERROR" | head -8
  fi
done
echo
echo "Matriz: $PASS OK, $FAIL fallos"
[[ $FAIL -eq 0 ]]
