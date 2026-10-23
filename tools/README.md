# tools/

Aquí van los binarios necesarios para `scripts/build.sh`. **No se versionan** (ver `.gitignore`).

La forma fácil:

```bash
./scripts/setup.sh
```

La forma manual:

```bash
mkdir -p tools && cd tools
curl -LO https://github.com/baksmali/smali/releases/download/3.0.10/baksmali-3.0.10-fat.jar
curl -LO https://github.com/baksmali/smali/releases/download/3.0.10/smali-3.0.10-fat.jar
mv baksmali-3.0.10-fat.jar baksmali.jar
mv smali-3.0.10-fat.jar smali.jar
curl -LO https://maven.google.com/com/android/tools/desugar_jdk_libs/2.1.5/desugar_jdk_libs-2.1.5.jar
```

| Fichero | Versión | De dónde |
|---|---|---|
| `baksmali.jar` | 3.0.10 | https://github.com/baksmali/smali/releases/tag/3.0.10 |
| `smali.jar` | 3.0.10 | mismo release |
| `desugar_jdk_libs-2.1.5.jar` | 2.1.5 | maven.google.com |
| `debug.jks` | — | se genera solo en el primer build |

`zipalign`, `apksigner`, `dexdump` y `d8` vienen en los Android **build-tools** (probado con 35.0.0).

