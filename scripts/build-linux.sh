#!/usr/bin/env bash
# =============================================================================
# Build de Fluent Bit en Linux (Ubuntu 22.04 / WSL).
#
# Reproduce la build oficial sobre Ubuntu sin tocar el sistema (instala deps
# via apt si no estan), produce el binario en build-linux/bin/fluent-bit.
#
# Auto-sync desde /mnt/<drv>/...:
#   Si el repo vive en una ruta /mnt/<letra>/... (NTFS visto desde WSL via 9p)
#   el script automaticamente sincroniza una copia a ~/fluent-bit-pragma-build
#   en el filesystem nativo de WSL y se re-ejecuta desde alli. Esto evita
#   tres problemas conocidos al compilar en /mnt:
#     - line endings CRLF en scripts vendorizados (configure -> error 127)
#     - bit de ejecucion no respetado por 9p
#     - 9p es ~5x mas lento que ext4 para builds C grandes
#
#   Para deshabilitar el auto-sync usa --no-sync.
#
# Uso:
#   scripts/build-linux.sh [--clean] [--no-sync]
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"
BUILD_DIR="${REPO_ROOT}/build-linux"

CLEAN=0
SYNC=1
for arg in "$@"; do
    case "$arg" in
        --clean) CLEAN=1 ;;
        --no-sync) SYNC=0 ;;
    esac
done

# -----------------------------------------------------------------------------
# Auto-sync a ext4 nativo cuando estamos sobre /mnt/<drv>/
# -----------------------------------------------------------------------------
if [[ $SYNC -eq 1 && "$REPO_ROOT" == /mnt/* ]]; then
    DEST="${HOME}/fluent-bit-pragma-build"
    echo "==> Detectado repo en 9p ($REPO_ROOT)"
    echo "==> Sincronizando a $DEST (ext4 nativo) para evitar problemas de CRLF/9p"

    if ! command -v rsync >/dev/null 2>&1; then
        sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends rsync
    fi

    mkdir -p "$DEST"
    # Exclusiones ancladas al root del repo (con '/' al inicio) para no
    # filtrar directorios internos llamados 'build/' como lib/zstd-1.5.7/build/
    # que es codigo fuente vendorizado, no artefactos de build.
    rsync -a --delete \
        --exclude='/build/' \
        --exclude='/build-linux/' \
        --exclude='/.git/' \
        --exclude='/.vs/' \
        --exclude='/.venv/' \
        --exclude='*.log' \
        "$REPO_ROOT/" "$DEST/"

    echo "==> Normalizando line endings y permisos en scripts vendorizados"
    PATTERNS=(configure '*.sh' config.guess config.sub install-sh depcomp missing compile ltmain.sh)
    for pat in "${PATTERNS[@]}"; do
        # sed -i es mas robusto que dos2unix: este ultimo se niega a convertir
        # archivos que detecta como 'binary' (libbacktrace/configure trae
        # bytes no-ASCII que disparan ese flag y dos2unix los deja igual).
        find "$DEST" -type f -name "$pat" -exec sed -i 's/\r$//' {} + 2>/dev/null || true
        find "$DEST" -type f -name "$pat" -exec chmod +x {} + 2>/dev/null || true
    done

    echo "==> Verificacion shebang libbacktrace:"
    head -1 "$DEST/lib/libbacktrace-b9e4006/configure" | od -c | head -1

    echo "==> Re-ejecutando build desde $DEST"
    exec "$DEST/scripts/build-linux.sh" "${@}" --no-sync
fi

echo "==> Repo: $REPO_ROOT"
echo "==> Build dir: $BUILD_DIR"

# 1. Dependencias del sistema
NEEDED_PKGS=(
    build-essential
    cmake
    bison
    flex
    pkg-config
    libssl-dev
    libsasl2-dev
    libsystemd-dev
    libyaml-dev
    libpq-dev
    zlib1g-dev
    libcurl4-openssl-dev
)
MISSING=()
for p in "${NEEDED_PKGS[@]}"; do
    if ! dpkg -s "$p" >/dev/null 2>&1; then
        MISSING+=("$p")
    fi
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "==> Instalando dependencias faltantes: ${MISSING[*]}"
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${MISSING[@]}"
fi

# 2. Build dir
if [[ $CLEAN -eq 1 ]]; then
    echo "==> Limpiando $BUILD_DIR"
    rm -rf "$BUILD_DIR"
fi
mkdir -p "$BUILD_DIR"

# 2.5 Fix line endings y permisos para scripts vendored (defensivo)
# Si por alguna razon el sync no se ejecuto y el repo trae CRLF
# (clonado con core.autocrlf=true), normalizamos aqui tambien. Es
# idempotente: si ya esta limpio no hace nada.
if [[ "$REPO_ROOT" == /mnt/* ]]; then
    echo "==> Aviso: build en 9p (/mnt) sin --no-sync no fue invocado; saltando normalizacion"
else
    echo "==> Verificando line endings (defensivo, sed)"
    PATTERNS_DEF=(configure '*.sh' config.guess config.sub install-sh depcomp missing compile ltmain.sh)
    for pat in "${PATTERNS_DEF[@]}"; do
        # sed -i es mas robusto que dos2unix con archivos detectados como binary
        find "${REPO_ROOT}/lib" -type f -name "$pat" -exec sed -i 's/\r$//' {} + 2>/dev/null || true
        find "${REPO_ROOT}/lib" -type f -name "$pat" -exec chmod +x {} + 2>/dev/null || true
    done
fi

# 3. CMake configure
echo "==> CMake configure"
cmake -S "$REPO_ROOT" -B "$BUILD_DIR" \
    -DFLB_RELEASE=On \
    -DFLB_DEBUG=Off \
    -DFLB_TESTS_INTERNAL=Off \
    -DFLB_TESTS_RUNTIME=Off \
    -DFLB_OUT_KINESIS_STREAMS=On \
    -DFLB_OUT_S3=On \
    -DFLB_OUT_CLOUDWATCH_LOGS=On \
    -DFLB_BACKTRACE=Off \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5

# 4. Build
echo "==> Compilando ($(nproc) jobs)"
cmake --build "$BUILD_DIR" -j "$(nproc)"

EXE="$BUILD_DIR/bin/fluent-bit"
if [[ ! -f "$EXE" ]]; then
    echo "ERROR: no se genero $EXE"
    exit 1
fi
echo "==> Generado: $EXE"
"$EXE" --version

# 5. Empaquetar (tar.gz para distribucion uniforme con macOS)
ARCH="$(uname -m)"
VERSION="$(awk -F'"' '/FLB_VERSION_STR/ {print $2; exit}' "${REPO_ROOT}/CMakeLists.txt")"
PKG_NAME="fluent-bit-${VERSION}-linux-${ARCH}"
PKG_DIR="${BUILD_DIR}/${PKG_NAME}"
mkdir -p "${PKG_DIR}/bin"
cp "$EXE" "${PKG_DIR}/bin/fluent-bit"
chmod +x "${PKG_DIR}/bin/fluent-bit"
[[ -f "${REPO_ROOT}/LICENSE" ]] && cp "${REPO_ROOT}/LICENSE" "${PKG_DIR}/"
[[ -f "${REPO_ROOT}/README.md" ]] && cp "${REPO_ROOT}/README.md" "${PKG_DIR}/"

(cd "$BUILD_DIR" && tar -czf "${PKG_NAME}.tar.gz" "$PKG_NAME")
echo ""
echo "==> Paquete: ${BUILD_DIR}/${PKG_NAME}.tar.gz"
ls -lh "${BUILD_DIR}/${PKG_NAME}.tar.gz"
