#!/usr/bin/env bash
# diag-reboot.sh - ¿por qué se reinicia mi reloj?
#
# Lee del propio reloj la causa del ultimo reinicio (watchdog del kernel,
# crash de una app, apagon...) y da un veredicto en lenguaje claro.
# Funciona sin root, pero con root (Magisk) da mucha mas informacion.
#
# Uso:  ./scripts/diag-reboot.sh
set -uo pipefail

ADB="${ADB:-adb}"
TMP="${TMPDIR:-/tmp}/sp0tiold-diag"
mkdir -p "$TMP"

hdr() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
sh_() { $ADB shell "$@" 2>/dev/null; }
# root opcional (Magisk): algunos relojes piden confirmacion en pantalla
root_() { $ADB shell su -c "$1" 2>/dev/null; }

ts() {  # epoch en milisegundos -> fecha local
  local s=$(( $1 / 1000 ))
  if date -r "$s" +%s >/dev/null 2>&1; then date -r "$s" '+%Y-%m-%d %H:%M'
  else date -d "@$s" '+%Y-%m-%d %H:%M'; fi
}

$ADB devices | grep -qw device || { echo "No hay reloj conectado (revisa: adb devices)"; exit 1; }

ROOT=0
[ "$(root_ id | head -1)" = "uid=0(root) gid=0(root) context=u:r:magisk:s0" ] && ROOT=1
[ "$(root_ id | grep -c 'uid=0')" -ge 1 ] && ROOT=1

hdr "1. Motivo del ultimo arranque"
BR="$(sh_ getprop ro.boot.bootreason)"
echo "ro.boot.bootreason = ${BR:-<vacio>}"
case "$BR" in
  watchdog)
    echo "  -> Lo reinicio el WATCHDOG de hardware: el kernel/SoC se quedo colgado."
    echo "     NO es un crash de la app (un crash de app no reinicia el reloj)." ;;
  kernel_panic|panic|oops)
    echo "  -> El kernel hizo panic/oops. Mira la seccion 3." ;;
  power_on|""|hard)
    echo "  -> Arranque normal (boton de encendido o bateria)." ;;
  *) echo "  -> $BR" ;;
esac
UP="$(sh_ cat /proc/uptime | cut -d' ' -f1)"
if [ -n "$UP" ]; then
  M=$(( ${UP%.*} / 60 ))
  echo "Encendido desde hace $(( M / 60 )) h $(( M % 60 )) min"
fi

hdr "2. Historial de arranques (dropbox)"
if [ "$ROOT" = 1 ]; then
  root_ 'ls /data/system/dropbox' | grep 'SYSTEM_BOOT@' | sed 's/.*@//; s/\.txt//' | sort -n > "$TMP/boots.txt"
  N=$(wc -l < "$TMP/boots.txt" | tr -d ' ')
  echo "$N arranques registrados (mas recientes al final):"
  tail -8 "$TMP/boots.txt" | while read -r t; do [ -n "$t" ] && echo "  $(ts "$t")"; done
  echo "(historial completo en $TMP/boots.txt)"
  echo
  echo "Ultimos eventos del sistema:"
  root_ 'ls -t /data/system/dropbox' | grep -E 'SYSTEM_RESTART|system_server_crash|data_app_crash|system_server_watchdog' |
    head -6 | sed 's/.*/  &/'
else
  echo "sin root: no puedo leer /data/system/dropbox"
fi

hdr "3. Log del kernel del reinicio (pstore/ramoops)"
if [ "$ROOT" = 1 ] && [ -n "$(root_ 'ls /sys/fs/pstore' | grep ramoops)" ]; then
  for f in dmesg-ramoops-0 console-ramoops-0; do
    root_ "cat /sys/fs/pstore/$f" > "$TMP/$f.txt" 2>/dev/null
  done
  HITS=$(grep -hcE 'Oops|WARNING:|Kernel panic|BUG:' "$TMP"/*ramoops*.txt 2>/dev/null | paste -sd+ - | bc 2>/dev/null)
  echo "Capturado: $(ls -1 "$TMP" | grep ramoops | paste -sd' ' -)"
  echo "Fallos del kernel encontrados: ${HITS:-0}"
  for f in "$TMP"/dmesg-ramoops-0.txt "$TMP"/console-ramoops-0.txt; do
    [ -s "$f" ] || continue
    echo
    echo "--- $(basename "$f") ---"
    grep -E 'Oops|WARNING:|Kernel panic|BUG:' "$f" | head -3 | cut -c1-150
    # el culpable suele estar al FINAL del console log (momento del cuelgue)
    SRC="$f"
    case "$f" in *console-ramoops*) SRC="$TMP/console-tail.txt"; tail -80 "$f" > "$SRC" ;; esac
    CULP=$(grep -oE 'ipt_do_table|nf_conntrack_in|tcp_rtx_synack|i2c_dw_xfer|mmc_[a-z_]+|ext4_[a-z_]+' "$SRC" |
           sort -u | paste -sd' ' -)
    [ -n "$CULP" ] && echo "indicios en el stack: $CULP"
  done
  echo
  echo "Interpretacion rapida:"
  echo "  ipt_do_table / nf_conntrack / tcp_*  -> bug del ROM en el filtrado de red"
  echo "                                         DURANTE el suspend (WiFi activa)"
  echo "  i2c_dw_xfer / max170                 -> bug del ROM en el driver I2C/bateria"
  echo "  mmc_ / ext4_                         -> problema del almacenamiento (eMMC)"
  echo "  (vacio)                              -> sin rastro: apagon o fallo de bateria"
else
  echo "sin root o sin pstore: no hay log del kernel del reinicio anterior"
fi

hdr "4. Estado ahora mismo"
echo "RAM:"
sh_ cat /proc/meminfo | grep -E 'MemTotal|MemFree|SwapFree' | sed 's/^/  /'
echo "Conexiones TCP de Spotify (uid 10045):"
root_ 'cat /proc/net/tcp6' | grep -c ' 10045 ' | sed 's/^/  sockets: /'
echo "  (si hay muchas y el reloj se reinicia al dormir, ver docs/FINDINGS.md seccion 10)"

hdr "Veredicto"
if [ "$BR" = "watchdog" ]; then
  cat <<'EOF'
El reloj se reinicia por el watchdog del hardware, no por un crash de la app.
Suele pasar al entrar en suspend (pantalla apagada) mientras hay trafico de red:
un bug del kernel del ROM (netfilter/I2C) cuelga el SoC y el watchdog lo resetea.
Pruebas utiles:
  1) Un dia con WiFi apagada (solo Bluetooth): si no se reinicia, es el bug de red.
  2) Un dia sin Spotify: si sigue reiniciandose, es del ROM y no de la app.
  3) Modo offline de Spotify: menos sockets abiertos -> menos disparos.
EOF
else
  echo "Sin sintomas de watchdog en este arranque. Si se reinicia, vuelve a ejecutar este script."
fi
echo
