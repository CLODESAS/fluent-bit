#!/usr/bin/env bash
# =============================================================================
# Build de Fluent Bit en macOS (arm64 / x86_64).
#
# Reproduce localmente o en CI (runner macos-latest) el packaging para Mac.
# Genera build-macos/bin/fluent-bit (Mach-O) listo para correr en macOS.
#
# Aplica los mismos workarounds aprendidos en Linux:
#   -DCMAKE_POLICY_VERSION_MINIMUM=3.5  : CMake 4.x removio policies <3.5
#                                        que algunos sub-proyectos vendorizados
#                                        aun declaran.
#   -DFLB_BACKTRACE=Off                 : libbacktrace tiene problemas de
#                                        autoconf en Mac (mach/clock.h ausente
#                                        en glibc-style headers).
#
# Pre-requisitos (Homebrew):
#   brew install cmake bison flex pkg-config openssl@3
#
# Uso:
#   chmod +x scripts/build-macos.sh
#   ./scripts/build-macos.sh [--clean]
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"
BUILD_DIR="${REPO_ROOT}/build-macos"

CLEAN=0
for arg in "$@"; do
    case "$arg" in
        --clean) CLEAN=1 ;;
    esac
done

echo "==> Repo: $REPO_ROOT"
echo "==> Build dir: $BUILD_DIR"
echo "==> Arquitectura host: $(uname -m)"

# ---------------------------------------------------------------------------
# 1. Verificar que estamos en macOS
# ---------------------------------------------------------------------------
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "ERROR: este script solo corre en macOS. Detectado: $(uname -s)"
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. Dependencias Homebrew
# ---------------------------------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
    echo "ERROR: Homebrew no instalado. https://brew.sh"
    exit 1
fi

NEEDED_BREW=(cmake bison flex pkg-config openssl@3)
MISSING_BREW=()
for p in "${NEEDED_BREW[@]}"; do
    if ! brew list --formula "$p" >/dev/null 2>&1; then
        MISSING_BREW+=("$p")
    fi
done
if [[ ${#MISSING_BREW[@]} -gt 0 ]]; then
    echo "==> Instalando deps brew: ${MISSING_BREW[*]}"
    brew install "${MISSING_BREW[@]}"
fi

# bison/flex de Homebrew estan keg-only en macOS: hay que ponerlos en PATH
# explicitamente para que CMake los detecte por encima de los del sistema.
BREW_PREFIX="$(brew --prefix)"
export PATH="${BREW_PREFIX}/opt/bison/bin:${BREW_PREFIX}/opt/flex/bin:${PATH}"
export OPENSSL_ROOT_DIR="${BREW_PREFIX}/opt/openssl@3"

echo "==> bison: $(command -v bison) ($(bison --version | head -1))"
echo "==> flex:  $(command -v flex)  ($(flex --version))"
echo "==> openssl: $OPENSSL_ROOT_DIR"

# ---------------------------------------------------------------------------
# 3. Build dir
# ---------------------------------------------------------------------------
if [[ $CLEAN -eq 1 ]]; then
    echo "==> Limpiando $BUILD_DIR"
    rm -rf "$BUILD_DIR"
fi
mkdir -p "$BUILD_DIR"

# ---------------------------------------------------------------------------
# 4. CMake configure
# ---------------------------------------------------------------------------
echo "==> CMake configure"
cmake -S "$REPO_ROOT" -B "$BUILD_DIR" \
    -DOPENSSL_ROOT_DIR="$OPENSSL_ROOT_DIR" \
    -DFLB_RELEASE=On \
    -DFLB_DEBUG=Off \
    -DFLB_TESTS_INTERNAL=Off \
    -DFLB_TESTS_RUNTIME=Off \
    -DFLB_OUT_KINESIS_STREAMS=On \
    -DFLB_OUT_S3=On \
    -DFLB_OUT_CLOUDWATCH_LOGS=On \
    -DFLB_BACKTRACE=Off \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5

# ---------------------------------------------------------------------------
# 5. Compilar
# ---------------------------------------------------------------------------
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
echo "==> Compilando ($JOBS jobs)"
cmake --build "$BUILD_DIR" -j "$JOBS"

EXE="$BUILD_DIR/bin/fluent-bit"
if [[ ! -f "$EXE" ]]; then
    echo "ERROR: no se genero $EXE"
    exit 1
fi
echo "==> Generado: $EXE"
"$EXE" --version

# ---------------------------------------------------------------------------
# 6. Empaquetar (tar.gz para distribucion)
# ---------------------------------------------------------------------------
ARCH="$(uname -m)"  # arm64 | x86_64
VERSION="$(awk -F'"' '/FLB_VERSION_STR/ {print $2; exit}' CMakeLists.txt)"
PKG_NAME="fluent-bit-${VERSION}-darwin-${ARCH}"
PKG_DIR="${BUILD_DIR}/${PKG_NAME}"
mkdir -p "${PKG_DIR}/bin"
cp "$EXE" "${PKG_DIR}/bin/fluent-bit"
chmod +x "${PKG_DIR}/bin/fluent-bit"

# Incluir LICENSE y README si existen
[[ -f "${REPO_ROOT}/LICENSE" ]] && cp "${REPO_ROOT}/LICENSE" "${PKG_DIR}/"
[[ -f "${REPO_ROOT}/README.md" ]] && cp "${REPO_ROOT}/README.md" "${PKG_DIR}/"

(cd "$BUILD_DIR" && tar -czf "${PKG_NAME}.tar.gz" "$PKG_NAME")
echo ""
echo "==> Paquete: ${BUILD_DIR}/${PKG_NAME}.tar.gz"
ls -lh "${BUILD_DIR}/${PKG_NAME}.tar.gz"
