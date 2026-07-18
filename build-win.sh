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

# OpenOCD uses a non-recursive automake for src (single top-level Makefile),
# with doc/ as a SUBDIR. texinfo 7 chokes on this fork's openocd.texi, and we
# don't need docs, so neutralize makeinfo with a no-op (MAKEINFO=true).
echo "==> Building (docs disabled via MAKEINFO=true)..."
make -j"$(nproc)" MAKEINFO=true

cd "${ROOT}"

echo "==> Assembling distribution in ${DIST_DIR}..."
rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}/bin"

# The openocd binary lives at build/src/openocd.exe (non-recursive layout).
if [ -f "${BUILD_DIR}/src/openocd.exe" ]; then
  cp "${BUILD_DIR}/src/openocd.exe" "${DIST_DIR}/bin/"
elif [ -f "${BUILD_DIR}/src/openocd" ]; then
  cp "${BUILD_DIR}/src/openocd" "${DIST_DIR}/bin/openocd.exe"
else
  echo "ERROR: openocd binary not found under ${BUILD_DIR}/src" >&2
  find "${BUILD_DIR}" -name 'openocd*' -maxdepth 3 -print >&2 || true
  exit 1
fi

echo "==> Installing TCL scripts..."
mkdir -p "${DIST_DIR}/share/openocd/scripts"
cp -R "${ROOT}/tcl/"* "${DIST_DIR}/share/openocd/scripts/"

echo "==> Bundling docs that already exist (if any)..."
mkdir -p "${DIST_DIR}/share/doc/openocd"
for f in README README.Windows COPYING; do
  [ -f "${ROOT}/${f}" ] && cp "${ROOT}/${f}" "${DIST_DIR}/share/doc/openocd/" || true
done

echo "==> Collecting runtime DLLs..."
cd "${DIST_DIR}/bin"

# Detect a working objdump (name differs across MSYS2 environments).
OBJDUMP="$(command -v x86_64-w64-mingw32-objdump 2>/dev/null || command -v objdump 2>/dev/null || true)"
if [ -z "$OBJDUMP" ]; then
  echo "ERROR: objdump not found; cannot resolve DLL dependencies" >&2
  exit 1
fi
echo "    objdump: ${OBJDUMP}"

# 1) Direct dependencies of openocd.exe that live in the MinGW tree.
for f in $("$OBJDUMP" -p openocd.exe | awk '/DLL Name/{print $3}'); do
  if [ -f "/mingw64/bin/$f" ]; then cp -f "/mingw64/bin/$f" .; fi
done

# 2) Recurse into the copied DLLs to pull in their MinGW dependencies.
for pass in 1 2 3; do
  for dll in *.dll; do
    [ -f "$dll" ] || continue
    for f in $("$OBJDUMP" -p "$dll" | awk '/DLL Name/{print $3}'); do
      if [ ! -f "$f" ] && [ -f "/mingw64/bin/$f" ]; then cp -f "/mingw64/bin/$f" .; fi
    done
  done
done

# 3) Safety net: ensure the core MinGW runtime DLLs are present even if the
#    linker dropped them as already-satisfied for some reason.
for core in libgcc_s_seh-1.dll libwinpthread-1.dll libstdc++-6.dll; do
  if [ ! -f "$core" ] && [ -f "/mingw64/bin/$core" ]; then cp -f "/mingw64/bin/$core" .; fi
done

echo "    DLLs bundled:"; ls -1 *.dll 2>/dev/null | sed 's/^/      /'

# Sanity check: a build without any runtime DLL is broken, fail loudly.
if [ -z "$(ls -A *.dll 2>/dev/null)" ]; then
  echo "ERROR: no runtime DLLs were bundled; the distribution is incomplete" >&2
  exit 1
fi
cd "${ROOT}"

echo "==> Packaging ${DIST_NAME}.tar.xz..."
tar -cJf "${DIST_NAME}.tar.xz" "${DIST_NAME}"

echo "==> Done."
echo "    Binary:  ${DIST_DIR}/bin/openocd.exe"
echo "    Tarball: ${ROOT}/${DIST_NAME}.tar.xz"
