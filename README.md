# Sp0tiold-X86

**Spotify for Wear OS en relojes Intel x86 con Android 7.1.1 (API 25)** — p. ej. el NBRiq y otros smartwatches chinos con SoC Intel Atom.

El cliente de Wear OS moderno exige `minSdkVersion 28` (Android 9). Este repo documenta y automatiza el parcheo necesario para hacerlo arrancar, iniciar sesión y reproducir en un reloj de 2017 con **API 25 / x86 (i386)**.

> 🧸 **¿Solo quieres instalarlo y no te interesa el cómo?** → **[Guía fácil paso a paso (para dummies)](README-SIMPLE.md)**

> **Estado: funciona de punta a punta salvo el sonido, que necesita Bluetooth.** Arranca, empareja, inicia sesión, **se conserva el login al reinstalar** y carga home/biblioteca (verificado en un NBRiq: "Good morning" + Liked Songs + playlists). La reproducción no se ha podido oír todavía porque el reloj no tiene altavoz útil y Spotify pide un dispositivo Bluetooth (los auriculares del usuario). Audio focus **no** es un problema: la app ya trae la rama API 25.

---

## TL;DR

```bash
./scripts/setup.sh                                  # una sola vez: baja las herramientas
./scripts/build.sh "com.spotify.music_9.0.40.386-..._minAPI28(x86).apk"
# -> build/spotify-wear-api25.apk  (minSdk 25, desugared, firmado, solo lib/x86: ~16 MB)
adb install -r build/spotify-wear-api25.apk
adb shell am start -n com.spotify.music/com.spotify.wear.main.MainActivity
```

Mantenimiento desde el ordenador (todo opcional):

```bash
./scripts/spotify-sleep.sh on        # quitar el reloj: cierra Spotify + apaga WiFi
./scripts/spotify-sleep.sh off       # ponértelo: WiFi + abre Spotify
./scripts/debloat.sh list            # apps de Google que sobran (disable/restore)
./scripts/diag-reboot.sh             # si el reloj se reinicia solo (no es la app)
./scripts/reinstall-keep-data.sh build/spotify-wear-api25.apk   # cambia el APK sin perder el login (root)
```

---

## Scripts

| Script | Para qué |
|---|---|
| `scripts/setup.sh` | descarga `baksmali`/`smali`/`desugar` y crea el keystore |
| `scripts/build.sh` | pipeline completo (minSdk, desugar, parches, repack, firma). `KEEP_ABIS=""` conserva todas las ABIs |
| `scripts/debloat.sh` | desactiva apps de Google prescindibles (reversible) y libera RAM |
| `scripts/spotify-sleep.sh` | modo dormir: `force-stop` de Spotify + WiFi off, y vuelta atrás |
| `scripts/diag-reboot.sh` | informe de reinicios: `bootreason`, historial, `pstore`, stack traducido |
| `scripts/reinstall-keep-data.sh` | reinstala el APK conservando la sesión (root + `magiskpolicy`); `--rollback` |

---

## El problema: cuatro muros

| # | Muro | Síntoma |
|---|------|---------|
| 1 | `minSdkVersion=28` en el manifest | `INSTALL_FAILED_OLDER_SDK` |
| 2 | `java.time.*` y `java.nio.file.*` no existen en API 25 | `NoClassDefFoundError` |
| 3 | Llamadas a framework de API 26+ | `NoSuchMethodError` |
| 4 | Cliente viejo (8.4.84) muerto en servidor | Home en blanco / bucle de login |

### Por qué no vale usar el cliente antiguo

`com.spotify.music` **8.4.84** (último con API 16 / x86) instala y loguea, pero es inservible:

* `GET https://api.spotify.com/v1/views/wear-home-v1` → **404** (endpoint retirado).
* `gew-dealer.spotify.com` → **NXDOMAIN** (backend de "group experience" desmantelado).

No es parcheable: la app pide datos que ya no existen. **Hay que portar el cliente moderno.**

---

## Cómo funciona el parche

Tres capas independientes, en este orden:

### Capa 1 — `minSdkVersion` 28 → 25 (AXML)

El `AndroidManifest.xml` de un APK es binario (AXML). `scripts/patch_minsdk.py` parsea el *string pool* y los chunks `START_ELEMENT`, localiza el atributo `minSdkVersion` (tipo `0x10`, dato de 8 bytes) y sobreescribe el entero en su sitio. **No** se reescribe el fichero: mismo tamaño, sin romper offsets.

```bash
python3 scripts/patch_minsdk.py entrada.apk salida.apk 25
```

### Capa 2 — desugaring de `java.time` / `java.nio.file`

API 25 no tiene `java.time` (llegó en 26) ni `java.nio.file` (26). La app los usa (Kotlinx-Datetime, Okio, WorkManager...).

Solución: **bundlear** las clases de `desugar_jdk_libs` **renombradas** a un paquete propio, porque el *bootclasspath* del sistema gana siempre a las clases de la app:

```
java/time/       ->  nbrt/time/
java/nio/file/   ->  nbrt/nio/file/
```

El renombrado es de **igual longitud en bytes**, lo que permite que el reemplazo dentro de los `.class` no mueva ningún offset (los `CONSTANT_Utf8` conservan tamaño → el class file sigue siendo válido sin reescribir la constant pool completa).

Esas clases van a un segundo dex: `classes2.dex` (multidex nativo desde API 21, sin librería de soporte).

```bash
python3 scripts/build_desugar.py desugar_jdk_libs-2.1.5.jar build/desugar-subset.jar
d8 --min-api 25 --output build/dexout build/desugar-subset.jar
```

### Capa 3 — reescritura de llamadas a framework API 26+ en smali

Aquí está el trabajo fino. **No se puede hacer un reemplazo binario en el dex**: ART verifica el *string pool* ordenado y la firma. Por eso el flujo es:

```
classes.dex --baksmali--> smali/ --(parches de texto)--> smali' --smali--> classes.dex'
```

El round-trip `baksmali`/`smali` (3.0.10) **re-ordena el string pool correctamente** y recalcula firma y checksum. Verificado con `dexdump -f`.

Símbolos parcheados (todos redirigidos a la clase helper `nbrt.compat.Notif`):

| Símbolo (API 26) | Dónde aparecía | Sustituto |
|---|---|---|
| `NotificationManager.getNotificationChannel(String)` | `ForegroundMediaService` (crash al terminar login), `DownloadWorkerImpl`, GMS `Q3/d` | `Notif.getChannel()` → devuelve objeto no nulo ⇒ la app **omite** la rama de creación de canal |
| `NotificationManager.createNotificationChannel(...)` | mismos 3 | `Notif.createChannel()` → no-op |
| `Context.startForegroundService(Intent)` | WorkManager `r1.1/d` | `startService(Intent)` (idéntico en 7.1: la notificación se promociona con `startForeground`) |
| `VibrationEffect.createPredefined(int)` | `Kc/F` (usado por ~10 clases de UI) | `Notif.nullVibration()` → null |
| `VibrationEffect.createOneShot(J, int)` | `Kc/F` | `Notif.nullVibration2()` → null |
| `Vibrator.vibrate(VibrationEffect)` | `Kc/F` | `Notif.noop2()` → no-op |

Además, en `Kc/F` hay que **eliminar los `checkNotNull` de Kotlin** (`Uf/k;->c(Ljava/lang/Object;)V`) que hay justo después de crear el `VibrationEffect`: si devolvemos `null`, esos checks lanzan `IllegalStateException`.

Y en `Q3/d` (comprobación de disponibilidad de GMS) se salta la rama completa con `goto`, porque en la rama `else` se llama a `NotificationChannel.getName()` / `setName()`, que no existen en el `Object` que devolvemos.

El helper (`smali/nbrt/compat/Notif.smali`) es equivalente a:

```java
public final class Notif {
    public static NotificationChannel getChannel(NotificationManager nm, String id) {
        return (NotificationChannel)(Object) new Object(); // no nulo, sin canales en <26
    }
    public static void createChannel(NotificationManager nm, Object ch) { /* no-op */ }
    public static void noop2(Object a, Object b) { }
    public static VibrationEffect nullVibration(Object predefined) { return null; }
    public static VibrationEffect nullVibration2(long ms, int amplitude) { return null; }
}
```

---

## Trampas encontradas (y cómo se resolvieron)

1. **Reemplazo binario del dex → `VerifyError`.** ART valida el orden del *string pool*; cambiar nombres sin reordenar rompe la verificación. Solo funciona si los nombres tienen la **misma longitud** y aun así es frágil. El round-trip por smali es la vía segura.
2. **`dexdump` es el juez.** `dexdump -f` sobre el dex reensamblado detecta checksum/firma/orden incorrectos. Si `dexdump` se queja, ART también.
3. **`extractNativeLibs`.** El manifest no lo desactiva ⇒ `true`: las `.so` se extraen en la instalación. Consecuencia buena: **no hacen falta stubs ni `useLegacyPackaging`**. El APK incluye 6 `.so` x86 reales.
4. **`classes2.dex` debe ir comprimido y con nombre exacto.** Multidex nativo lee `classes.dex`, `classes2.dex`, ... en orden.
5. **`dex` versión 037 vs 035.** El APK base usa 037 (API 24+); API 25 lo acepta. Al reensamblar con `smali a -a 25` se mantiene 037.
6. **Firma.** Cualquier modificación invalida `META-INF/*`; los scripts **borran** la firma original al repackear y hay que volver a firmar (`apksigner`) y alinear (`zipalign -p 4`).
7. **El login no se guarda si la app crashea justo después de emparejar.** El pairing completa en servidor, pero el token se persiste más tarde: hay que arreglar el crash **antes** de pedir un código nuevo.

---

## Requisitos del entorno

```bash
brew install openjdk@17 android-commandlinetools   # macOS
# baksmali / smali 3.0.10  (https://github.com/baksmali/smali/releases)
# desugar_jdk_libs 2.1.5   (maven.google.com -> com.android.tools:desugar_jdk_libs)
python3 --version   # 3.8+
```

`scripts/build.sh` espera (por variables de entorno o edición):

| Variable | Por defecto | Qué es |
|---|---|---|
| `BAKSMALI` | `./tools/baksmali.jar` | baksmali 3.0.10 |
| `SMALI` | `./tools/smali.jar` | smali 3.0.10 |
| `DESUGAR_JAR` | `./tools/desugar_jdk_libs-2.1.5.jar` | jar de desugar |
| `BT` | `.../build-tools/35.0.0` | zipalign + apksigner |
| `KS` | `./tools/debug.jks` | keystore |

---

## Pipeline manual (paso a paso)

```bash
export APK="com.spotify.music_9.0.40.386-..._minAPI28(x86).apk"

# 1) minSdk 28 -> 25
python3 scripts/patch_minsdk.py "$APK" build/ms25.apk 25

# 2) dex de desugar renombrado a nbrt/*
python3 scripts/build_desugar.py tools/desugar_jdk_libs-2.1.5.jar build/desugar-subset.jar
d8 --min-api 25 --output build/dexout build/desugar-subset.jar

# 3) baksmali del dex de la app
unzip -o build/ms25.apk classes.dex -d build/dex
java -jar tools/baksmali.jar d build/dex/classes.dex -o build/smali

# 4) helper + parches de call sites
cp -r smali/nbrt build/smali/
# 4a) renombrado de igual longitud (java.time / java.nio.file)
grep -rl 'Ljava/time/' build/smali | xargs sed -i '' 's{Ljava/time/}{Lnbrt/time/}g'
grep -rl 'Ljava/nio/file/' build/smali | xargs sed -i '' 's{Ljava/nio/file/}{Lnbrt/nio/file/}g'
# 4b) reescritura de API 26+
python3 scripts/patch_smali.py build/smali

# 5) reensamblar
java -jar tools/smali.jar a build/smali -o build/classes-patched.dex -a 25
dexdump -f build/classes-patched.dex | head -3     # debe abrir sin errores

# 6) repack + alinear + firmar
python3 scripts/repack_apk2.py build/ms25.apk build/unaligned.apk \
        build/classes-patched.dex build/dexout/classes.dex
zipalign -f -p 4 build/unaligned.apk build/spotify-wear-api25.apk
apksigner sign --ks tools/debug.jks --ks-pass pass:android \
        --key-pass pass:android build/spotify-wear-api25.apk
apksigner verify build/spotify-wear-api25.apk

# 7) instalar
adb install -r build/spotify-wear-api25.apk
adb shell am start -n com.spotify.music/com.spotify.wear.main.MainActivity
```

---

## Instalación en el reloj

1. `adb install -r` el APK firmado. Si falla por firma previa distinta: `adb uninstall com.spotify.music`.
2. Abrir la app → aparece **"Continue on phone"** con un código de 6 caracteres.
3. Ir a **https://www.spotify.com/pair** en el móvil/PC, iniciar sesión y meter el código.
4. La sesión se guarda en el reloj; a partir de ahí no hace falta el móvil.

---

## Pendiente

Los tres riesgos de API 26+ que quedaban **ya están resueltos o descartados con datos**
(detalle en [`docs/FINDINGS.md` §5.5 y §5.6](docs/FINDINGS.md#55-audiofocusrequest-falso-positivo)):

| Símbolo API 26+ | Estado real |
|---|---|
| `AudioFocusRequest` / `requestAudioFocus(AudioFocusRequest)` | ✅ **no aplica**: `W5/c.f()` comprueba `SDK_INT < 26` y usa `requestAudioFocus(listener, streamType, durationHint)` |
| `java.lang.invoke.MethodHandles` | ✅ **inofensivo**: solo en `ah/K`, y `ah/K.<clinit>` elige `ah/J` (reflexión clásica) porque `java.vm.name == "Dalvik"` en Android |
| `AdaptiveIconDrawable` | 🟡 **bajo**: `u1/d`, solo iconos adaptativos del launcher |
| `Notification.Builder.setChannelId` | ✅ no-op en <26, verificado en el reloj |

Lo que queda por probar:

- **Sonido real**: el NBRiq no tiene altavoz utilizable (`dumpsys audio` solo expone
  `speaker`, pero Spotify abre los ajustes de Bluetooth al elegir "This watch"). Hay que
  emparejar auriculares/manos libres y comprobar que suena, que no hay `AudioTrack` en
  error y que el `PlaybackState` pasa a `state=3`.
- Ajuste fino del buffer de `AudioTrack` en x86 sin NEON (solo si se oyen cortes).
- A/B de estabilidad del watchdog: una noche con `spotify-sleep.sh on` vs una normal,
  comparando el número de arranques con `./scripts/diag-reboot.sh`.

### Reinicios del reloj: no es la app

El NBRiq se reinicia solo (con o sin Spotify) por bugs del **kernel del ROM**:
`Oops` en `ipt_do_table` dentro de `suspend_enter`, `WARNING` en `i2c_dw_xfer` y fallos de
`page_alloc` en el driver WiFi (455 MB de RAM, ~18 MB libres). `ro.boot.bootreason=watchdog`.
Diagnóstico reproducible con [`scripts/diag-reboot.sh`](scripts/diag-reboot.sh); análisis
completo en [`docs/FINDINGS.md` §10](docs/FINDINGS.md#10-el-reloj-se-reinicia-solo--no-es-la-app).

---

## Aviso legal

Este repo **no contiene** el APK de Spotify ni código propietario de Spotify AB. Solo contiene herramientas propias de parcheo, documentación técnica y un helper smali original. Para usarlo necesitas obtener el APK original por tu cuenta y una cuenta de Spotify válida. Spotify es una marca registrada de Spotify AB; este proyecto no está afiliado ni respaldado por ellos.

## Licencia

MIT — ver [LICENSE](LICENSE). Solo para las herramientas y documentación de este repositorio.

