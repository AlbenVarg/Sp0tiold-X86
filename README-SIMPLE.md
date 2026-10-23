# 🧸 Guía fácil (para dummies)

> **¿Qué es esto?** Una app de Spotify para Wear OS que **sí funciona** en relojes viejos con Android 7.1.1 e Intel (x86), como el NBRiq.
>
> **¿Por qué existe?** Porque la app oficial pide Android 9 o superior y se niega a instalarse. Aquí está el truco para engañarla.
>
> **¿Tiempo?** Unos 15 minutos la primera vez, 2 minutos las siguientes.

---

## 0. ¿Mi reloj sirve?

Sí, si cumple **las tres**:

- [ ] Es un smartwatch con **Android 7.1.1** (o "Wear OS 2.0")
- [ ] Su procesador es **Intel / x86** (no ARM)
- [ ] Tienes un **ordenador** con cable USB y **`adb`**

Para comprobarlo, conecta el reloj y escribe:

```bash
adb shell getprop ro.build.version.sdk      # debe decir 25
adb shell getprop ro.product.cpu.abi        # debe decir x86
```

¿Sale `25` y `x86`? Adelante. ¿Sale `arm64-v8a`? Este repo no es para ti (pero probablemente la app oficial sí te valga).

---

## 1. Prepara el ordenador (solo la primera vez)

Necesitas tres cosas: **Java**, **Python** y las **herramientas de Android**.

### macOS

```bash
brew install openjdk@17 android-commandlinetools python3
```

### Linux (Debian/Ubuntu)

```bash
sudo apt install openjdk-17-jdk python3 android-sdk-build-tools android-sdk-platform-tools
```

### Windows

Instala [WSL](https://learn.microsoft.com/windows/wsl/) y sigue los pasos de Linux. (En Windows "puro" no está probado.)

Ahora descarga los "cachivaches" que hacen el trabajo duro:

```bash
git clone https://github.com/AlbenVarg/Sp0tiold-X86.git
cd Sp0tiold-X86
./scripts/setup.sh
```

Ese script se baja ~10 MB de herramientas a la carpeta `tools/`. Verás al final algo como:

```
Herramientas listas en .../tools:
baksmali.jar
desugar_jdk_libs-2.1.5.jar
smali.jar
```

✅ **Paso 1 terminado.** No lo vuelvas a hacer nunca más.

---

## 2. Consigue el APK original

Descarga de APKMirror el archivo **exactamente** con este nombre:

```
com.spotify.music_9.0.40.386-127404690_minAPI28(arm64-v8a,armeabi-v7a,x86,x86_64)(nodpi)_apkmirror.com.apk
```

Búscalo en APKMirror como *Spotify: Music and Podcasts* → versión **9.0.40.386** → variante **Wear OS**.

> ⚠️ **Tiene que ser la de Wear OS**, no la del móvil. Y tiene que incluir **x86** entre las arquitecturas.

Comprueba que es la buena:

```bash
aapt2 dump badging tu_archivo.apk | grep -iE "package:|sdkversion:|native-code:"
```

Debe salir algo así:

```
package: name='com.spotify.music' versionName='9.0.40.386' ...
minSdkVersion:'28'                                        <- 28 = necesita Android 9
native-code: 'arm64-v8a' 'armeabi-v7a' 'x86' 'x86_64'     <- x86 presente
```

> En build-tools antiguos la línea se llama `sdkVersion:'28'` en vez de `minSdkVersion:'28'`. Es lo mismo.

Si no ves `x86`, has descargado el archivo equivocado.

---

## 3. Fabrica tu APK parcheado

Un solo comando:

```bash
./scripts/build.sh "/ruta/a/com.spotify.music_9.0.40.386-..._apkmirror.com.apk"
```

Tarda **3-5 minutos**. Verás seis pasos:

```
==> 1/6 minSdkVersion -> 25                    (le dice al reloj "vale, te acepto")
==> 2/6 clases de desugar (java.time / java.nio.file -> nbrt/*)
==> 3/6 baksmali del classes.dex               (desmonta la app en trocitos de texto)
==> 4/6 helper nbrt.compat.Notif + renombrado + call sites API 26+
==> 5/6 reensamblado (smali, api 25)           (la vuelve a montar)
==> 6/6 repack + zipalign + apksigner          (la firma para que se pueda instalar)
```

Si termina con:

```
OK -> .../build/spotify-wear-api25.apk
```

🎉 **Ya tienes tu Spotify.** Si sale `AVISO: quedan N ficheros...`, algo se quedó sin parchear: cópialo y ábrele un issue.

---

## 4. Instálalo en el reloj

1. Conecta el reloj por USB y comprueba:
   ```bash
   adb devices          # debe aparecer tu reloj como "device"
   ```

2. Desinstala el Spotify viejo si lo tenías (la firma cambia, si no lo haces dará error):
   ```bash
   adb uninstall com.spotify.music
   ```

3. Instala el nuevo:
   ```bash
   adb install build/spotify-wear-api25.apk
   ```

4. Ábrelo desde el reloj (o con):
   ```bash
   adb shell am start -n com.spotify.music/com.spotify.wear.main.MainActivity
   ```

> 🔑 Si algún día **reconstruyes el APK en otro ordenador**, se firmará con otra clave distinta, así que antes tendrás que hacer `adb uninstall com.spotify.music`. Y ojo: desinstalar **borra la sesión**, tendrás que emparejar de nuevo.

---

## 5. Inicia sesión

1. En el reloj verás **"Continue on phone"** y un **código de 6 letras** (ej. `UP6K52`).
2. En tu móvil u ordenador abre 👉 **https://www.spotify.com/pair**
3. Entra con tu cuenta normal de Spotify e **introduce ese código**.
4. Espera 5-10 segundos. El reloj entra solo.

> 📌 **Apunta el código rápido**: caduca en unos minutos. Y si la app se cierra sola al meterlo, mira la sección siguiente.

---

## 6. Si algo falla

| Lo que ves | Qué significa | Qué hacer |
|---|---|---|
| `INSTALL_FAILED_OLDER_SDK` | El reloj es más viejo que el mínimo que acepta la app | No usaste el APK parcheado, o el paso 1 del build falló |
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | Hay otra versión con firma distinta | `adb uninstall com.spotify.music` y reintenta |
| `INSTALL_FAILED_NO_MATCHING_ABIS` | El APK no trae x86 | Has descargado la variante equivocada |
| La app abre y cierra al instante | Crash por algo de Android 9 que falta | `adb logcat -d \| grep FATAL` y abre un issue con el texto |
| Se cierra **justo después** de meter el código | Crash al entrar en la zona logueada | Es lo que arreglan los parches del build; usa la última versión del repo |
| El código caduca / la app se reinicia | El login no llegó a guardarse | Genera uno nuevo y vuelve a emparejar |
| Pantalla en negro sin fin | El servidor ya no da datos (cliente viejo) | Estás usando el 8.4.84; usa el 9.0.40 con este repo |
| `No such file: tools/baksmali.jar` | No ejecutaste el setup | `./scripts/setup.sh` |
| `no encuentro build-tools` | Falta el Android SDK | `brew install android-commandlinetools` o define `BT=/ruta/build-tools/35.0.0` |
| **El reloj se reinicia solo** (con la app en segundo plano) | Bug del ROM (watchdog del kernel), no de la app | `./scripts/diag-reboot.sh` lo confirma. Mira la sección 6.1 |

Para ver el error exacto de un crash:

```bash
adb logcat -c
adb shell am start -n com.spotify.music/com.spotify.wear.main.MainActivity
adb logcat -d | grep -A 20 "FATAL EXCEPTION"
```

### 6.1 "Se me reinicia el reloj"

**No es Spotify.** Lo comprobé con datos del propio reloj: el reinicio lo provoca el
**watchdog** del chip (el "perro guardián" que resetea cuando algo se cuelga), por bugs
del kernel del ROM que ya existían antes de instalar la app. Un crash de app cierra la app;
no reinicia el reloj.

Compruébalo tú mismo:

```bash
./scripts/diag-reboot.sh
```

Te dirá el motivo del último reinicio y traducirá el fallo del kernel. Lo que suele salir:

`ipt_do_table` / `nf_conntrack` → bug de red al entrar en reposo (`suspend`)
`i2c_dw_xfer` / `max170` → bug del driver de batería
`page_alloc` → el reloj se quedó sin memoria (tiene solo 455 MB)

Qué reduce las probabilidades (de más a menos útil):

1. **Modo dormir**: antes de quitarte el reloj,
   `./scripts/spotify-sleep.sh on` (cierra Spotify y apaga la WiFi). Al ponértelo,
   `./scripts/spotify-sleep.sh off` (enciende la WiFi y abre Spotify).
2. **No dejes Spotify abierto de fondo**: `adb shell am force-stop com.spotify.music`
   libera ~70 MB y cierra sus conexiones (es lo que hace el modo dormir).
3. **Usa el modo Offline** (canciones descargadas): menos conexiones abiertas.
4. **Cuanta menos cosa de fondo, mejor**: `./scripts/debloat.sh disable` apaga apps de
   Google que el reloj no necesita. Se puede deshacer con `./scripts/debloat.sh restore`.

Detalle técnico completo en [`docs/FINDINGS.md`](docs/FINDINGS.md#10-el-reloj-se-reinicia-solo--no-es-la-app).

### 6.2 Quiero cambiar el APK sin volver a emparejar

Si ya tienes sesión y quieres probar una versión nueva, **no** hagas `adb uninstall`
(perderías el login). Con root:

```bash
./scripts/reinstall-keep-data.sh build/spotify-wear-api25.apk
# ¿algo salió mal? vuelve atrás:
./scripts/reinstall-keep-data.sh --rollback
```

Guarda los datos en `$TMPDIR/spotify-data.tgz` y el APK viejo en `$TMPDIR/sp0tiold-old.apk`,
reinstala y devuelve los datos con el uid y el contexto SELinux correctos. Cómo funciona
por dentro (y los tres tropiezos con `tar`, `cp -a` y SELinux) está en
[`docs/FINDINGS.md` §11](docs/FINDINGS.md#11-cambiar-el-apk-sin-perder-la-sesión-con-root).

---

## 7. Preguntas tontas (con respuesta honesta)

**¿Necesito root?**
No. Ni Magisk, ni desbloquear el bootloader. Solo `adb`.

**¿Me pueden banear la cuenta?**
No hay motivo: usas la app oficial de Spotify, solo con parches de compatibilidad. No se toca nada de la cuenta ni se usa ninguna API pirata.

**¿Necesito el móvil cada vez que abro Spotify?**
No. Solo la primera vez, para autorizar. Después el reloj guarda la sesión.

**¿Funciona sin conexión / descarga canciones?**
En teoría sí (la app tiene modo offline), pero no está probado en este reloj. Ojo: el modo offline también ayuda a que el reloj no se reinicie (menos conexiones abiertas, ver 6.1).

**¿Se reinicia el reloj por culpa de la app?**
No. El reloj tiene un bug de kernel (watchdog) que ya se daba antes de instalar Spotify; la app solo lo hace más probable porque consume RAM y mantiene conexiones abiertas. Detalle y mitigaciones en la sección 6.1.

**¿Y el sonido?**
Por Bluetooth, emparejando auriculares al reloj. La reproducción por el altavoz del reloj no está probada.

**¿Por qué es tan complicado?**
Porque Spotify no publica una versión para Android 7. Este repo "traduce" la de Android 9 para que el reloj la entienda.

**¿Puedo compartir el APK que he generado?**
Técnicamente sí, pero es material con copyright de Spotify. Mejor comparte **este repo** y que cada uno se lo fabrique.

**¿Esto es legal?**
Parchear una app que ya tienes para que funcione en tu propio dispositivo está en zona gris según el país. Este repo **no** incluye el APK ni código de Spotify: solo herramientas y documentación. Úsalo bajo tu responsabilidad.

---

## 8. Glosario mínimo

| Palabra | Traducción a persona normal |
|---|---|
| **APK** | El "instalador" de una app de Android |
| **minSdk / API 25** | "Versión mínima de Android que acepto". 25 = Android 7.1 |
| **x86** | Tipo de procesador (Intel). Los móviles suelen ser ARM |
| **dex** | El código compilado dentro del APK (como un `.exe`) |
| **smali** | Ese mismo código, pero en texto legible que se puede editar |
| **baksmali / smali** | Las herramientas que convierten dex ↔ texto |
| **desugar** | Añadir a la app las piezas modernas que el Android viejo no trae |
| **firmar** | Poner un sello para que el reloj acepte el APK |
| **adb** | El cable/programa para hablar con el reloj desde el PC |

---

## 9. ¿Quieres entender el *por qué*?

Todo el detalle técnico (qué se rompe, qué se parchea, por qué) está en:

- 📄 [README.md](README.md) — resumen técnico
- 🔬 [docs/FINDINGS.md](docs/FINDINGS.md) — la investigación completa, con los crash reales y los callejones sin salida

---

*Si te ha servido, deja una ⭐ en el repo. Si no funciona en tu reloj, abre un issue con el modelo, la versión de Android y el `logcat`.*

