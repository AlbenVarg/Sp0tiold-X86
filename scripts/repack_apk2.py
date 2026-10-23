#!/usr/bin/env python3
"""Repackea un APK sustituyendo classes.dex por uno ya parcheado y anadiendo un
dex extra (clases de desugar) como classes2.dex.

Uso: python3 repack_apk2.py entrada.apk salida.apk nuevo_classes.dex desugar.dex
"""
import sys
import zipfile


def main():
    src, dst, new_dex_path, extra_dex_path = sys.argv[1:5]
    with open(new_dex_path, 'rb') as fh:
        new_dex = fh.read()
    with open(extra_dex_path, 'rb') as fh:
        extra_dex = fh.read()
    assert new_dex[:4] == b'dex\n' and extra_dex[:4] == b'dex\n', 'dex invalido'

    with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dst, 'w') as zout:
        for item in zin.infolist():
            name = item.filename
            is_sig = name.startswith('META-INF/') and (
                name == 'META-INF/MANIFEST.MF' or name.rsplit('.', 1)[-1] in ('RSA', 'DSA', 'EC', 'SF'))
            if is_sig:
                continue
            if name == 'classes.dex':
                zout.writestr(item, new_dex)
                continue
            zout.writestr(item, zin.read(name))
        zout.writestr('classes2.dex', extra_dex, compress_type=zipfile.ZIP_DEFLATED)
    print('repack_apk2: classes.dex sustituido (%d bytes) + classes2.dex (%d bytes) -> %s'
          % (len(new_dex), len(extra_dex), dst))


if __name__ == '__main__':
    main()
