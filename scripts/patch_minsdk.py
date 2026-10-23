#!/usr/bin/env python3
"""Baja el android:minSdkVersion de un APK parcheando el AndroidManifest.xml binario (AXML).

Uso: python3 patch_minsdk.py entrada.apk salida.apk 25
"""
import struct
import sys
import zipfile


def parse_string_pool(data, off):
    """Devuelve (lista_de_strings, tamano_total_del_chunk)."""
    chunk_type, header_size, chunk_size = struct.unpack_from('<HHI', data, off)
    assert chunk_type == 0x0001, 'no es un string pool (0x%04x)' % chunk_type
    string_count, _style_count, flags, strings_start, _styles_start = struct.unpack_from(
        '<IIIII', data, off + 8)
    utf8 = bool(flags & (1 << 8))
    offsets = struct.unpack_from('<%dI' % string_count, data, off + header_size)
    out = []
    base = off + strings_start
    for o in offsets:
        p = base + o
        if utf8:
            # longitud utf16 + longitud utf8 (ULEB128 simplificado: 1-2 bytes)
            n = data[p]
            p += 1
            if n & 0x80:
                p += 1
            n = data[p]
            p += 1
            if n & 0x80:
                n = ((n & 0x7f) << 8) | data[p]
                p += 1
            out.append(data[p:p + n].decode('utf-8', 'replace'))
        else:
            n = struct.unpack_from('<H', data, p)[0]
            p += 2
            if n & 0x8000:
                n = ((n & 0x7fff) << 16) | struct.unpack_from('<H', data, p)[0]
                p += 2
            out.append(data[p:p + n * 2].decode('utf-16-le', 'replace'))
    return out, chunk_size


def patch_axml(axml, new_sdk):
    data = bytearray(axml)
    off = 8  # cabecera del fichero AXML (magic + size)
    strings, sp_size = parse_string_pool(data, off)
    try:
        name_idx = strings.index('minSdkVersion')
    except ValueError:
        raise SystemExit('ERROR: no se encontro el string "minSdkVersion"')
    # Recorre los sub-chunks del chunk XML buscando START_ELEMENT con ese atributo
    total = struct.unpack_from('<I', data, 4)[0]
    pos = off + sp_size
    patched = 0
    while pos + 8 <= total:
        c_type, _hdr, c_size = struct.unpack_from('<HHI', data, pos)
        if c_size < 8 or pos + c_size > total:
            break
        if c_type == 0x0102:  # START_ELEMENT
            # node header 16B + attrExt 20B; attributeStart es relativo al inicio de attrExt
            attr_start, attr_size, attr_count = struct.unpack_from('<HHH', data, pos + 24)
            base = pos + 16 + attr_start
            for i in range(attr_count):
                p = base + i * attr_size
                if p + attr_size > pos + c_size:
                    break
                _ns, nm, raw, t_size, _res0, dtype, _val = struct.unpack_from('<IIIHBBI', data, p)
                if nm == name_idx and raw == 0xFFFFFFFF and dtype == 0x10 and t_size == 8:
                    struct.pack_into('<I', data, p + 16, new_sdk)
                    patched += 1
        pos += c_size
    if not patched:
        raise SystemExit('ERROR: no se encontro el atributo minSdkVersion')
    return bytes(data), patched


def main():
    src, dst, sdk = sys.argv[1], sys.argv[2], int(sys.argv[3])
    zin = zipfile.ZipFile(src, 'r')
    manifest = zin.read('AndroidManifest.xml')
    fixed, n = patch_axml(manifest, sdk)
    with zipfile.ZipFile(dst, 'w') as zout:
        for item in zin.infolist():
            name = item.filename
            is_sig = name.startswith('META-INF/') and (
                name == 'META-INF/MANIFEST.MF' or name.rsplit('.', 1)[-1] in ('RSA', 'DSA', 'EC', 'SF'))
            if is_sig:
                continue  # la firma se invalida al modificar: se elimina para re-firmar
            payload = fixed if name == 'AndroidManifest.xml' else zin.read(name)
            zout.writestr(item, payload)  # conserva compress_type y metadatos originales
    zin.close()
    print('OK: %d atributo(s) minSdkVersion -> %d ; escrito %s' % (n, sdk, dst))


if __name__ == '__main__':
    main()
