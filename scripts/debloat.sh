#!/usr/bin/env bash
# debloat.sh - apaga apps de Google que el reloj no necesita
#
# El NBRiq tiene solo 455 MB de RAM: cada proceso de fondo cuenta. Este script
# desactiva (sin desinstalar) las apps de Google prescindibles y se puede
# revertir en cualquier momento con `restore`.
#
# Uso:
#   ./scripts/debloat.sh list                 # que hay instalado y que se tocaria
#   ./scripts/debloat.sh disable              # desactiva el set seguro
#   ./scripts/debloat.sh disable --with-optional   # + Fit, TTS y Recordatorios
#   ./scripts/debloat.sh restore              # vuelve a activar todo
#
# No toca NUNCA: GMS, GSF, la app Wear, SystemUI, Settings, teclado, reloj,
# ni el paquete de instalacion: sin ellos el reloj deja de funcionar.
set -uo pipefail

ADB="${ADB:-adb}"
CONF="${TMPDIR:-/tmp}/sp0tiold-debloat"
mkdir -p "$CONF"
STATE="$CONF/disabled.txt"   # paquetes que hemos desactivado nosotros

# Prescindibles: apps de usuario que no participan en el sistema ni en Spotify
SAFE=(
  com.google.android.googlequicksearchbox      # app "Google" (buscador/Asistente)
  com.google.android.music                     # Google Play Music (servicio muerto)
  com.google.android.apps.translate            # Traducir en el reloj
  com.google.android.apps.handwriting.ime      # teclado de escribir a mano
  com.google.android.apps.wearable.retailattractloop # demo de tienda en bucle
  com.google.android.clockwork.gestures.tutorial     # tutorial de gestos
  com.google.android.apps.wearable.bugreportsender   # enviar informes de fallos
)

# Opcionales: utiles para algunos, pero se pueden apagar si vas justo de RAM
OPTIONAL=(
  com.google.android.apps.fitness              # Google Fit (pasos)
  com.google.android.tts                       # sintesis de voz
  com.google.android.wearable.reminders         # recordatorios del movil
)

# Nunca tocar (por seguridad, aunque alguien edite las listas)
PROTECTED=(
  com.google.android.gms com.google.android.gsf com.android.vending
  com.google.android.wearable.app com.google.android.wearable.ambient
  com.google.android.apps.wearable.systemui com.google.android.apps.wearable.settings
  com.google.android.wearable.setupwizard com.google.android.deskclock
  com.google.android.inputmethod.latin com.google.android.packageinstaller
  com.google.android.ext.services com.google.android.ext.shared
  com.google.android.wearable.frameworkpackagestubs com.spotify.music
  com.topjohnwu.magisk dev.nbriq.wear.watchface
)

die() { echo "ERROR: $*" >&2; exit 1; }
sh_() { $ADB shell "$@" 2>/dev/null; }
su_() { $ADB shell su -c "$1" 2>/dev/null; }

installed() { sh_ pm list packages | sed 's/package://' | tr -d '\r' | grep -qx "$1"; }
is_disabled() { sh_ pm list packages -d | sed 's/package://' | tr -d '\r' | grep -qx "$1"; }
is_protected() { printf '%s\n' "${PROTECTED[@]}" | grep -qx "$1"; }

set_state() {  # $1 pkg, $2 enable|disable
  if [ "$2" = disable ]; then
    if su_ "pm disable-user --user 0 $1" | grep -qi 'new state'; then return 0; fi
    sh_ pm disable-user --user 0 "$1" >/dev/null && return 0
    sh_ pm hide "$1" >/dev/null && return 0
    return 1
  else
    su_ "pm enable $1" >/dev/null || sh_ pm enable "$1" >/dev/null
  fi
}

CMD="${1:-list}"
case "$CMD" in
  list)
    echo "== prescindibles =="
    for p in "${SAFE[@]}"; do
      if ! installed "$p"; then echo "  (no instalada)  $p"
      elif is_disabled "$p"; then echo "  ya desactivada  $p"
      else echo "  ACTIVA          $p"; fi
    done
    echo "== opcionales =="
    for p in "${OPTIONAL[@]}"; do
      if ! installed "$p"; then echo "  (no instalada)  $p"
      elif is_disabled "$p"; then echo "  ya desactivada  $p"
      else echo "  ACTIVA          $p"; fi
    done
    echo "== protegidas (no se tocan) =="
    echo "  ${#PROTECTED[@]} paquetes: GMS/Wear/SystemUI/teclado/reloj/Spotify/..."
    ;;
  disable)
    LIST=("${SAFE[@]}")
    [ "${2:-}" = "--with-optional" ] && LIST+=("${OPTIONAL[@]}")
    for p in "${LIST[@]}"; do
      if is_protected "$p"; then echo "  SALTO (protegida) $p"; continue; fi
      if ! installed "$p"; then echo "  (no instalada)    $p"; continue; fi
      if is_disabled "$p"; then echo "  ya estaba        $p"; grep -qx "$p" "$STATE" 2>/dev/null || echo "$p" >> "$STATE"; continue; fi
      if set_state "$p" disable; then
        echo "  desactivada       $p"
        grep -qx "$p" "$STATE" 2>/dev/null || echo "$p" >> "$STATE"
      else
        echo "  FALLO             $p (mira: adb shell pm list packages -d)"
      fi
    done
    echo
    echo "Estado guardado en $STATE (para poder revertir)."
    echo "RAM libre ahora: $(sh_ cat /proc/meminfo | grep MemFree | sed 's/  */ /g')"
    ;;
  restore)
    if [ -f "$STATE" ]; then
      while read -r p; do
        [ -n "$p" ] || continue
        set_state "$p" enable && echo "  reactivada $p"
      done < "$STATE"
      rm -f "$STATE"
    fi
    for p in "${SAFE[@]}" "${OPTIONAL[@]}"; do
      installed "$p" && is_disabled "$p" && set_state "$p" enable && echo "  reactivada $p"
    done
    echo "Listo: todo lo que apago este script vuelve a estar activo."
    echo "RAM libre ahora: $(sh_ cat /proc/meminfo | grep MemFree | sed 's/  */ /g')"
    ;;
  *)
    die "uso: $0 {list|disable [--with-optional]|restore}"
    ;;
esac
