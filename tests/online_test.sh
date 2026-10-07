#!/usr/bin/env bash
# Prueba ONLINE con instancias reales del juego (headless) en la misma máquina.
#
# Uso:   GODOT=/ruta/a/godot tests/online_test.sh <humanos> <minijuegos> [bots] [escenario]
#
# humanos   nº de PCs/jugadores humanos (1 host + N-1 clientes), 1 jugador por PC
# bots      jugadores bot extra que añade el host (para simular más jugadores)
# escenario normal         partida completa lobby → minijuegos → marcador → final
#           kill_in_lobby  un cliente se cae en el lobby; la partida debe seguir sin él
#           kill_in_game   un cliente se cae en mitad de un minijuego; lo sustituye un bot
#           kill_host      el host se cae en mitad de una partida; los clientes vuelven al menú
#           late_join      un cliente intenta entrar con la partida empezada: debe ser rechazado
#
# Cada instancia usa los argumentos de DevCli (--host, --join, --autopilot, --log...).
# Los logs quedan en tests/logs/<escenario>_<humanos>p_<bots>b/. Sale con 0 si todo OK.

HUMANS=${1:-2}
GAMES=${2:-3}
BOTS=${3:-0}
SCEN=${4:-normal}
GODOT=${GODOT:-godot}
TS=${TIMESCALE:-3}
MAX_WAIT=${MAX_WAIT:-420}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LOGS="$ROOT/tests/logs/${SCEN}_${HUMANS}p_${BOTS}b"
TOTAL=$((HUMANS + BOTS))
mkdir -p "$LOGS"
rm -f "$LOGS"/*.log

declare -A PIDS
FAILS=()

fail() { FAILS+=("$1"); echo "  ✗ $1"; }
ok()   { echo "  ✓ $1"; }

launch() {  # launch <nombre> <args...>
  local name=$1; shift
  "$GODOT" --headless --path "$ROOT" -- "$@" --log --autopilot --timescale="$TS" > "$LOGS/$name.log" 2>&1 &
  PIDS[$name]=$!
}

alive() { kill -0 "${PIDS[$1]}" 2>/dev/null; }

kill_instance() { kill -9 "${PIDS[$1]}" 2>/dev/null; }

# Espera (con tiempo máximo) a que aparezca un texto en el log de una instancia.
wait_for_log() {  # wait_for_log <nombre> <regex> <segundos>
  local end=$((SECONDS + $3))
  while (( SECONDS < end )); do
    grep -qE "$2" "$LOGS/$1.log" 2>/dev/null && return 0
    sleep 0.5
  done
  return 1
}

# Espera a que terminen todas las instancias dadas.
wait_exit() {  # wait_exit <nombres...>
  local end=$((SECONDS + MAX_WAIT))
  while (( SECONDS < end )); do
    local running=0
    for n in "$@"; do alive "$n" && running=1; done
    (( running == 0 )) && return 0
    sleep 1
  done
  return 1
}

cleanup() { for n in "${!PIDS[@]}"; do kill -9 "${PIDS[$n]}" 2>/dev/null; done; }
trap cleanup EXIT

launch_host() {
  launch host --host --name=Host --players="$TOTAL" --games="$GAMES" --bots="$BOTS" --quit-at-end
}
launch_client() {  # launch_client <i>
  launch "c$1" --join=127.0.0.1 --name="Cli$1" --quit-at-end
}
launch_clients() {
  for ((i = 2; i <= HUMANS; i++)); do launch_client "$i"; sleep 0.4; done
}

echo "== Online: $HUMANS humanos + $BOTS bots, $GAMES minijuegos, escenario '$SCEN' (x$TS) =="
launch_host
sleep 3
CLIENTS=()
for ((i = 2; i <= HUMANS; i++)); do CLIENTS+=("c$i"); done
SURVIVORS=(host "${CLIENTS[@]}")

case "$SCEN" in
  normal)
    launch_clients
    wait_exit "${SURVIVORS[@]}" || fail "timeout esperando el final de la partida"
    ;;
  kill_in_lobby)
    launch "ghost" --join=127.0.0.1 --name=Ghost --quit-at-end
    wait_for_log host 'roster n=. humans=2|roster n=.. humans=2' 15 || fail "el host no vio entrar al fantasma"
    sleep 1
    kill_instance ghost
    wait_for_log host 'peer_left removed' 20 && ok "el host detectó la caída en el lobby" || fail "el host no detectó la caída en el lobby"
    launch_clients
    wait_exit "${SURVIVORS[@]}" || fail "timeout esperando el final de la partida"
    ;;
  kill_in_game)
    (( HUMANS >= 2 )) || { echo "kill_in_game necesita >= 2 humanos"; exit 2; }
    launch_clients
    wait_for_log host 'state=PLAYING' 90 || fail "la partida no llegó a PLAYING"
    sleep 4
    kill_instance c2
    SURVIVORS=(host "${CLIENTS[@]:1}")
    wait_for_log host 'replaced_by_bot' 30 && ok "el host sustituyó al desconectado por un bot" || fail "el host no sustituyó al desconectado"
    wait_exit "${SURVIVORS[@]}" || fail "timeout: la partida se quedó bloqueada tras la caída"
    ;;
  kill_host)
    (( HUMANS >= 2 )) || { echo "kill_host necesita >= 2 humanos"; exit 2; }
    launch_clients
    wait_for_log host 'state=PLAYING' 90 || fail "la partida no llegó a PLAYING"
    sleep 4
    kill_instance host
    for c in "${CLIENTS[@]}"; do
      wait_for_log "$c" 'host_lost' 30 && ok "$c volvió al menú tras caer el host" || fail "$c no detectó la caída del host"
    done
    exit_code=0
    [[ ${#FAILS[@]} -gt 0 ]] && exit_code=1
    echo
    [[ $exit_code -eq 0 ]] && echo "ONLINE TEST OK ($SCEN)" || echo "ONLINE TEST FALLÓ ($SCEN)"
    exit $exit_code
    ;;
  late_join)
    launch_clients
    wait_for_log host 'state=INTRO' 90 || fail "la partida no empezó"
    launch "late" --join=127.0.0.1 --name=Tarde --quit-at-end
    wait_for_log late 'join_rejected' 20 && ok "el cliente tardío fue rechazado" || fail "el cliente tardío no fue rechazado"
    kill_instance late
    wait_exit "${SURVIVORS[@]}" || fail "timeout esperando el final de la partida"
    ;;
  *)
    echo "escenario desconocido: $SCEN"; exit 2 ;;
esac

# ---------------------------------------------------------------- verificación ---
echo "-- Verificación --"
FINAL_HOST=$(grep -h "final scores=" "$LOGS/host.log" | tail -1 | sed 's/.*final scores=//')
if [[ -z "$FINAL_HOST" ]]; then
  fail "el host no llegó a la pantalla final"
else
  ok "el host llegó a la pantalla final: $FINAL_HOST"
  P=$(grep -c "state=PLAYING" "$LOGS/host.log")
  [[ "$P" -eq "$GAMES" ]] && ok "el host jugó $GAMES minijuegos" || fail "el host jugó $P minijuegos (esperados $GAMES)"
  # El host debió simular y recibir entrada de los clientes en cada minijuego.
  if (( HUMANS >= 2 )); then
    BAD=$(grep "mg_session" "$LOGS/host.log" | grep -c "snapshots_sent=0 ")
    [[ "$BAD" -eq 0 ]] && ok "el host envió snapshots en todos los minijuegos" || fail "algún minijuego no envió snapshots"
    NOIN=$(grep "mg_session" "$LOGS/host.log" | grep -c "inputs_applied=0$")
    [[ "$NOIN" -eq 0 ]] && ok "el host recibió entrada de clientes en todos los minijuegos" || fail "algún minijuego no recibió entrada de clientes"
  fi
fi
for n in "${SURVIVORS[@]}"; do
  [[ "$n" == host ]] && continue
  F=$(grep -h "final scores=" "$LOGS/$n.log" | tail -1 | sed 's/.*final scores=//')
  if [[ -z "$F" ]]; then
    fail "$n no llegó a la pantalla final"
    continue
  fi
  [[ "$F" == "$FINAL_HOST" ]] && ok "$n: clasificación final idéntica a la del host" || fail "$n: clasificación distinta ($F vs $FINAL_HOST)"
  BADC=$(grep "mg_session" "$LOGS/$n.log" | grep -c "snapshots_applied=0 ")
  CNT=$(grep -c "mg_session" "$LOGS/$n.log")
  [[ "$BADC" -eq 0 && "$CNT" -ge "$GAMES" ]] && ok "$n: recibió snapshots en los $GAMES minijuegos" || fail "$n: snapshots insuficientes ($CNT sesiones, $BADC sin snapshots)"
done
# Errores de script en cualquier instancia.
# En los escenarios con caídas el motor puede quejarse al enviar a un peer que se está
# yendo ("Unable to send packet"): es ruido esperado de ENet, no un fallo del juego.
IGNORE="^$"
case "$SCEN" in kill_*|late_join) IGNORE="Unable to send packet" ;; esac
BADLOGS=()
for f in "$LOGS"/*.log; do
  if grep -E "SCRIPT ERROR|^ERROR:" "$f" | grep -vqE "$IGNORE"; then BADLOGS+=("$(basename "$f")"); fi
done
if [[ ${#BADLOGS[@]} -gt 0 ]]; then
  fail "hay errores en: ${BADLOGS[*]}"
  for b in "${BADLOGS[@]}"; do grep -E "SCRIPT ERROR|^ERROR:" -A2 "$LOGS/$b" | grep -vE "$IGNORE" | head -8; done
else
  ok "sin errores de script en ninguna instancia"
fi

echo
if [[ ${#FAILS[@]} -eq 0 ]]; then
  echo "ONLINE TEST OK ($HUMANS humanos + $BOTS bots, $SCEN)"
  exit 0
else
  echo "ONLINE TEST FALLÓ ($SCEN): ${#FAILS[@]} problema(s)"
  exit 1
fi
