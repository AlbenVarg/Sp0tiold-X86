#!/usr/bin/env bash
# Descarga las herramientas necesarias en tools/. Solo hay que ejecutarlo una vez.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="$HERE/tools"
mkdir -p "$TOOLS"

SMALI_VER="3.0.10"
DESUGAR_VER="2.1.5"

base="https://github.com/baksmali/smali/releases/download/$SMALI_VER"

dl() {  # dl <url> <destino>
  if [ -f "$2" ]; then
    echo "  ya existe: $(basename "$2")"
  else
    echo "  descargando $(basename "$2") ..."
    curl -fL --retry 3 -o "$2.part" "$1"
    mv "$2.part" "$2"
  fi
}

echo "==> baksmali $SMALI_VER"
dl "$base/baksmali-$SMALI_VER-fat.jar" "$TOOLS/baksmali.jar"

echo "==> smali $SMALI_VER"
dl "$base/smali-$SMALI_VER-fat.jar" "$TOOLS/smali.jar"

echo "==> desugar_jdk_libs $DESUGAR_VER"
dl "https://maven.google.com/com/android/tools/desugar_jdk_libs/$DESUGAR_VER/desugar_jdk_libs-$DESUGAR_VER.jar" \
   "$TOOLS/desugar_jdk_libs-$DESUGAR_VER.jar"

echo
echo "Herramientas listas en $TOOLS:"
ls -1 "$TOOLS"/*.jar

echo
echo "Comprobando java y python3..."
java -version 2>&1 | head -1 || echo "  FALTA java (instala un JDK 17)"
python3 --version || echo "  FALTA python3"
