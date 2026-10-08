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

# Mata el proceso Y sus hijos (el ejecutable "console" de Godot lanza otro proceso: matar solo
# el envoltorio dejaría el juego real huérfano ocupando el puerto).
kill_tree() {
  local w
  w=$(cat "/proc/$1/winpid" 2>/dev/null) || w=$1
  taskkill //F //T //PID "$w" >/dev/null 2>&1
  kill -9 "$1" 2>/dev/null
}
kill_instance() { kill_tree "${PIDS[$1]}"; }

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

cleanup() { for n in "${!PIDS[@]}"; do kill_tree "${PIDS[$n]}"; done; }
trap cleanup EXIT

launch_host() {
  launch host --host --name=Host --players="$TOTAL" --games="$GAMES" --bots="$BOTS" --quit-at-end ${ONLY:+--only=$ONLY}
}
launch_client() {  # launch_client <i>
  launch "c$1" --join=127.0.0.1 --name="Cli$1" --quit-at-end
}
launch_clients() {
  for ((i = 2; i <= HUMANS; i++)); do launch_client "$i"; sleep 0.4; done
}

# Comprobación previa: si el puerto está ocupado, un proceso huérfano contaminaría la prueba.
if netstat -ano -p UDP 2>/dev/null | grep -q ":24680 "; then
  echo "ERROR: el puerto UDP 24680 está ocupado (¿instancias de Godot huérfanas de otra ejecución?)"; exit 3
fi

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
  kill_in_game|kill_in_parallel)
    (( HUMANS >= 2 )) || { echo "kill_in_game necesita >= 2 humanos"; exit 2; }
    launch_clients
    PLAYING_RE='state=PLAYING'; [[ "$SCEN" == kill_in_parallel ]] && PLAYING_RE='state=PLAYING index=[0-9]+ mg=(reaction_test|cube_dash|wave_dash)'
    wait_for_log host "$PLAYING_RE" 120 || fail "la partida no llegó al minijuego esperado"
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
  # HOST_AUTHORITATIVE: el host debió simular y recibir entrada de los clientes en cada minijuego.
  HA_HOST=$(grep "mg_session mode=HOST_AUTHORITATIVE" "$LOGS/host.log")
  HA_N=$(echo -n "$HA_HOST" | grep -c "mg_session")
  if (( HUMANS >= 2 && HA_N > 0 )); then
    BAD=$(echo "$HA_HOST" | grep -c "snapshots_sent=0 ")
    [[ "$BAD" -eq 0 ]] && ok "[HOST_AUTH] el host envió snapshots en los $HA_N minijuegos de ese modelo" || fail "algún minijuego HOST_AUTH no envió snapshots"
    NOIN=$(echo "$HA_HOST" | grep -c "inputs_applied=0 ")
    if [[ "$SCEN" == kill_in_game && "$HUMANS" -le 2 ]]; then
      # Con 2 humanos, tras caer el único cliente ya no queda a quién escuchar: basta con el primero.
      (( NOIN < HA_N )) && ok "[HOST_AUTH] el host recibió entrada del cliente mientras estuvo conectado" || fail "el host no recibió entrada del cliente"
    else
      [[ "$NOIN" -eq 0 ]] && ok "[HOST_AUTH] el host recibió entrada de clientes en todos los minijuegos" || fail "algún minijuego HOST_AUTH no recibió entrada de clientes"
    fi
  fi
  # LOCAL_PARALLEL: el host debe haber recogido el resultado de TODOS los jugadores, sin "no terminados".
  LP_HOST=$(grep "mg_session mode=LOCAL_PARALLEL" "$LOGS/host.log")
  LP_N=$(echo -n "$LP_HOST" | grep -c "mg_session")
  if (( LP_N > 0 )); then
    LP_OK=$(echo "$LP_HOST" | grep -c "results=$TOTAL dnf=0$")
    [[ "$LP_OK" -eq "$LP_N" ]] && ok "[LOCAL_PARALLEL] el host recogió $TOTAL resultados (sin DNF) en los $LP_N minijuegos de ese modelo" || fail "[LOCAL_PARALLEL] resultados incompletos o DNF: $(echo "$LP_HOST" | tr '\n' '|')"
  fi
  # Cobertura: con 4 minijuegos salen los dos modelos.
  if (( GAMES >= 5 )); then
    grep -q "mg=reaction_test" "$LOGS/host.log" && ok "se jugó un minijuego LOCAL_PARALLEL (reaction_test)" || fail "no salió reaction_test"
    grep -q "mg=cube_dash" "$LOGS/host.log" && ok "se jugó el minijuego LOCAL_PARALLEL cube_dash" || fail "no salió cube_dash"
    grep -q "mg=shrinking_platform" "$LOGS/host.log" && ok "se jugó un minijuego HOST_AUTHORITATIVE" || fail "no salió shrinking_platform"
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
  CNT=$(grep -c "mg_session" "$LOGS/$n.log")
  BADC=$(grep "mg_session mode=HOST_AUTHORITATIVE" "$LOGS/$n.log" | grep -c "snapshots_applied=0 ")
  [[ "$BADC" -eq 0 && "$CNT" -ge "$GAMES" ]] && ok "$n: $CNT sesiones de minijuego; snapshots recibidos en todas las HOST_AUTH" || fail "$n: sesiones insuficientes o sin snapshots ($CNT sesiones, $BADC HOST_AUTH sin snapshots)"
  # En LOCAL_PARALLEL el cliente NO debe recibir estado de los demás (no se ven durante la prueba).
  LPBAD=$(grep "mg_session mode=LOCAL_PARALLEL" "$LOGS/$n.log" | grep -vc "snapshots_applied=0 ")
  [[ "$LPBAD" -eq 0 ]] && ok "$n: en LOCAL_PARALLEL no recibió ningún estado ajeno" || fail "$n: recibió estado ajeno en un minijuego LOCAL_PARALLEL"
done
# Un jugador caído NO puntúa: su puntuación no puede cambiar en ningún marcador posterior a la caída.
case "$SCEN" in kill_in_game|kill_in_parallel)
  DEAD_ID=$(grep -m1 "replaced_by_bot" "$LOGS/host.log" | sed 's/.*id=\([0-9]*\).*/\1/')
  if [[ -n "$DEAD_ID" ]]; then
    if awk -v id="$DEAD_ID" '
        /replaced_by_bot/ { dead = 1; next }
        /scoreboard scores=/ {
          match($0, /scores=[^ ]*/); s = substr($0, RSTART + 7, RLENGTH - 7)
          n = split(s, a, ","); v = 0
          for (i = 1; i <= n; i++) { split(a[i], kv, ":"); if (kv[1] == id) v = kv[2] }
          if (!dead) before = v; else if (v != before) bad = 1
        }
        END { exit bad }' "$LOGS/host.log"; then
      ok "el jugador caído (id $DEAD_ID) no sumó puntos tras desconectarse"
    else
      fail "el jugador caído (id $DEAD_ID) siguió puntuando tras desconectarse"
    fi
  fi ;;
esac
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
