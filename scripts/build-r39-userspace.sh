#!/usr/bin/env bash
# build-r39-userspace.sh — build the two JetPack r39 Talos system extensions the GPU needs
# besides the kernel modules, from NVIDIA's Jetson Linux BSP tarball:
#
#   nvidia-firmware-ext:<FIRMWARE_EXT_TAG>      GA10B firmware (package nvidia-l4t-firmware)
#   nvidia-tegra-userspace:<USERSPACE_EXT_TAG>  libcuda and the NVIDIA runtime libraries it
#                                               needs (packages nvidia-l4t-cuda-nvgpu, -core)
#
# Why a build step and not a download on the node, as r36 did: the r39 core GPU packages are
# not in NVIDIA's apt repository any more, only in the BSP tarball (1.3 GB). So CI extracts the
# few debs it needs, and the libraries and firmware travel inside the node image like the
# kernel modules, always matching the nvgpu build. The libraries are the closure of
# libcuda.so.1 (computed from the ELF headers, so it cannot drift from the BSP release).
#
# Usage:
#   JETPACK=r39 scripts/build-r39-userspace.sh             assemble + verify (+ build images if docker is there)
#   JETPACK=r39 PUSH=1 REGISTRY_DOCKER=ghcr.io/<owner> scripts/build-r39-userspace.sh
# Env: WORK (default /tmp/r39-userspace), PUSH (default 0), BSP_URL / BSP_SHA256 (override pins).
set -euo pipefail
source "$(dirname "$0")/common.sh"

[[ "${JETPACK}" == "r39" ]] || error "This script builds the JetPack r39 extensions; run it with JETPACK=r39."

WORK="${WORK:-/tmp/r39-userspace}"
PUSH="${PUSH:-0}"
BSP_URL="${BSP_URL:-https://developer.nvidia.com/downloads/embedded/l4t/r39_release_v2.1/release/Jetson_Linux_r39.2.1_aarch64.tbz2}"
BSP_SHA256="${BSP_SHA256:-2e5619088ba88e85dab25247f033d70659b6f676ff835176a07766dcb0fdbe6b}"
BSP_FILE="${WORK}/$(basename "${BSP_URL}")"
DEBS_DIR="${WORK}/debs"
X="${WORK}/x"          # extracted debs
OUT="${WORK}/out"      # extension build contexts

mkdir -p "${WORK}" "${DEBS_DIR}"
rm -rf "${X}" "${OUT}"
mkdir -p "${X}" "${OUT}"

info "r39 userspace extensions: firmware ${FIRMWARE_EXT_TAG}, userspace ${USERSPACE_EXT_TAG}"

# ── 1. BSP tarball ───────────────────────────────────────────────────────────
if [[ ! -f "${BSP_FILE}" ]]; then
  info "Downloading ${BSP_URL}"
  curl -fL --retry 3 -o "${BSP_FILE}" "${BSP_URL}"
fi
GOT=$(sha256sum "${BSP_FILE}" | cut -d' ' -f1)
[[ "${GOT}" == "${BSP_SHA256}" ]] \
  || error "BSP checksum mismatch: got ${GOT}, expected ${BSP_SHA256}"
info "BSP checksum OK ($(du -hL "${BSP_FILE}" | cut -f1))"

# ── 2. the three debs ────────────────────────────────────────────────────────
PKGS=(nvidia-l4t-core nvidia-l4t-cuda-nvgpu nvidia-l4t-firmware)
if ! ls "${DEBS_DIR}"/nvidia-l4t-core_*_arm64.deb >/dev/null 2>&1; then
  info "Extracting ${PKGS[*]} from the BSP (bzip2 stream, a few minutes)"
  WILD=()
  for p in "${PKGS[@]}"; do WILD+=(--wildcards "*/nv_tegra/l4t_deb_packages/${p}_*_arm64.deb"); done
  tar -xjf "${BSP_FILE}" -C "${DEBS_DIR}" --strip-components=3 "${WILD[@]}"
fi
for p in "${PKGS[@]}"; do
  DEB=$(ls "${DEBS_DIR}/${p}_"*_arm64.deb 2>/dev/null | head -1)
  [[ -f "${DEB}" ]] || error "${p} deb not found in the BSP"
  mkdir -p "${X}/${p}"
  dpkg-deb -x "${DEB}" "${X}/${p}"
  info "  ${p}: $(basename "${DEB}")"
done

# ── 3. userspace: the closure of libcuda.so.1 ────────────────────────────────
LIB_OUT="${OUT}/userspace/rootfs/usr/local/lib/nvidia-tegra"
mkdir -p "${LIB_OUT}"
LIBDIRS=("${X}/nvidia-l4t-cuda-nvgpu/opt/nvidia/l4t-gpu-libs/nvgpu"
         "${X}/nvidia-l4t-core/usr/lib/aarch64-linux-gnu/nvidia")

is_system_lib() {
  case "$1" in
    libc.so*|libm.so*|libdl.so*|librt.so*|libpthread.so*|libgcc_s.so*|libstdc++.so*|libutil.so*|libresolv.so*|ld-linux-aarch64.so*) return 0 ;;
  esac
  return 1
}
find_lib() { local d; for d in "${LIBDIRS[@]}"; do [[ -e "${d}/$1" ]] && { echo "${d}/$1"; return 0; }; done; return 1; }
needed() { readelf -d "$1" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p'; }

# copy a library, its symlink chain, and return the real file
copy_lib() { # copy_lib <path> <destdir>
  local p="$1" dest="$2" cur="$1" next
  while [[ -L "${cur}" ]]; do
    cp -a "${cur}" "${dest}/"
    next="$(dirname "${cur}")/$(readlink "${cur}")"
    cur="${next}"
  done
  cp -a "${cur}" "${dest}/"
  echo "${cur}"
}

declare -A SEEN=()
QUEUE=(libcuda.so.1)
while ((${#QUEUE[@]})); do
  NAME="${QUEUE[0]}"; QUEUE=("${QUEUE[@]:1}")
  [[ -n "${SEEN[${NAME}]:-}" ]] && continue
  SEEN[${NAME}]=1
  is_system_lib "${NAME}" && continue
  SRC=$(find_lib "${NAME}") || error "${NAME} (needed by the closure of libcuda) not found in the BSP debs"
  REAL=$(copy_lib "${SRC}" "${LIB_OUT}")
  while IFS= read -r n; do QUEUE+=("${n}"); done < <(needed "${REAL}")
done
# the unversioned development symlink, for dlopen("libcuda.so")
[[ -e "${LIBDIRS[0]}/libcuda.so" ]] && cp -a "${LIBDIRS[0]}/libcuda.so" "${LIB_OUT}/"

# verification: the closure is complete inside the output directory
FAIL=0
for f in "${LIB_OUT}"/*; do
  [[ -L "${f}" ]] && continue
  readelf -h "${f}" | grep -q "AArch64" || { warn "not an AArch64 ELF: ${f##*/}"; FAIL=1; }
  while IFS= read -r n; do
    is_system_lib "${n}" && continue
    [[ -e "${LIB_OUT}/${n}" ]] || { warn "${f##*/} needs ${n}, not in the output"; FAIL=1; }
  done < <(needed "${f}")
done
CUDA_SIZE=$(stat -c %s "${LIB_OUT}/libcuda.so.1.1" 2>/dev/null || echo 0)
(( CUDA_SIZE > 50000000 )) || { warn "libcuda.so.1.1 is only ${CUDA_SIZE} bytes"; FAIL=1; }
[[ -L "${LIB_OUT}/libcuda.so.1" ]] || { warn "libcuda.so.1 symlink missing"; FAIL=1; }
(( FAIL == 0 )) || error "userspace library verification failed"
info "userspace: $(find "${LIB_OUT}" -maxdepth 1 \( -type f -o -type l \) | wc -l) entries, $(du -sh "${LIB_OUT}" | cut -f1), libcuda.so.1.1 ${CUDA_SIZE} bytes"
ls -l "${LIB_OUT}" | sed 's/^/    /'

# ── 4. firmware ──────────────────────────────────────────────────────────────
FW_SRC="${X}/nvidia-l4t-firmware/lib/firmware/nvidia/ga10b"
[[ -d "${FW_SRC}" ]] || error "ga10b firmware directory not found in nvidia-l4t-firmware"
FW_OUT="${OUT}/firmware/rootfs/usr/lib/firmware"
mkdir -p "${FW_OUT}"
# same layout as the r36 extension: /usr/lib/firmware/ga10b (nvgpu asks for nvidia/ga10b/<file>,
# then ga10b/<file>; firmware_class.path=/usr/lib/firmware is on the kernel command line)
cp -a "${FW_SRC}" "${FW_OUT}/ga10b"
for must in gpmu_ucode_next_prod_image.bin pmu_pkc_prod_sig.bin fecs_encrypt_prod.bin gpccs_encrypt_prod.bin; do
  [[ -s "${FW_OUT}/ga10b/${must}" ]] || error "firmware file missing or empty: ${must}"
done
info "firmware: $(find "${FW_OUT}/ga10b" -type f | wc -l) files, $(du -sh "${FW_OUT}/ga10b" | cut -f1)"

# ── 5. extension manifests and build contexts ────────────────────────────────
write_ctx() { # write_ctx <dir> <name> <version> <description>
  printf 'version: v1alpha1\nmetadata:\n  name: %s\n  version: %s\n  author: custom-build\n  description: %s\n  compatibility:\n    talos:\n      version: ">= 1.12.6"\n' \
    "$2" "$3" "$4" > "$1/manifest.yaml"
  printf 'FROM scratch\nCOPY manifest.yaml /manifest.yaml\nCOPY rootfs /rootfs\n' > "$1/Dockerfile"
}
BSP_REL="$(basename "${DEBS_DIR}"/nvidia-l4t-core_*_arm64.deb | sed 's/^nvidia-l4t-core_//; s/_arm64.deb$//')"
write_ctx "${OUT}/firmware" nvidia-firmware-ext "${FIRMWARE_EXT_TAG}" \
  "NVIDIA GA10B firmware from JetPack 7.2 (Jetson Linux ${BSP_REL})"
write_ctx "${OUT}/userspace" nvidia-tegra-userspace "${USERSPACE_EXT_TAG}" \
  "NVIDIA Jetson userspace for CUDA: libcuda and its runtime libraries from JetPack 7.2 (Jetson Linux ${BSP_REL})"

# ── 6. images ────────────────────────────────────────────────────────────────
if [[ "${PUSH}" == "1" ]]; then
  [[ -n "${REGISTRY_DOCKER:-}" ]] || error "PUSH=1 needs REGISTRY_DOCKER (e.g. ghcr.io/<owner>)"
  docker buildx build --platform linux/arm64 \
    -t "${REGISTRY_DOCKER}/nvidia-firmware-ext:${FIRMWARE_EXT_TAG}" --push "${OUT}/firmware/"
  docker buildx build --platform linux/arm64 \
    -t "${REGISTRY_DOCKER}/nvidia-tegra-userspace:${USERSPACE_EXT_TAG}" --push "${OUT}/userspace/"
  info "pushed ${REGISTRY_DOCKER}/nvidia-firmware-ext:${FIRMWARE_EXT_TAG}"
  info "pushed ${REGISTRY_DOCKER}/nvidia-tegra-userspace:${USERSPACE_EXT_TAG}"
elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  for e in firmware userspace; do
    docker buildx build --platform linux/arm64 --output "type=local,dest=${OUT}/image-${e}" "${OUT}/${e}/" >/dev/null
    info "image check ${e}: $(find "${OUT}/image-${e}" -type f | wc -l) files in the image"
  done
else
  info "no docker: skipped the image build (assembly and verification done)"
fi
info "done"
