#!/usr/bin/env python3
"""Aplica los parches de compatibilidad API 26+ al arbol smali de Spotify Wear.

Uso: python3 patch_smali.py /tmp/smali_out
"""
import os
import re
import sys

# (patron, reemplazo) aplicados a TODOS los .smali
GLOBAL = [
    # NotificationManager.getNotificationChannel(String) -> helper (API 26)
    (re.compile(r'invoke-virtual (\{[^}]*\}), Landroid/app/NotificationManager;->getNotificationChannel'
                r'\(Ljava/lang/String;\)Landroid/app/NotificationChannel;'),
     r'invoke-static \1, Lnbrt/compat/Notif;->getChannel(Landroid/app/NotificationManager;'
     r'Ljava/lang/String;)Landroid/app/NotificationChannel;'),
    # NotificationManager.createNotificationChannel(...) -> no-op (API 26)
    (re.compile(r'invoke-virtual (\{[^}]*\}), Landroid/app/NotificationManager;->createNotificationChannel'
                r'\(Landroid/app/NotificationChannel;\)V'),
     r'invoke-static \1, Lnbrt/compat/Notif;->createChannel(Landroid/app/NotificationManager;'
     r'Ljava/lang/Object;)V'),
    # Context.startForegroundService (API 26) -> startService (API 1)
    (re.compile(r'invoke-virtual (\{[^}]*\}), Landroid/content/Context;->startForegroundService'
                r'\(Landroid/content/Intent;\)Landroid/content/ComponentName;'),
     r'invoke-virtual \1, Landroid/content/Context;->startService(Landroid/content/Intent;)'
     r'Landroid/content/ComponentName;'),
    # VibrationEffect.createPredefined (API 26)
    (re.compile(r'invoke-static (\{[^}]*\}), Landroid/os/VibrationEffect;->createPredefined'
                r'\(I\)Landroid/os/VibrationEffect;'),
     r'invoke-static \1, Lnbrt/compat/Notif;->nullVibration(Ljava/lang/Object;)'
     r'Landroid/os/VibrationEffect;'),
    # VibrationEffect.createOneShot (API 26)
    (re.compile(r'invoke-static (\{[^}]*\}), Landroid/os/VibrationEffect;->createOneShot'
                r'\(JI\)Landroid/os/VibrationEffect;'),
     r'invoke-static \1, Lnbrt/compat/Notif;->nullVibration2(JI)Landroid/os/VibrationEffect;'),
    # Vibrator.vibrate(VibrationEffect) (API 26) -> no-op
    (re.compile(r'invoke-virtual (\{[^}]*\}), Landroid/os/Vibrator;->vibrate'
                r'\(Landroid/os/VibrationEffect;\)V'),
     r'invoke-static \1, Lnbrt/compat/Notif;->noop2(Ljava/lang/Object;Ljava/lang/Object;)V'),
]

# parches puntuales: fichero -> lista de (patron, reemplazo)
FILE_SPECIFIC = {
    # GMS "availability": usa channel.getName()/setName() en la rama else.
    # Saltamos la rama entera (creacion/actualizacion del canal).
    'Q3/d.smali': [
        (re.compile(r'if-nez v0, :cond_10e'), 'goto :cond_11e'),
    ],
    # Kc/F: constructor de vibracion; tras devolver null hay que quitar los
    # checkNotNull de Kotlin (Uf/k.c) que reventarian con null.
    'Kc/F.smali': [
        (re.compile(r'^\s*invoke-static \{p1\}, LUf/k;->c\(Ljava/lang/Object;\)V\n', re.M), ''),
    ],
}


def main():
    root = sys.argv[1]
    total = {pat.pattern[:48]: 0 for pat, _ in GLOBAL}
    specific = 0
    for dirpath, _dirs, files in os.walk(root):
        for fn in files:
            if not fn.endswith('.smali'):
                continue
            path = os.path.join(dirpath, fn)
            with open(path, 'r', encoding='utf-8', errors='surrogateescape') as fh:
                text = fh.read()
            orig = text
            for pat, rep in GLOBAL:
                text, n = pat.subn(rep, text)
                total[pat.pattern[:48]] += n
            rel = os.path.relpath(path, root)
            for pat, rep in FILE_SPECIFIC.get(rel, []):
                text, n = pat.subn(rep, text)
                specific += n
            if text != orig:
                with open(path, 'w', encoding='utf-8', errors='surrogateescape') as fh:
                    fh.write(text)
    for k, v in total.items():
        print('  %-50s %d' % (k, v))
    print('parches puntuales: %d' % specific)


if __name__ == '__main__':
    main()
