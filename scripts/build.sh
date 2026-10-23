#!/usr/bin/env bash
# Sp0tiold-X86 - pipeline completo: APK de Spotify Wear (minSdk 28) -> APK para API 25 / x86
#
# Uso:  ./scripts/build.sh <spotify-wear.apk> [minSdk]
#
# Variables de entorno (opcionales):
#   TOOLS        dir con baksmali.jar / smali.jar / desugar_jdk_libs-2.1.5.jar  (def: ./tools)
#   BAKSMALI     ruta a baksmali.jar
#   SMALI        ruta a smali.jar
#   DESUGAR_JAR  ruta a desugar_jdk_libs jar
#   BT           dir de android build-tools (zipalign/apksigner/dexdump/d8)
#   KS           keystore (se crea si no existe)
#   OUT          APK de salida
#   KEEP_ABIS    ABIs a conservar, separadas por comas (def: x86; "" = todas).
#                El NBRiq es x86 puro: dejando solo x86 el APK baja de ~42 a ~18 MB.
set -euo pipefail

SRC="${1:?uso: build.sh <spotify-wear.apk> [minSdk]}"
TARGET_SDK="${2:-25}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="${TOOLS:-$HERE/tools}"
BAKSMALI="${BAKSMALI:-$TOOLS/baksmali.jar}"
SMALI="${SMALI:-$TOOLS/smali.jar}"
DESUGAR_JAR="${DESUGAR_JAR:-$TOOLS/desugar_jdk_libs-2.1.5.jar}"
KS="${KS:-$TOOLS/debug.jks}"

if [ -z "${BT:-}" ]; then
  for c in /opt/homebrew/share/android-commandlinetools/build-tools/* \
           "$HOME/Library/Android/sdk/build-tools/"* \
           /usr/lib/android-sdk/build-tools/*; do
    [ -x "$c/apksigner" ] && BT="$c"
  done
fi
BT="${BT:?no encuentro build-tools (define BT=/ruta/build-tools/X.Y.Z)}"

WORK="$HERE/build"
OUT="${OUT:-$WORK/spotify-wear-api${TARGET_SDK}.apk}"
mkdir -p "$WORK"

for f in "$BAKSMALI" "$SMALI" "$DESUGAR_JAR"; do
  [ -f "$f" ] || { echo "ERROR: falta $f" >&2; exit 1; }
done

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- 1) minSdk
step "1/6 minSdkVersion -> $TARGET_SDK"
python3 "$HERE/scripts/patch_minsdk.py" "$SRC" "$WORK/step1-minsdk.apk" "$TARGET_SDK"

# ------------------------------------------------------- 2) dex de desugar
step "2/6 clases de desugar (java.time / java.nio.file -> nbrt/*)"
python3 "$HERE/scripts/build_desugar.py" "$DESUGAR_JAR" "$WORK/desugar-subset.jar"
rm -rf "$WORK/dexout"
mkdir -p "$WORK/dexout"
"$BT/d8" --min-api "$TARGET_SDK" --output "$WORK/dexout" "$WORK/desugar-subset.jar"

# ------------------------------------------------------------- 3) baksmali
step "3/6 baksmali del classes.dex"
rm -rf "$WORK/dex" "$WORK/smali"
mkdir -p "$WORK/dex"
unzip -o -q "$WORK/step1-minsdk.apk" classes.dex -d "$WORK/dex"
java -Xmx3g -jar "$BAKSMALI" d "$WORK/dex/classes.dex" -o "$WORK/smali"

# --------------------------------------------------------------- 4) parches
step "4/6 helper nbrt.compat.Notif + renombrado + call sites API 26+"
cp -r "$HERE/smali/nbrt" "$WORK/smali/"
find "$WORK/smali" -name '*.smali' -print0 | xargs -0 perl -pi -e \
  's{Ljava/time/}{Lnbrt/time/}g; s{Ljava/nio/file/}{Lnbrt/nio/file/}g'
python3 "$HERE/scripts/patch_smali.py" "$WORK/smali"

# comprobacion: no deben quedar simbolos de API 26+ (grep devuelve 1 si no
# encuentra nada; con pipefail eso mataria el script, de ahi el "|| true")
LEFTOVER=0
check_sym() {  # check_sym <simbolo> <maximo_permitido>
  local sym="$1" max="${2:-0}" n
  n=$(grep -rl -- "$sym" "$WORK/smali" 2>/dev/null | wc -l) || true
  n=$(echo "$n" | tr -d ' ')
  if [ "$n" -gt "$max" ]; then
    echo "  AVISO: quedan $n ficheros con $sym (max esperado: $max)"
    LEFTOVER=1
  fi
  return 0
}
check_sym 'Landroid/os/VibrationEffect;->'
check_sym 'startForegroundService'
check_sym 'NotificationManager;->getNotificationChannel'
# NotificationChannel como tipo solo debe quedar en el helper y en las 3 lineas
# invoke-static que lo usan como tipo de retorno (ForegroundMediaService,
# DownloadWorkerImpl, Q3/d)
check_sym 'Landroid/app/NotificationChannel;' 4

# ------------------------------------------------------------- 5) smali
step "5/6 reensamblado (smali, api $TARGET_SDK)"
java -Xmx4g -jar "$SMALI" a "$WORK/smali" -o "$WORK/classes-patched.dex" -a "$TARGET_SDK"
"$BT/dexdump" -f "$WORK/classes-patched.dex" > "$WORK/dexdump.txt" 2>&1 || true
grep -q "DEX version" "$WORK/dexdump.txt" || { echo "ERROR: dexdump no pudo abrir el dex" >&2; exit 1; }

# --------------------------------------------------- 6) repack + firmar
step "6/6 repack + zipalign + apksigner"
python3 "$HERE/scripts/repack_apk2.py" "$WORK/step1-minsdk.apk" "$WORK/unaligned.apk" \
        "$WORK/classes-patched.dex" "$WORK/dexout/classes.dex" "${KEEP_ABIS-x86}"
"$BT/zipalign" -f -p 4 "$WORK/unaligned.apk" "$OUT"
if [ ! -f "$KS" ]; then
  keytool -genkeypair -keystore "$KS" -alias android -storepass android \
          -keypass android -dname "CN=Sp0tiold" -keyalg RSA -keysize 2048 \
          -validity 10000 >/dev/null 2>&1
fi
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android "$OUT"
"$BT/apksigner" verify "$OUT"

echo
echo "OK -> $OUT"
[ "$LEFTOVER" = "1" ] && echo "AVISO: revisa los simbolos listados arriba antes de instalar."
echo "Instalar:  adb install -r \"$OUT\""
