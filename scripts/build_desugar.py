#!/usr/bin/env python3
"""Extrae de desugar_jdk_libs las clases necesarias para API < 26 y las renombra
a un prefijo propio de la MISMA longitud (java/time/ -> nbrt/time/), de modo que
el dex de la app pueda parchearse con un simple reemplazo binario de igual tamano.

Uso: python3 build_desugar.py desugar_jdk_libs.jar salida.jar
"""
import sys
import zipfile

# (prefijo original, prefijo nuevo) -- MISMA LONGITUD en bytes (requisito del parcheo)
RENAMES = [
    ('java/time/', 'nbrt/time/'),
    ('java/nio/file/', 'nbrt/nio/file/'),
]
# Paquetes no-java que se conservan tal cual (implementaciones del desugar)
KEEP_NON_JAVA = ('desugar/', 'sun/', 'jdk/', 'libcore/')


def main():
    src, dst = sys.argv[1], sys.argv[2]
    for a, b in RENAMES:
        assert len(a) == len(b), 'longitudes distintas: %s / %s' % (a, b)
    kept = dropped = 0
    with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dst, 'w', zipfile.ZIP_DEFLATED) as zout:
        for item in zin.infolist():
            name = item.filename
            if not name.endswith('.class'):
                continue
            if name.startswith('java/'):
                # solo se conservan los paquetes que NO existen en API 25
                if not any(name.startswith(a) for a, _ in RENAMES):
                    dropped += 1
                    continue
                new = name
                for a, b in RENAMES:
                    if new.startswith(a):
                        new = b + new[len(a):]
                        break
            elif name.startswith(KEEP_NON_JAVA):
                new = name
            else:
                dropped += 1
                continue
            data = zin.read(name)
            for a, b in RENAMES:  # reemplazo de igual longitud: offsets intactos
                data = data.replace(a.encode(), b.encode())
            zout.writestr(new, data)
            kept += 1
    print('build_desugar: %d clases conservadas, %d descartadas -> %s' % (kept, dropped, dst))


if __name__ == '__main__':
    main()
