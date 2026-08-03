#!/usr/bin/env bash
# Build xpeng Kernel (ReSukiSU) and repack into latest LineageOS boot.img
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT_DIR}"

DEVICE="${DEVICE:-xpeng}"
CLANG_VERSION="${CLANG_VERSION:-clang-r563880c}"
CLANG_URL="${CLANG_URL:-https://github.com/SA9990/Toolchain/releases/download/${CLANG_VERSION}/${CLANG_VERSION}.tar.gz}"
TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-${ROOT_DIR}/.ci-toolchain}"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/out}"
WORK_DIR="${WORK_DIR:-${ROOT_DIR}/.ci-work}"
JOBS="${JOBS:-$(nproc)}"

DEFCONFIGS=(
  "arch/arm64/configs/vendor/lahaina-qgki_defconfig"
  "arch/arm64/configs/vendor/lineage_moto-lahaina.config"
  "arch/arm64/configs/vendor/lineage_xpeng.config"
)

mkdir -p "${TOOLCHAIN_DIR}" "${OUT_DIR}" "${WORK_DIR}"
mkdir -p "${WORK_DIR}/boot" "${WORK_DIR}/release"

log() { echo "::group::$1"; }
endlog() { echo "::endgroup::"; }
info() { echo "[+] $*"; }
die() { echo "[!] $*" >&2; exit 1; }

# GitHub / mirrorbits TLS can flake on HTTP/2; prefer HTTP/1.1 + retries
curl_get() {
  curl -L --http1.1 --retry 5 --retry-all-errors --retry-delay 3 "$@"
}

# ---------------------------------------------------------------------------
# 1) Update ReSukiSU submodule to latest main
# ---------------------------------------------------------------------------
gh_env() {
  # Append KEY=VALUE to GITHUB_ENV when running in Actions
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    printf '%s=%s\n' "$1" "$2" >> "${GITHUB_ENV}"
  fi
}

update_resukisu() {
  log "Update ReSukiSU submodule"
  if [[ ! -e KernelSU/.git ]]; then
    git submodule update --init --recursive KernelSU
  fi

  if [[ "${UPDATE_RESUKISU:-true}" == "true" ]]; then
    # Ensure full history so KSU_VERSION (rev-list --count) is accurate
    git -C KernelSU fetch --unshallow origin 2>/dev/null || true
    git -C KernelSU fetch origin main --tags --force
    git -C KernelSU checkout -f origin/main
    info "ReSukiSU updated to origin/main"
  else
    info "ReSukiSU kept at current checkout (UPDATE_RESUKISU=false)"
  fi

  RESUKISU_VERSION="$(git -C KernelSU describe --tags --always)"
  RESUKISU_SHA="$(git -C KernelSU rev-parse --short=8 HEAD)"
  # Match ReSukiSU Kbuild: KSU_VERSION = 30000 + rev-list-count + 700
  local ksu_count
  ksu_count="$(git -C KernelSU rev-list --count HEAD)"
  KSU_VERSION="$((30000 + ksu_count + 700))"
  # UAPI version from ReSukiSU headers (manager shows as VERSION/UAPI)
  KSU_UAPI_VERSION="$(
    sed -nE 's/.*KERNEL_SU_UAPI_VERSION[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' \
      KernelSU/uapi/supercall.h 2>/dev/null | head -1
  )"
  KSU_UAPI_VERSION="${KSU_UAPI_VERSION:-2}"
  # e.g. v4.1.0-1332-g59c99fdf@ReSukiSU (35046/2)
  RESUKISU_DISPLAY="${RESUKISU_VERSION}@ReSukiSU (${KSU_VERSION}/${KSU_UAPI_VERSION})"

  info "ReSukiSU: ${RESUKISU_DISPLAY}"
  gh_env RESUKISU_VERSION "${RESUKISU_VERSION}"
  gh_env RESUKISU_SHA "${RESUKISU_SHA}"
  gh_env KSU_VERSION "${KSU_VERSION}"
  gh_env KSU_UAPI_VERSION "${KSU_UAPI_VERSION}"
  gh_env RESUKISU_DISPLAY "${RESUKISU_DISPLAY}"
  export RESUKISU_VERSION RESUKISU_SHA KSU_VERSION KSU_UAPI_VERSION RESUKISU_DISPLAY
  printf '%s\n' "${RESUKISU_VERSION}" > "${WORK_DIR}/resukisu_version.txt"
  printf '%s\n' "${RESUKISU_DISPLAY}" > "${WORK_DIR}/resukisu_display.txt"
  printf '%s\n' "${KSU_VERSION}" > "${WORK_DIR}/ksu_version.txt"
  printf '%s\n' "${KSU_UAPI_VERSION}" > "${WORK_DIR}/ksu_uapi_version.txt"
  endlog
}

# ---------------------------------------------------------------------------
# 2) Setup AOSP clang (LineageOS 23.2 default: clang-r563880c)
# ---------------------------------------------------------------------------
setup_clang() {
  log "Setup ${CLANG_VERSION}"
  local stamp="${TOOLCHAIN_DIR}/${CLANG_VERSION}/.ready"
  if [[ ! -f "${stamp}" ]]; then
    rm -rf "${TOOLCHAIN_DIR}/${CLANG_VERSION}"
    mkdir -p "${TOOLCHAIN_DIR}/${CLANG_VERSION}"
    info "Downloading ${CLANG_URL}"
    curl_get -o "${TOOLCHAIN_DIR}/${CLANG_VERSION}.tar.gz" "${CLANG_URL}"
    tar -xzf "${TOOLCHAIN_DIR}/${CLANG_VERSION}.tar.gz" -C "${TOOLCHAIN_DIR}/${CLANG_VERSION}"
    # Some archives nest an extra directory
    if [[ ! -x "${TOOLCHAIN_DIR}/${CLANG_VERSION}/bin/clang" ]]; then
      local nested
      nested="$(find "${TOOLCHAIN_DIR}/${CLANG_VERSION}" -maxdepth 2 -type f -name clang -printf '%h\n' | head -1)"
      if [[ -n "${nested}" && "${nested}" != "${TOOLCHAIN_DIR}/${CLANG_VERSION}/bin" ]]; then
        shopt -s dotglob
        mv "${nested}/"* "${TOOLCHAIN_DIR}/${CLANG_VERSION}/" || true
        shopt -u dotglob
      fi
    fi
    [[ -x "${TOOLCHAIN_DIR}/${CLANG_VERSION}/bin/clang" ]] || die "clang not found after extract"
    rm -f "${TOOLCHAIN_DIR}/${CLANG_VERSION}.tar.gz"
    touch "${stamp}"
  fi
  export PATH="${TOOLCHAIN_DIR}/${CLANG_VERSION}/bin:${PATH}"
  info "clang: $(clang --version | head -1)"
  endlog
}

# ---------------------------------------------------------------------------
# 3) Build kernel Image
# ---------------------------------------------------------------------------
build_kernel() {
  log "Build kernel Image"
  for f in "${DEFCONFIGS[@]}"; do
    [[ -f "${f}" ]] || die "Missing defconfig fragment: ${f}"
  done

  export ARCH=arm64
  export SUBARCH=arm64
  export LLVM=1
  export LLVM_IAS=1
  export KBUILD_BUILD_USER=github-actions
  export KBUILD_BUILD_HOST=resukisu-ci
  export PATH="${TOOLCHAIN_DIR}/${CLANG_VERSION}/bin:${PATH}"

  local make_args=(
    O="${OUT_DIR}"
    ARCH=arm64
    LLVM=1
    LLVM_IAS=1
    CC=clang
    LD=ld.lld
    AR=llvm-ar
    NM=llvm-nm
    OBJCOPY=llvm-objcopy
    OBJDUMP=llvm-objdump
    READELF=llvm-readelf
    STRIP=llvm-strip
    HOSTCC=clang
    HOSTCXX=clang++
    HOSTLD=ld.lld
  )

  info "Merging defconfigs: ${DEFCONFIGS[*]}"
  rm -rf "${OUT_DIR}"
  mkdir -p "${OUT_DIR}"
  # -m: merge only; run olddefconfig ourselves with LLVM toolchain flags
  ARCH=arm64 scripts/kconfig/merge_config.sh -m -O "${OUT_DIR}" "${DEFCONFIGS[@]}"
  make "${make_args[@]}" olddefconfig

  info "Compiling Image (-j${JOBS})"
  make "${make_args[@]}" -j"${JOBS}" Image

  local image="${OUT_DIR}/arch/arm64/boot/Image"
  [[ -f "${image}" ]] || die "Build failed: ${image} not found"
  info "Image size: $(du -h "${image}" | awk '{print $1}')"
  cp -f "${image}" "${WORK_DIR}/release/Image"
  endlog
}

# ---------------------------------------------------------------------------
# 4) Fetch latest LineageOS boot.img for xpeng
# ---------------------------------------------------------------------------
fetch_boot_img() {
  log "Fetch latest LineageOS boot.img (${DEVICE})"
  local api="https://download.lineageos.org/api/v1/${DEVICE}/nightly/autodownloader"
  local meta
  meta="$(curl_get -fsS "${api}")"

  local filename date boot_url
  filename="$(python3 -c '
import json, sys
data = json.loads(sys.argv[1])["response"]
if not data:
    raise SystemExit("no builds in LineageOS API response")
print(data[0]["filename"])
' "${meta}")"
  # lineage-23.2-YYYYMMDD-nightly-xpeng-signed.zip
  date="$(echo "${filename}" | sed -nE 's/.*-([0-9]{8})-nightly-.*/\1/p')"
  [[ -n "${date}" ]] || die "Failed to parse LOS date from ${filename}"
  boot_url="https://mirrorbits.lineageos.org/full/${DEVICE}/${date}/boot.img"

  info "ROM: ${filename}"
  info "LOS date: ${date}"
  info "boot.img: ${boot_url}"

  curl_get -o "${WORK_DIR}/boot/stock-boot.img" "${boot_url}"
  [[ -s "${WORK_DIR}/boot/stock-boot.img" ]] || die "Downloaded boot.img is empty"

  LOS_DATE="${date}"
  LOS_FILENAME="${filename}"
  export LOS_DATE LOS_FILENAME
  gh_env LOS_DATE "${LOS_DATE}"
  gh_env LOS_FILENAME "${LOS_FILENAME}"
  printf '%s\n' "${LOS_DATE}" > "${WORK_DIR}/los_date.txt"
  printf '%s\n' "${LOS_FILENAME}" > "${WORK_DIR}/los_filename.txt"
  endlog
}

# ---------------------------------------------------------------------------
# 5-7) magiskboot unpack -> replace kernel -> repack
# ---------------------------------------------------------------------------
setup_magiskboot() {
  log "Setup magiskboot"
  local magisk_dir="${TOOLCHAIN_DIR}/magisk"
  mkdir -p "${magisk_dir}"
  if [[ ! -x "${magisk_dir}/magiskboot" ]]; then
    local tag apk
    local magisk_api="https://api.github.com/repos/topjohnwu/Magisk/releases/latest"
    local magisk_base="https://github.com/topjohnwu/Magisk/releases/download"
    if [[ -n "${GITHUB_PROXY:-}" ]]; then
      magisk_api="${GITHUB_PROXY%/}/${magisk_api}"
      magisk_base="${GITHUB_PROXY%/}/${magisk_base}"
    fi
    tag="$(curl_get -fsS "${magisk_api}" | python3 -c 'import sys,json; print(json.load(sys.stdin)["tag_name"])')"
    apk="${magisk_dir}/Magisk-${tag}.apk"
    curl_get -o "${apk}" "${magisk_base}/${tag}/Magisk-${tag}.apk"
    python3 - <<PY
import zipfile
apk="${apk}"
out="${magisk_dir}/magiskboot"
with zipfile.ZipFile(apk) as z:
    # Prefer x86_64 host binary
    for name in ("lib/x86_64/libmagiskboot.so", "lib/x86/libmagiskboot.so"):
        if name in z.namelist():
            with z.open(name) as src, open(out, "wb") as dst:
                dst.write(src.read())
            break
    else:
        raise SystemExit("libmagiskboot.so not found in Magisk apk")
PY
    chmod +x "${magisk_dir}/magiskboot"
  fi
  export MAGISKBOOT="${magisk_dir}/magiskboot"
  endlog
}

repack_boot() {
  log "Repack boot.img with custom kernel"
  local unpack_dir="${WORK_DIR}/boot/unpack"
  rm -rf "${unpack_dir}"
  mkdir -p "${unpack_dir}"
  cp -f "${WORK_DIR}/boot/stock-boot.img" "${unpack_dir}/boot.img"
  pushd "${unpack_dir}" >/dev/null

  "${MAGISKBOOT}" unpack boot.img
  [[ -f kernel ]] || die "magiskboot did not produce 'kernel'"

  # Replace unpacked kernel with our Image (must be named 'kernel')
  cp -f "${WORK_DIR}/release/Image" kernel
  "${MAGISKBOOT}" repack boot.img new-boot.img
  [[ -f new-boot.img ]] || die "magiskboot repack failed"

  RESUKISU_VERSION="${RESUKISU_VERSION:-$(cat "${WORK_DIR}/resukisu_version.txt")}"
  LOS_DATE="${LOS_DATE:-$(cat "${WORK_DIR}/los_date.txt")}"
  local safe_ver
  safe_ver="$(echo "${RESUKISU_VERSION}" | tr '/:' '--')"
  local out_name="boot-${DEVICE}-ReSukiSU-${safe_ver}-LOS-${LOS_DATE}.img"
  cp -f new-boot.img "${WORK_DIR}/release/${out_name}"
  # Also keep a stable name for convenience
  cp -f new-boot.img "${WORK_DIR}/release/boot.img"
  cp -f "${WORK_DIR}/release/Image" "${WORK_DIR}/release/kernel"

  popd >/dev/null

  # Unique tag per CI run so each Release is kept (same LOS/ReSukiSU must not overwrite)
  local build_id
  if [[ -n "${GITHUB_RUN_NUMBER:-}" ]]; then
    build_id="r${GITHUB_RUN_NUMBER}"
  elif [[ -n "${GITHUB_RUN_ID:-}" ]]; then
    build_id="r${GITHUB_RUN_ID}"
  else
    build_id="$(date -u +%Y%m%d%H%M%S)"
  fi
  RELEASE_TAG="ReSukiSU-${safe_ver}-LOS-${LOS_DATE}-${build_id}"
  RESUKISU_DISPLAY="${RESUKISU_DISPLAY:-$(cat "${WORK_DIR}/resukisu_display.txt" 2>/dev/null || echo "${RESUKISU_VERSION}@ReSukiSU")}"
  RELEASE_NAME="xpeng ${RESUKISU_DISPLAY} + LineageOS ${LOS_DATE} (${build_id})"
  BOOT_ARTIFACT="${WORK_DIR}/release/${out_name}"
  export RELEASE_TAG RELEASE_NAME BOOT_ARTIFACT

  gh_env RELEASE_TAG "${RELEASE_TAG}"
  gh_env RELEASE_NAME "${RELEASE_NAME}"
  gh_env BOOT_ARTIFACT "${BOOT_ARTIFACT}"

  info "Output: ${BOOT_ARTIFACT}"
  info "Release tag: ${RELEASE_TAG}"
  endlog
}

pack_anykernel3() {
  log "Pack AnyKernel3 zip"
  local pack_script
  pack_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pack_anykernel3.sh"
  [[ -f "${pack_script}" ]] || die "missing ${pack_script}"
  # shellcheck disable=SC1090
  ROOT_DIR="${ROOT_DIR}" WORK_DIR="${WORK_DIR}" DEVICE="${DEVICE}" \
    RESUKISU_VERSION="${RESUKISU_VERSION:-}" \
    RESUKISU_DISPLAY="${RESUKISU_DISPLAY:-}" \
    LOS_DATE="${LOS_DATE:-}" \
    GITHUB_PROXY="${GITHUB_PROXY:-}" \
    KERNEL_IMAGE="${WORK_DIR}/release/Image" \
    bash "${pack_script}"
  endlog
}

write_release_notes() {
  RESUKISU_VERSION="${RESUKISU_VERSION:-$(cat "${WORK_DIR}/resukisu_version.txt")}"
  RESUKISU_DISPLAY="${RESUKISU_DISPLAY:-$(cat "${WORK_DIR}/resukisu_display.txt" 2>/dev/null || echo "${RESUKISU_VERSION}@ReSukiSU")}"
  LOS_DATE="${LOS_DATE:-$(cat "${WORK_DIR}/los_date.txt")}"
  LOS_FILENAME="${LOS_FILENAME:-$(cat "${WORK_DIR}/los_filename.txt")}"
  AK3_COMMIT="${AK3_COMMIT:-$(cat "${WORK_DIR}/ak3_commit.txt" 2>/dev/null || echo unknown)}"
  cat > "${WORK_DIR}/release/RELEASE_NOTES.md" <<EOF
## xpeng ReSukiSU kernel

| Item | Value |
|------|-------|
| Device | ${DEVICE} |
| ReSukiSU | \`${RESUKISU_DISPLAY}\` |
| LineageOS date | \`${LOS_DATE}\` |
| Base ROM | \`${LOS_FILENAME}\` |
| AnyKernel3 | [osm0sis/AnyKernel3](https://github.com/osm0sis/AnyKernel3) \`${AK3_COMMIT}\` |
| Kernel configs | \`vendor/lahaina-qgki_defconfig\` + \`vendor/lineage_moto-lahaina.config\` + \`vendor/lineage_xpeng.config\` |
| Clang | \`${CLANG_VERSION}\` |

### Assets

- \`boot-*.img\` — LineageOS boot.img with replaced kernel (fastboot)
- \`AnyKernel3-*.zip\` — flashable zip for recovery / Kernel Flasher (any ROM)
- \`Image\` — raw kernel image

### Flash (AnyKernel3, recommended for other ROMs)

Sideload or flash \`AnyKernel3-*.zip\` in a custom recovery, or use a kernel flasher app.

### Flash (LineageOS boot.img)

\`\`\`bash
fastboot flash boot boot-*.img
fastboot reboot
\`\`\`

> Built automatically from \`lineage-23.2-ReSukiSU\` with the latest ReSukiSU submodule, latest AnyKernel3 upstream, and the newest official LineageOS boot.img for xpeng.
EOF
  gh_env RELEASE_NOTES "${WORK_DIR}/release/RELEASE_NOTES.md"
}

main() {
  update_resukisu
  setup_clang
  if [[ "${SKIP_BUILD:-false}" != "true" ]]; then
    build_kernel
  else
    [[ -f "${WORK_DIR}/release/Image" || -f "${OUT_DIR}/arch/arm64/boot/Image" ]] \
      || die "SKIP_BUILD=true but Image not found"
    mkdir -p "${WORK_DIR}/release"
    if [[ ! -f "${WORK_DIR}/release/Image" ]]; then
      cp -f "${OUT_DIR}/arch/arm64/boot/Image" "${WORK_DIR}/release/Image"
    fi
    info "Skipping kernel build; using existing Image"
  fi
  fetch_boot_img
  setup_magiskboot
  repack_boot
  pack_anykernel3
  # Persist AK3 commit for notes if pack script exported it
  if [[ -n "${AK3_COMMIT:-}" ]]; then
    printf '%s\n' "${AK3_COMMIT}" > "${WORK_DIR}/ak3_commit.txt"
  fi
  write_release_notes
  info "Done."
}

main "$@"
