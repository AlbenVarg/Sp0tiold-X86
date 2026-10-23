#!/usr/bin/env bash
# reinstall-keep-data.sh - cambia el APK de Spotify sin perder la sesion
#
# El APK que esta puesto en el reloj se firmo con otra clave distinta a
# tools/debug.jks, asi que Android no deja hacer `adb install -r` (firma
# distinta). Sin root eso obligaria a emparejar otra vez con el movil.
# Con root se puede: se guarda /data/data/com.spotify.music, se reinstala y se
# devuelve en su sitio (uid + contexto SELinux incluidos).
#
# Lo que aprendimos usandolo en el NBRiq (ver docs/FINDINGS.md 11):
#   * `tar -xzf` NO funciona en el reloj (toybox tar no tiene gunzip).
#     Por eso se descomprime en el Mac y se copia el arbol con `cp -r`.
#   * `cp -a` falla (intenta restaurar el contexto SELinux y no puede).
#   * En esta ROM `su -c` corre en el dominio shell, al que SELinux no le deja
#     crear ficheros en /data/data. Se arregla en caliente con magiskpolicy.
#
# Uso:
#   ./scripts/reinstall-keep-data.sh build/spotify-wear-api25.apk
#   ./scripts/reinstall-keep-data.sh --rollback        # vuelve al APK anterior
#
# Requiere: root (Magisk) en el reloj y `adb`.
set -uo pipefail

ADB="${ADB:-adb}"
PKG="com.spotify.music"
ACT="$PKG/com.spotify.wear.main.MainActivity"
TMP="${TMPDIR:-/tmp}"
WORK="$TMP/sp0tiold-reinstall"
BACKUP_OLD_APK="$TMP/sp0tiold-old.apk"
BACKUP_TGZ="$TMP/spotify-data.tgz"

die() { echo "ERROR: $*" >&2; exit 1; }
sh_() { $ADB shell "$@" | tr -d '\r'; }
su_() { $ADB shell "su -c \"$1\"" | tr -d '\r'; }

need_root() { [ "$(su_ 'id -u')" = "0" ] || die "hace falta root (Magisk) en el reloj"; }

# --- SELinux: deja que el dominio shell escriba en /data/data (en caliente) ---
fix_selinux() {
  cat > "$WORK/fixpolicy.sh" <<'EOS'
#!/system/bin/sh
MP=/data/adb/magisk/magiskpolicy
for DOM in shell magisk; do
  "$MP" --live \
    "allow $DOM system_data_file dir { create write read search setattr add_name remove_name rmdir }" \
    "allow $DOM system_data_file file { create write read getattr setattr unlink rename }" \
    "allow $DOM system_data_file lnk_file { create read getattr setattr unlink }" \
    "allow $DOM app_data_file dir { create write read search setattr add_name remove_name rmdir }" \
    "allow $DOM app_data_file file { create write read getattr setattr unlink rename }" \
    "allow $DOM app_data_file lnk_file { create read getattr setattr unlink }" >/dev/null 2>&1
done
EOS
  $ADB push "$WORK/fixpolicy.sh" /data/local/tmp/fixpolicy.sh >/dev/null || die "no pude subir fixpolicy.sh"
  su_ "sh /data/local/tmp/fixpolicy.sh"
}

# --- devuelve el arbol de $WORK/data a /data/data/$PKG ---
restore_data() {
  local uid appdir
  su_ "am force-stop $PKG"
  uid=$(sh_ dumpsys package "$PKG" | grep -m1 'userId=' | cut -d= -f2)
  appdir=$(sh_ pm path "$PKG" | sed 's|package:||; s|/base.apk||')
  [ -n "$uid" ] && [ -n "$appdir" ] || die "no pude leer uid/ruta de $PKG"

  $ADB shell "rm -rf /data/local/tmp/spdata" >/dev/null
  $ADB push "$WORK/data/$PKG" /data/local/tmp/spdata/ >/dev/null 2>&1 || true
  su_ "rm -rf /data/data/$PKG; cp -r /data/local/tmp/spdata/$PKG /data/data/ || exit 1"
  su_ "ln -sfn $appdir/lib/x86 /data/data/$PKG/lib"
  su_ "chown -R $uid:$uid /data/data/$PKG"
  su_ "chmod 771 /data/data/$PKG"
  su_ "restorecon -R /data/data/$PKG >/dev/null 2>&1"
  echo "  datos restaurados (uid $uid, lib -> $appdir/lib/x86)"
}

backup_data() {
  echo "  APK actual  -> $BACKUP_OLD_APK"
  local p
  p=$(sh_ pm path "$PKG" | sed 's/package://')
  $ADB shell "su -c 'cat $p'" > "$BACKUP_OLD_APK" || die "no pude copiar el APK actual"
  [ -s "$BACKUP_OLD_APK" ] || die "la copia del APK salio vacia"

  su_ "tar -czf /sdcard/spotify-data.tgz -C /data/data $PKG" || die "no pude comprimir los datos"
  $ADB pull /sdcard/spotify-data.tgz "$BACKUP_TGZ" >/dev/null || die "no pude traer los datos al Mac"
  $ADB shell "rm -f /sdcard/spotify-data.tgz" >/dev/null

  rm -rf "$WORK/data"; mkdir -p "$WORK/data"
  gzip -dc "$BACKUP_TGZ" | tar -xf - -C "$WORK/data" || die "no pude descomprimir la copia"
  rm -f "$WORK/data/$PKG/lib"          # symlink absoluto: se recrea en el reloj
  echo "  datos       -> $BACKUP_TGZ ($(du -h "$BACKUP_TGZ" | cut -f1))"
}

$ADB devices | grep -qw device || die "no hay reloj conectado"
mkdir -p "$WORK"
need_root
fix_selinux

if [ "${1:-}" = "--rollback" ]; then
  [ -f "$BACKUP_OLD_APK" ] || die "no tengo copia del APK anterior ($BACKUP_OLD_APK)"
  [ -f "$BACKUP_TGZ" ]     || die "no tengo copia de los datos ($BACKUP_TGZ)"
  rm -rf "$WORK/data"; mkdir -p "$WORK/data"
  gzip -dc "$BACKUP_TGZ" | tar -xf - -C "$WORK/data" || die "copia de datos ilegible"
  rm -f "$WORK/data/$PKG/lib"
  sh_ pm uninstall "$PKG" >/dev/null
  $ADB install -r "$BACKUP_OLD_APK" || die "no pude instalar el APK anterior"
  restore_data
  sh_ am start -n "$ACT" >/dev/null
  echo "Hecho: APK y datos de antes."
  exit 0
fi

NEW_APK="${1:?uso: $0 <apk-nuevo> | --rollback}"
[ -f "$NEW_APK" ] || die "no existe $NEW_APK"

echo "== 1) copia de seguridad =="
backup_data

echo "== 2) desinstalar e instalar el nuevo =="
sh_ pm uninstall "$PKG" >/dev/null || echo "  (aviso: pm uninstall devolvio error, sigo)"
$ADB install -r "$NEW_APK" || die "no pude instalar $NEW_APK"

echo "== 3) devolver los datos =="
restore_data

echo "== 4) arrancar Spotify =="
sh_ am start -n "$ACT" >/dev/null
sleep 4
echo "  $(sh_ dumpsys package "$PKG" | grep -m1 versionName | sed 's/^ *//')"
echo
echo "Comprueba en el reloj que la sesion sigue iniciada y que carga la home."
echo "Si algo fue mal:  $0 --rollback"

