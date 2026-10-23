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
| `AudioFocusRequest` / `requestAudioFocus(AudioFocusRequest)` | 26 | capa de reproducción (**pendiente**) |
| `java.lang.invoke.MethodHandles` | 26 | `ah/K` (Kotlin reflection) |
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
| Sobrevive al login (crash `NotificationChannel`) | ✅ parcheado, pendiente de re-verificar |
| Home / biblioteca | ❓ sin verificar |
| Reproducción | ❌ falta `AudioFocusRequest` |

## 9. Siguientes pasos sugeridos

1. Re-verificar login completo con la build parcheada.
2. Si `AudioManager.requestAudioFocus(AudioFocusRequest)` revienta: redirigir a la sobrecarga de API 8 (`requestAudioFocus(OnAudioFocusChangeListener, int, int)`).
3. Si `VibrationEffect` reaparece por otra ruta (`Notification.defaults`, `AudioAttributes`), ampliar `nbrt.compat.Notif`.
4. Eliminar del APK final las ABIs no-x86 y los recursos `*-v26` no usados (reduce ~40 MB a ~15 MB).
5. Comprobar `AudioTrack`/códecs: en x86 sin NEON el playback usa rutas software; puede necesitar ajustar el buffer.

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

1. **No dejar sockets abiertos al dormir**: modo *Offline* (descargas) o cerrar Spotify con
   `adb shell am force-stop com.spotify.music` antes de quitarte el reloj. Con la app cerrada
   se liberan ~70 MB y desaparecen los temporizadores TCP.
2. **WiFi apagada cuando no escuches** (solo Bluetooth): sin red no hay `ipt_do_table`
   ni `dhd_dpc` en el suspend.
3. **Liberar RAM**: cuantas menos cosas corran de fondo (GMS, watchfaces, apps), menos
   probable es el fallo de asignación de páginas.
4. Arreglo de verdad: kernel/ROM parcheado (fuera del alcance de este repo).

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

