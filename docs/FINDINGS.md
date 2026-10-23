# Notas técnicas / investigación

Registro del proceso completo, incluidos los callejones sin salida, para que quien lo retome no repita el trabajo.

## 0. Objetivo

| Dato | Valor |
|---|---|
| Dispositivo | NBRiq (smartwatch chino), SoC Intel, **x86 (i386)** |
| SO | Android 7.1.1, **API 25**, ART, sin Google Play Services reales |
| Objetivo | Spotify for Wear OS funcionando (login + home + reproducción) |

## 1. Elección del APK base

Candidatos descargados de APKMirror:

| Versión | minSdk | ABIs | Veredicto |
|---|---|---|---|
| 8.4.84.874 (`+40113278`) | 16 | x86 | Instala y loguea, **pero muerto en servidor** (ver §2) |
| 8.4.84.874 (`+40113281`) | 25 | armeabi-v7a | Sin x86 → descartado |
| **9.0.40.386** (`+127404690`) | **28** | arm64-v8a, armeabi-v7a, **x86**, x86_64 | **Elegido** |

Verificación de que 9.0.40.386 es la **variante Wear** (no la de móvil):

* Activity principal: `com.spotify.wear.main.MainActivity`
* Paquete `com.spotify.wear.*` presente
* Librerías nativas x86 **reales** (6 `.so`), no stubs:

```
lib/x86/libspotify_appmusicdecrypt.so
lib/x86/libspotify_audio_processing.so
lib/x86/libspotify_playback.so
lib/x86/libc++_shared.so
...
```

## 2. Autopsia del cliente antiguo (8.4.84)

Instalado y con login correcto, la pantalla principal queda vacía. Logcat:

```
HTTP 404  GET https://api.spotify.com/v1/views/wear-home-v1
```

y el backend de sincronización entre dispositivos:

```
gew-dealer.spotify.com  ->  NXDOMAIN
```

* `wear-home-v1` era el endpoint específico del "home" de Wear; **retirado** del API público.
* `gew-*` (Group Experience / Spotify Connect antiguo) ya no resuelve.

**Conclusión:** el cliente viejo no se puede arreglar parcheando: no hay datos que mostrar. Hay que portar el cliente moderno.

## 3. Muro 1 — `minSdkVersion`

`aapt2 dump badging` del APK 9.0.40.386 → `sdkVersion:'28'`.

El manifest es AXML binario. `scripts/patch_minsdk.py` localiza el atributo `minSdkVersion` dentro del chunk `START_ELEMENT` de `<uses-sdk>` y escribe el entero *in place* (tipo `0x10`, `data = 8`). Mismo tamaño ⇒ no hay que recolocar nada ni tocar el resto del AXML.

Tras esto el APK **instala**, pero crashea al arrancar.

## 4. Muro 2 — `java.time` / `java.nio.file`

Primer crash:

```
java.lang.NoClassDefFoundError: Failed resolution of: Ljava/time/Instant;
```

API 25 no tiene `java.time` (API 26) ni `java.nio.file` (API 26). `desugar_jdk_libs` provee implementaciones, pero **no se pueden dejar en `java/time/...`**: el *bootclasspath* del sistema tiene prioridad y, en API 25, el paquete ni siquiera existe como módulo cargable desde la app (restricción del cargador de clases de ART para paquetes `java.*`).

Solución: renombrar a un paquete propio **de la misma longitud**:

```
java/time/       (10 bytes) -> nbrt/time/       (10 bytes)
java/nio/file/   (13 bytes) -> nbrt/nio/file/   (13 bytes)
```

Misma longitud ⇒ el reemplazo dentro de los `.class` no desplaza offsets y el *class file* sigue siendo válido sin reescribir la `constant pool`. Se aplica tanto a los nombres de fichero/clase como a las referencias internas (`this_class`, `super_class`, descriptores, firmas).

Ajustes necesarios en el subset:

* Solo se conservan las clases bajo `java/time/` y `java/nio/file/`, más las implementaciones internas (`desugar/`, `sun/`, `jdk/`, `libcore/`).
* El resto de `java/*` del jar se descarta (ya existe en la plataforma y shadowearlo rompería).

Resultado: `classes2.dex` con las clases `nbrt.*`. Multidex nativo (API 21+) las carga sin librería de soporte.

## 5. Muro 3 — símbolos de framework API 26+

### 5.1 Crash tras el login

El emparejamiento **sí funcionaba**, y justo después:

```
java.lang.NoSuchMethodError: No virtual method
  getNotificationChannel(Ljava/lang/String;)Landroid/app/NotificationChannel;
  in class Landroid/app/NotificationManager;
  at com.spotify.wear.loggedinscope.mediasession.ForegroundMediaService.onCreate
```

`NotificationChannel` y `getNotificationChannel` son API 26. El servicio de reproducción en primer plano crea su canal de notificación al arrancar ⇒ crash inmediato al entrar en la zona logueada.

> Detalle importante: el crash ocurría **después** de que el servidor aceptase el pairing, pero **antes** de persistir el token ⇒ al relanzar había que pedir un código nuevo. Por eso el orden correcto es: arreglar crashes → luego emparejar.

### 5.2 Auditoría completa de API 26+

Búsqueda de todos los símbolos con `apiLevel > 25` usados en el dex:

| Símbolo | API | Ficheros |
|---|---|---|
| `NotificationManager.getNotificationChannel` | 26 | `ForegroundMediaService`, `DownloadWorkerImpl`, `Q3/d` |
| `NotificationManager.createNotificationChannel` | 26 | los mismos 3 |
| `NotificationChannel` (tipo) | 26 | los mismos 3 |
| `Context.startForegroundService` | 26 | `r1.1/d` (WorkManager) |
| `VibrationEffect.createPredefined` / `createOneShot` | 26 | `Kc/F` (llamado desde ~10 clases de UI) |
| `Vibrator.vibrate(VibrationEffect)` | 26 | `Kc/F` |
| `AudioFocusRequest` / `requestAudioFocus(AudioFocusRequest)` | 26 | ✅ **no aplica**: la app ya trae rama para <26 (ver 5.5) |
| `java.lang.invoke.MethodHandles` | 26 | ✅ **inofensivo**: solo en `ah/K`, que en Android no se instancia (ver 5.6) |
| `AdaptiveIconDrawable` | 26 | `u1/d` (iconos) |

### 5.3 Estrategia de parcheo de call sites

Primer intento descartado: **reemplazo binario dentro del dex** cambiando el nombre del método por otro de la misma longitud. Problema:

* El *string pool* del dex debe estar **ordenado**; cambiar una cadena sin reordenar el pool invalida la verificación de ART (`VerifyError` / `ClassNotFoundException` en cascada).
* El `invoke-virtual` apunta a un `method_id` con `class_idx` + `name_idx` + `proto_idx`; si cambias el nombre a mano, el mismo string puede estar compartido por otros usos y corromperlos.

Solución adoptada: **baksmali → edición de texto → smali**. El round-trip:

1. baksmali reconstruye el pool en orden de aparición,
2. smali lo **re-ordena alfabéticamente** y recalcula `signature` (SHA-1) y `checksum` (Adler-32),
3. `dexdump -f` confirma que el fichero es válido.

Coste: ~2-3 min por iteración en un MacBook (11.5k clases). Aceptable.

### 5.4 Diseño del helper

En vez de inventar secuencias de bytes para cada caso, se añade una clase Java/Smali nueva, `nbrt.compat.Notif`, y se redirigen las llamadas:

```java
public final class Notif {
    // API <26 no tiene canales: devolver no-nulo hace que el codigo original
    // tome la rama "el canal ya existe" y no intente crearlo.
    public static NotificationChannel getChannel(NotificationManager nm, String id) {
        return (NotificationChannel) (Object) new Object();
    }
    public static void createChannel(NotificationManager nm, Object ch) { }
    public static void noop2(Object a, Object b) { }
    public static VibrationEffect nullVibration(Object predefined) { return null; }
    public static VibrationEffect nullVibration2(long ms, int amplitude) { return null; }
}
```

Ventajas: una sola clase a mantener, `invoke-static` con firma compatible, y si mañana se quiere comportamiento real (p. ej. degradar a `Notification.Builder` sin canal) se cambia solo ahí.

Trampa: devolver `null` donde Kotlin espera no-null dispara `IllegalStateException` por los `checkNotNull` insertados por el compilador (`Uf/k;->c(Ljava/lang/Object;)V`). Hay que **borrar esas dos líneas** en `Kc/F`.

Trampa 2: en `Q3/d` (comprobación de disponibilidad de Google Play Services) la rama `else` hace `channel.getName()` → `NoSuchMethodError` sobre nuestro `Object`. Se parchea el salto: `if-nez v0, :cond_10e` → `goto :cond_11e`.

### 5.5 `AudioFocusRequest`: falso positivo

`AudioFocusRequest` (y su `Builder`) son API 26+, pero **Spotify ya trae el camino
antiguo** y lo elige en tiempo de ejecución:

* `W5/c;->f()I` hace `sget Landroid/os/Build$VERSION;->SDK_INT:I` y
  `const/16 v4, 0x1a; if-lt v1, v4, :cond_56`. Si `SDK_INT < 26` salta a
  `:cond_56`, donde está `invoke-virtual {v1, v0, v5, v9}, Landroid/media/AudioManager;->requestAudioFocus(Landroid/media/AudioManager$OnAudioFocusChangeListener;II)I`
  (sobrecarga de API 8 con `streamType` + `durationHint`).
* `La3/i;->w(LX5/b;)I` es la rama 26+ (usa `AudioFocusRequest` y
  `LPc/X;->s(...)` para construirlo). Solo se ejecuta si `SDK_INT >= 26`.
* `abandonAudioFocus` también está duplicado: `W5/c` línea ~424 usa la versión
  antigua con listener.

Conclusión: **no hay que parchear nada** para audio focus en API 25. Si algún
día apareciera el crash, la ruta sería reescribir el `Builder` a una clase
`nbrt/compat/AfRequest` propia, pero hoy sería trabajo tirado.

**Confirmado en el reloj** (23-oct, reproduciendo desde "Liked Songs"):

```bash
$ adb shell dumpsys media_session | grep -m1 PlaybackState
  state=PlaybackState {state=3, position=126699, speed=1.0, ...}

$ adb shell dumpsys audio | sed -n '/Audio Focus stack/,+2p'
Audio Focus stack entries (last is top of stack):
  source:... -- pack: com.spotify.music -- client: android.media.AudioManager@a84352cY5.c@32721ad
  -- gain: GAIN -- flags: -- loss: none -- uid: 10046
  -- attr: AudioAttributes: usage=1 content=2 flags=0x0 tags= bundle=null
```

`state=3` es `PLAYING`, la posición avanza (4335 → 126699 ms) y el focus lo tiene
`Y5.c` — exactamente la clase de la rama legacy. Ni un `NoSuchMethodError`.

### 5.6 `java.lang.invoke`: código muerto en Android

Todo `java.lang.invoke` del APK está en `Lah/K;` (6 referencias:
`MethodHandles.lookup()`, `Lookup.unreflectSpecial`, `MethodHandle.bindTo`,
`invokeWithArguments`). Es el helper de "invocar default methods" de Kotlin/Java 8.

`Lah/K;-><clinit>` decide la implementación así:

```
const-string v0, "java.vm.name"
invoke-static {v0}, Ljava/lang/System;->getProperty(...)
const-string v1, "Dalvik"
invoke-virtual {v1, v0}, Ljava/lang/String;->equals(...)   # ¿"Dalvik" == vm.name?
if-eqz v0, :cond_14        # distinto de Dalvik -> new Lah/K (con MethodHandles)
:cond_14  new-instance v0, Lah/J   # "Dalvik" -> Lah/J (reflexión clásica)
```

Y en Android `java.vm.name` vale **`"Dalvik"`** tanto en Dalvik como en ART
(por compatibilidad). Es decir: en el reloj se usa `Lah/J`, que **no contiene
ni una referencia a `java.lang.invoke`** (`grep -c 'java/lang/invoke' ah/J.smali`
→ 0). El código con `MethodHandles` solo se ejecutaría en una JVM de escritorio.
Riesgo real: ninguno.

## 6. Empaquetado

* `repack_apk2.py` sustituye `classes.dex` y añade `classes2.dex`, **eliminando** `META-INF/*.RSA|SF|MF` (la firma original deja de ser válida).
* `zipalign -p 4` — el `-p` alinea las `.so` a 4 KiB (necesario en algunas ROMs; en 7.1 es inocuo).
* `apksigner` con keystore propio. En el reloj: si había otra firma, `adb uninstall` antes.
* `extractNativeLibs` no está desactivado en el manifest ⇒ `true` ⇒ las `.so` se extraen al instalar y API 25 las carga sin problemas de page-alignment.

## 7. Checklist de verificación

```bash
# minSdk
aapt2 dump badging out.apk | grep sdkVersion          # -> 25

# dex válido
dexdump -f classes.dex | head -3                       # sin "Failure"

# sin símbolos API 26+
for s in 'Landroid/os/VibrationEffect;->' startForegroundService \
         'NotificationManager;->getNotificationChannel'; do
  echo -n "$s -> "; grep -rc -- "$s" smali/ | grep -v ':0' | wc -l
done

# firma
apksigner verify --print-certs out.apk

# en el dispositivo
adb logcat -c && adb shell am start -n com.spotify.music/com.spotify.wear.main.MainActivity
adb logcat -d | grep -E 'FATAL|NoSuchMethod|NoClassDefFound|VerifyError'
```

## 8. Estado actual

| Hito | Estado |
|---|---|
| Instala en API 25 / x86 | ✅ |
| Arranca sin crash | ✅ |
| Genera código de emparejamiento | ✅ |
| Completa login (servidor acepta) | ✅ |
| Sobrevive al login (crash `NotificationChannel`) | ✅ verificado en el reloj |
| Home / biblioteca | ✅ cargan ("Good morning", Liked Songs, playlists) |
| Sesión conservada tras reinstalar el APK slim | ✅ (ver §11) |
| Reproducción | ✅ `state=3` (PLAYING) con audio focus en `Y5.c`; posición avanza y **suena** (confirmado por el usuario). Capturas en [`docs/img/`](docs/img/) |
| Sonido audible | ✅ confirmado escuchando en el reloj |
| APK slim (solo x86) | ✅ `KEEP_ABIS=x86`, 41,7 MB → 16 MB, instalado |
| Apps de Google prescindibles | ✅ desactivadas (`scripts/debloat.sh`) |

## 9. Siguientes pasos sugeridos

1. Probar reproducción real (Bluetooth/A2DP y altavoz) y anotar si suena.
2. Si `VibrationEffect` reaparece por otra ruta (`Notification.defaults`, `AudioAttributes`), ampliar `nbrt.compat.Notif`.
3. Comprobar `AudioTrack`/códecs: en x86 sin NEON el playback usa rutas software; puede necesitar ajustar el buffer.
4. Mitigar los reinicios del watchdog: `scripts/spotify-sleep.sh` (WiFi off + force-stop) y `scripts/debloat.sh` (apps de Google que sobran). Ver §10.

---

## 10. "El reloj se reinicia solo" — NO es la app

Síntoma reportado: con Spotify en segundo plano, al rato **el reloj se reinicia**.
Investigado el 2026-10-23 con `scripts/diag-reboot.sh`. **El culpable es el ROM.**

### 10.1 Evidencia

| Prueba | Resultado |
|---|---|
| `ro.boot.bootreason` | `watchdog` → lo resetea el perro guardián del SoC, no un crash de app |
| Historial `SYSTEM_BOOT` en dropbox | **16 arranques**; 15 de ellos **antes** de instalar Spotify (instalado 23-oct 00:53) |
| `dmesg-ramoops-0` (pstore) | `Oops#1` con stack `ipt_do_table → nf_conntrack_in → tcp_v4_send_synack → tcp_rtx_synack → reqsk_timer_handler`, disparado **dentro de `suspend_enter`** |
| `console-ramoops-0` | `WARNING … i2c-designware-core.c:1265 i2c_dw_xfer` desde `max17042_evt_worker` (batería, en resume) |
| `console-ramoops-0` | `WARNING … mm/page_alloc.c:3032 __alloc_pages_nodemask` desde `dhd_dpc` (driver WiFi, `allocate_slab`) |
| RAM | `MemTotal: 455 MB`, `MemFree: ~18 MB`, swap zram 307 MB con ~70 MB usados |

### 10.2 Cadena causal

1. El reloj (Intel Merrifield, kernel 4.4.20, 455 MB de RAM) vive al límite de memoria.
2. Con Spotify en background quedan ~18 MB libres; el driver WiFi (`dhd_dpc`) no consigue
   asignar slabs en contexto atómico → `WARNING` en `page_alloc.c`.
3. Al apagarse la pantalla el sistema entra en `suspend`. Cualquier socket TCP vivo
   (Spotify mantiene 3 conexiones establecidas) deja temporizadores pendientes;
   un `reqsk_timer_handler` dispara en pleno `suspend_enter` → `ip_output` → netfilter
   → **Oops del kernel en `ipt_do_table`**.
4. El SoC se queda colgado → el watchdog de hardware (SCU) resetea el reloj
   (`ro.boot.bootreason=watchdog`).

Ninguno de los tres `WARNING`/`Oops` está en código de la app: son bugs del kernel del ROM
que ya existían (se reiniciaba igual sin Spotify instalado).

### 10.3 Qué se puede hacer (de más a menos efectivo)

1. **Modo dormir automático**: `./scripts/spotify-sleep.sh on` cierra Spotify y apaga la
   WiFi de una vez; `off` lo revierte (WiFi + abrir la app). Es el punto 1 + 2 juntos.
2. **No dejar sockets abiertos al dormir**: modo *Offline* (descargas) o cerrar Spotify con
   `adb shell am force-stop com.spotify.music` antes de quitarte el reloj. Con la app cerrada
   se liberan ~70 MB y desaparecen los temporizadores TCP.
3. **WiFi apagada cuando no escuches** (solo Bluetooth): sin red no hay `ipt_do_table`
   ni `dhd_dpc` en el suspend.
4. **Liberar RAM**: `./scripts/debloat.sh disable` apaga las apps de Google prescindibles
   (app Google, Play Music, Traducir, teclado manuscrito, demo de tienda, tutorial,
   bugreportsender; con `--with-optional`, también Fit, TTS y Recordatorios). Reversible con
   `./scripts/debloat.sh restore`. En el NBRiq ya estaban casi todas desactivadas y el
   `MemAvailable` ronda 170 MB con Spotify abierto.
5. Arreglo de verdad: kernel/ROM parcheado (fuera del alcance de este repo).

### 10.4 Cómo comprobarlo en tu reloj

```bash
./scripts/diag-reboot.sh
```

Lee `ro.boot.bootreason`, el historial de arranques, el `pstore` del último cuelgue y
traduce el stack a lenguaje claro. Requiere `adb`; con root (Magisk) da el informe completo.

### 10.5 Descartado con datos

* **No** es un crash de la app: un `FATAL EXCEPTION` mata el proceso, no reinicia el reloj.
* **No** lo causan los parches: `classes.dex` es idéntico al que arranca y loguea bien; el
  `Oops` es del kernel y el historial de reinicios es anterior a la instalación.
* **No** es el `system_server_crash` de `02:15` (`ActivityNotFoundException: ACTION_ASSIST`
  al mantener pulsado el botón de encendido): eso solo reinicia `system_server`, no el reloj,
  y es otro bug conocido del ROM. Ver `docs/FINDINGS.md` y el issue del repo si quieres
  evitarlo: no dejes pulsado el botón de encendido.

---

## 11. Cambiar el APK sin perder la sesión (con root)

El APK que quedó instalado en el reloj se firmó con otra clave (se regeneró
`tools/debug.jks` después), así que `adb install -r` falla con
`INSTALL_FAILED_UPDATE_INCOMPATIBLE` y habría que desinstalar → perder el login.
Con root se puede hacer sin perder nada: `scripts/reinstall-keep-data.sh`.

Lo que costó descubrir (todo comprobado en el NBRiq, Magisk viejo + Android 7.1.1):

| Tropiezo | Síntoma | Solución |
|---|---|---|
| `tar -xzf` en el reloj | `tar: exec gunzip: No such file or directory` | el toybox `tar` **crea** `.tgz` pero no lo extrae; descomprimir en el Mac y copiar el árbol |
| `cp -a` | `cp: /data/data/com.spotify.music: Permission denied` | `-a` intenta restaurar el contexto SELinux del origen; usar `cp -r` y luego `restorecon` |
| `su -c` no escribe | `chmod`/`touch` → `Permission denied`, sin `avc: denied` nuevo en dmesg | en esta ROM `su -c` ejecuta en el dominio **`shell`**, no en `magisk`; con `magiskpolicy --live` se le dan permisos |
| `su -c 'id'` dice root pero `chmod` falla | `scontext=u:r:shell:s0` en el AVC | comprobar siempre `id -Z`, no solo `id` |
| `adb push` de un symlink | `failed to copy ... Is a directory` | quitar `lib` del árbol (es un enlace absoluto a `/data/app/...`, se recrea) |

Reglas mínimas (van en el script, **no persisten**: se pierden al reiniciar):

```sh
/data/adb/magisk/magiskpolicy --live \
  'allow shell system_data_file dir { create write read search setattr add_name remove_name rmdir }' \
  'allow shell system_data_file file { create write read getattr setattr unlink rename }' \
  'allow shell app_data_file dir { create write read search setattr add_name remove_name rmdir }' \
  'allow shell app_data_file file { create write read getattr setattr unlink rename }'
```

> Ojo con la sintaxis: este `magiskpolicy` quiere `allow <src> <tgt> <clase> { perms }`
> (sin `:` entre tipo y clase) y no acepta `file`/`dir` como *tipos*.

Orden que funciona:

1. `su -c 'tar -czf /sdcard/d.tgz -C /data/data com.spotify.music'` (esto sí funciona) y `adb pull`.
2. `pm uninstall` + `adb install` del APK nuevo.
3. Descomprimir en el Mac, quitar `lib`, `adb push` a `/data/local/tmp/spdata/`.
4. `cp -r` a `/data/data/`, recrear `lib` → `$(dirname $(pm path ...))/lib/x86`,
   `chown -R <uid>:<uid>`, `chmod 771`, `restorecon -R`.
5. `am start` y comprobar: la home debe mostrar "Good morning" + tus playlists
   (así se verificó que el login sobrevive a la reinstalación).

Resultado real en el NBRiq: APK de 41,7 MB → **16 MB** (solo `lib/x86`), sesión intacta.


