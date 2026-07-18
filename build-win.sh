#!/bin/bash
# Build OpenOCD for Windows (x86_64, native MinGW-w64 / MSYS2).
# Run this script from the repository root inside an MSYS2 MINGW64 shell.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${ROOT}/build"
DIST_NAME="openocd-win64"
DIST_DIR="${ROOT}/${DIST_NAME}"

cd "${ROOT}"

echo "==> Regenerating autotools build system (jimtcl autosetup dance)..."
# jimtcl ships an autosetup-generated configure; autoreconf would overwrite it
# with a broken autoconf one, so back it up, run autoreconf, then restore.
if grep -q autosetup jimtcl/configure; then
    cp jimtcl/configure jimtcl/configure.autosetup.bak
fi
autoreconf -fi
if [[ -f jimtcl/configure.autosetup.bak ]]; then
    cp jimtcl/configure.autosetup.bak jimtcl/configure
    rm -f jimtcl/configure.autosetup.bak
fi

echo "==> Restoring executable bits lost during git import..."
chmod +x configure jimtcl/configure 2>/dev/null || true
chmod +x build-aux/* src/jtag/drivers/libjaylink/build-aux/* 2>/dev/null || true
find . -name "*.sh" -not -path "./.git/*" -not -path "./build/*" -exec chmod +x {} +

# AX_CONFIG_SUBDIR_OPTION generates a non-portable jimtcl/configure.gnu on some
# platforms; provide an explicit one that passes the needed jimtcl options.
cat > jimtcl/configure.gnu <<'EOF'
#!/bin/sh
exec "`dirname "$0"`/configure" --disable-install-jim --with-ext=json "$@"
EOF
chmod +x jimtcl/configure.gnu

echo "==> Configuring..."
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"
../configure --disable-werror --disable-dependency-tracking \
  --enable-ftdi \
  --enable-stlink \
  --enable-ti-icdi \
  --enable-ulink \
  --enable-usb-blaster \
  --enable-usb_blaster_2 \
  --enable-cmsis-dap \
  --enable-jlink \
  --enable-vsllink \
  --enable-remote-bitbang \
  --enable-dummy \
  --prefix="${DIST_DIR}"

echo "==> Building jimtcl..."
make -C jimtcl -j"$(nproc)"

echo "==> Building openocd (skipping docs)..."
make -C src -j"$(nproc)"

echo "==> Installing openocd binary..."
make -C src install

cd "${ROOT}"

echo "==> Installing TCL scripts..."
mkdir -p "${DIST_DIR}/share/openocd/scripts"
cp -R "${ROOT}/tcl/"* "${DIST_DIR}/share/openocd/scripts/"

echo "==> Collecting runtime DLLs..."
mkdir -p "${DIST_DIR}/bin"
cd "${DIST_DIR}/bin"
for f in $(x86_64-w64-mingw32-objdump -p openocd.exe | grep 'DLL Name' | awk '{print $3}'); do
  if [ -f "/mingw64/bin/$f" ]; then cp "/mingw64/bin/$f" .; fi
done
# grab any locally-built DLLs (e.g. libjim) that live next to the build tree
for d in "${BUILD_DIR}/jimtcl" "${BUILD_DIR}/src"; do
  if [ -d "$d" ]; then
    for f in "$d"/*.dll; do [ -f "$f" ] && cp -u "$f" .; done
  fi
done
cd "${ROOT}"

echo "==> Packaging ${DIST_NAME}.tar.xz..."
tar -cJf "${DIST_NAME}.tar.xz" "${DIST_NAME}"

echo "==> Done."
echo "    Binary:  ${DIST_DIR}/bin/openocd.exe"
echo "    Tarball: ${ROOT}/${DIST_NAME}.tar.xz"
