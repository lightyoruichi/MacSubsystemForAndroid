#!/bin/bash
# Bundle QEMU for the Mac app: qemu-system-aarch64 and qemu-img built from source
# with SDL audio, their libraries (install names rewritten to point inside the
# app), and the arm64 UEFI firmware. Output: build/payload/qemu/{Helpers,Frameworks/qemu,share}
#
#   core/scripts/bundle-qemu.sh
#
# Built rather than taken from Homebrew because Homebrew's QEMU has no SDL, and
# QEMU's Core Audio backend can only play (max_voices_in = 0): the microphone
# needs `-audiodev sdl`. Run on an Apple-silicon Mac (or macOS runner) with
# Homebrew. QEMU runs as its own process, so its GPLv2 licence sits beside the
# app's GPLv3 one; NOTICE.md says where its source comes from.
set -euo pipefail

QEMU_VERSION=11.1.2
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ROOT}/build/payload/qemu"
SRC="${ROOT}/build/qemu-${QEMU_VERSION}"
QEMU="${ROOT}/build/qemu-install"

command -v brew >/dev/null || { echo "Homebrew is required"; exit 1; }
brew install --quiet meson ninja pkgconf glib pixman libslirp dtc capstone zstd sdl2 dylibbundler

if [ ! -x "${QEMU}/bin/qemu-system-aarch64" ]; then
    mkdir -p "${ROOT}/build"
    if [ ! -d "${SRC}" ]; then
        curl -fL "https://download.qemu.org/qemu-${QEMU_VERSION}.tar.xz" | tar -xJ -C "${ROOT}/build"
    fi
    # Homebrew's flags (Formula/q/qemu.rb), trimmed to the one target, plus SDL.
    (cd "${SRC}" && ./configure --prefix="${QEMU}" \
        --target-list=aarch64-softmmu \
        --disable-docs --disable-guest-agent --disable-bsd-user \
        --disable-pvg --disable-gtk --enable-cocoa --enable-sdl \
        --enable-slirp --enable-capstone --enable-fdt=system --enable-zstd \
        --audio-drv-list=coreaudio,sdl \
        --extra-cflags="-I$(brew --prefix)/include" --extra-ldflags="-L$(brew --prefix)/lib" \
        && make -j"$(sysctl -n hw.ncpu)" install)
fi
"${QEMU}/bin/qemu-system-aarch64" -audiodev help | grep -qx sdl || { echo "QEMU built without SDL audio"; exit 1; }
echo "Bundling $(${QEMU}/bin/qemu-system-aarch64 --version | head -1)"

rm -rf "${OUT}"
mkdir -p "${OUT}/Helpers" "${OUT}/Frameworks/qemu" "${OUT}/share"
cp "${QEMU}/bin/qemu-system-aarch64" "${QEMU}/bin/qemu-img" "${OUT}/Helpers/"
chmod u+w "${OUT}/Helpers/"*

# Copy every non-system dylib next to the app and point the binaries at it.
dylibbundler --overwrite-files --bundle-deps --create-dir \
    --fix-file "${OUT}/Helpers/qemu-system-aarch64" \
    --fix-file "${OUT}/Helpers/qemu-img" \
    --dest-dir "${OUT}/Frameworks/qemu" \
    --install-path "@executable_path/../Frameworks/qemu/" \
    --search-path "$(brew --prefix)/lib"
# Homebrew's SDL2 is sdl2-compat, which dlopens SDL3 from beside itself; without it,
# QEMU hangs on an error dialog at start.
cp "$(brew --prefix sdl3)/lib/libSDL3.0.dylib" "${OUT}/Frameworks/qemu/libSDL3.dylib"
chmod u+w "${OUT}/Frameworks/qemu/libSDL3.dylib"
install_name_tool -id "@loader_path/libSDL3.dylib" "${OUT}/Frameworks/qemu/libSDL3.dylib" 2>/dev/null
codesign --force --sign - "${OUT}/Frameworks/qemu/libSDL3.dylib"

cp "${QEMU}/share/qemu/edk2-aarch64-code.fd" "${OUT}/share/"
# QEMU's licence travels with it.
cp "${SRC}/LICENSE" "${OUT}/share/QEMU-LICENSE" 2>/dev/null || true
"${QEMU}/bin/qemu-system-aarch64" --version | head -1 > "${OUT}/share/QEMU-VERSION"

du -sh "${OUT}"
echo "Wrote ${OUT}"
