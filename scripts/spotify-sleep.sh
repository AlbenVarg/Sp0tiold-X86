#!/usr/bin/env bash
# spotify-sleep.sh - modo dormir para el NBRiq
#
# El reloj se reinicia solo por un bug del kernel al entrar en reposo con
# conexiones TCP abiertas y poca RAM (ver docs/FINDINGS.md seccion 10).
# Este script cierra Spotify y apaga la WiFi antes de quitarte el reloj,
# y lo revierte cuando vuelves.
#
# Uso:
#   ./scripts/spotify-sleep.sh on        # a dormir: cierra Spotify + WiFi off
#   ./scripts/spotify-sleep.sh off       # despertar: WiFi on + abre Spotify
#   ./scripts/spotify-sleep.sh status    # como esta ahora
#   ./scripts/spotify-sleep.sh on --dry-run   # solo enseña lo que haria
#
# Nota: si estas conectado por `adb connect` (WiFi), al hacer `on` pierdes adb.
#       Vuelve a conectar cuando el reloj tenga WiFi otra vez, o usa USB.
set -uo pipefail

ADB="${ADB:-adb}"
PKG="com.spotify.music"
ACT="$PKG/com.spotify.wear.main.MainActivity"

DRY=0
ARGS=()
for a in "$@"; do
  case "$a" in
    --dry-run|-n) DRY=1 ;;
    *) ARGS+=("$a") ;;
  esac
done
CMD="${ARGS[0]:-}"

die() { echo "ERROR: $*" >&2; exit 1; }

wifi_state() {
  local v
  v=$($ADB shell settings get global wifi_on 2>/dev/null | tr -d '\r')
  case "$v" in
    1) echo "encendida" ;;
    0) echo "apagada" ;;
    *) echo "desconocido ($v)" ;;
  esac
}
sp_state() {
  if $ADB shell ps 2>/dev/null | tr -d '\r' | grep -q "$PKG"; then
    echo "en marcha"
  else
    echo "parado"
  fi
}

run() {
  if [ "$DRY" = 1 ]; then echo "  [dry-run] $*"; else $ADB shell "$@"; fi
}

$ADB devices 2>/dev/null | grep -qw device || die "no hay reloj conectado (adb devices)"

case "$CMD" in
  on)
    [ "$DRY" = 1 ] || echo "Cerrando Spotify y apagando WiFi..."
    run am force-stop "$PKG"
    run svc wifi disable
    if [ "$DRY" = 0 ]; then
      sleep 2
      echo
      echo "Listo. WiFi: $(wifi_state) | Spotify: $(sp_state)"
      echo "Aviso: si estabas por WiFi, adb se ha cortado."
    fi
    ;;
  off)
    [ "$DRY" = 1 ] || echo "Encendiendo WiFi y abriendo Spotify..."
    run svc wifi enable
    [ "$DRY" = 1 ] || sleep 4
    run am start -n "$ACT"
    if [ "$DRY" = 0 ]; then
      sleep 2
      echo
      echo "WiFi: $(wifi_state) | Spotify: $(sp_state)"
    fi
    ;;
  status|"")
    echo "WiFi:    $(wifi_state)"
    echo "Spotify: $(sp_state)"
    echo "RAM:     $(run cat /proc/meminfo | grep MemFree | sed 's/  */ /g')"
    echo "Reinicios por watchdog: $(run getprop ro.boot.bootreason)"
    ;;
  *)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
