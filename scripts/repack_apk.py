#!/usr/bin/env python3
"""Repackea un APK: parchea las referencias java.time/java.nio.file del dex
(desugaring manual) y anade un dex extra con las clases de desugar.

Uso: python3 repack_apk.py entrada.apk salida.apk desugar.dex
"""
import sys
import zipfile

RENAMES = [
    (b'java/time/', b'nbrt/time/'),
    (b'java/nio/file/', b'nbrt/nio/file/'),
]


def patch_dex(data):
    data = bytearray(data)
    total = 0
    for a, b in RENAMES:
        assert len(a) == len(b)
        total += data.count(a)
        data = data.replace(a, b)
    # el header del dex lleva firma SHA-1 (offset 12, cubre [32:]) y checksum
    # Adler-32 (offset 8, cubre [12:] -> incluye la firma): primero la firma
    import hashlib
    import struct
    import zlib
    data[12:32] = hashlib.sha1(bytes(data[32:])).digest()
    struct.pack_into('<I', data, 8, zlib.adler32(bytes(data[12:])) & 0xFFFFFFFF)
    return bytes(data), total


def main():
    src, dst, extra_dex = sys.argv[1], sys.argv[2], sys.argv[3]
    with open(extra_dex, 'rb') as fh:
        extra = fh.read()
    assert extra[:4] == b'dex\n', 'el dex extra no es valido'

    replaced = 0
    with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dst, 'w') as zout:
        for item in zin.infolist():
            name = item.filename
            is_sig = name.startswith('META-INF/') and (
                name == 'META-INF/MANIFEST.MF' or name.rsplit('.', 1)[-1] in ('RSA', 'DSA', 'EC', 'SF'))
            if is_sig:
                continue
            if name == 'classes.dex':
                data, n = patch_dex(zin.read(name))
                replaced += n
                zout.writestr(item, data)
                continue
            zout.writestr(item, zin.read(name))
        # anade el dex de desugar como classes2.dex (multidex nativo en API 21+)
        zout.writestr('classes2.dex', extra, compress_type=zipfile.ZIP_DEFLATED)
    print('repack_apk: %d referencias java.time/java.nio.file reescritas -> %s' % (replaced, dst))


if __name__ == '__main__':
    main()
