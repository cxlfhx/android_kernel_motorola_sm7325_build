#!/usr/bin/env bash
# Pack compiled kernel Image into latest upstream AnyKernel3 zip (osm0sis/AnyKernel3)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# When sourced/called from build_resukisu_boot.sh, ROOT_DIR/WORK_DIR may already be set
ROOT_DIR="${ROOT_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
WORK_DIR="${WORK_DIR:-${ROOT_DIR}/.ci-work}"
DEVICE="${DEVICE:-xpeng}"
AK3_REPO="${AK3_REPO:-https://github.com/osm0sis/AnyKernel3.git}"
AK3_REF="${AK3_REF:-master}"
AK3_DIR="${AK3_DIR:-${WORK_DIR}/AnyKernel3}"

info() { echo "[+] $*"; }
die() { echo "[!] $*" >&2; exit 1; }

gh_env() {
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    printf '%s=%s\n' "$1" "$2" >> "${GITHUB_ENV}"
  fi
}

resolve_image() {
  if [[ -n "${KERNEL_IMAGE:-}" && -f "${KERNEL_IMAGE}" ]]; then
    echo "${KERNEL_IMAGE}"
    return
  fi
  for cand in \
    "${WORK_DIR}/release/Image" \
    "${ROOT_DIR}/out/arch/arm64/boot/Image" \
    "${ROOT_DIR}/arch/arm64/boot/Image"; do
    if [[ -f "${cand}" ]]; then
      echo "${cand}"
      return
    fi
  done
  die "kernel Image not found (set KERNEL_IMAGE or build first)"
}

clone_anykernel3() {
  local url="${AK3_REPO}"
  if [[ -n "${GITHUB_PROXY:-}" ]]; then
    # https://gh-proxy.com/https://github.com/...
    case "${url}" in
      https://github.com/*) url="${GITHUB_PROXY%/}/${url}" ;;
    esac
  fi

  rm -rf "${AK3_DIR}"
  info "Cloning AnyKernel3 (${AK3_REF}) from ${url}"
  git clone --depth=1 --branch "${AK3_REF}" "${url}" "${AK3_DIR}"
  AK3_COMMIT="$(git -C "${AK3_DIR}" rev-parse --short=8 HEAD)"
  AK3_DESCRIBE="$(git -C "${AK3_DIR}" describe --tags --always 2>/dev/null || echo "${AK3_COMMIT}")"
  export AK3_COMMIT AK3_DESCRIBE
  printf '%s\n' "${AK3_COMMIT}" > "${WORK_DIR}/ak3_commit.txt"
  gh_env AK3_COMMIT "${AK3_COMMIT}"
  info "AnyKernel3: ${AK3_DESCRIBE} (${AK3_COMMIT})"
}

write_anykernel_sh() {
  local resukisu_ver="${RESUKISU_DISPLAY:-${RESUKISU_VERSION:-unknown}}"
  local los_date="${LOS_DATE:-unknown}"
  cat > "${AK3_DIR}/anykernel.sh" <<EOF
### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers
## Auto-generated for ${DEVICE} ReSukiSU

### AnyKernel setup
# global properties
properties() { '
kernel.string=xpeng ${resukisu_ver} (LOS ${los_date})
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=${DEVICE}
device.name2=
device.name3=
device.name4=
device.name5=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties


### AnyKernel install
## boot files attributes
boot_attributes() {
set_perm_recursive 0 0 755 644 \$RAMDISK/*;
set_perm_recursive 0 0 750 750 \$RAMDISK/init* \$RAMDISK/sbin;
} # end attributes

# boot shell variables (A/B device, kernel-only replace)
BLOCK=boot;
IS_SLOT_DEVICE=1;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh;

# boot install: replace kernel only (keep ROM ramdisk) for broad ROM compatibility
split_boot;
flash_boot;
## end boot install
EOF
}

pack_zip() {
  local image="$1"
  mkdir -p "${WORK_DIR}/release"

  # Clean example / VCS clutter; keep tools, META-INF, etc.
  rm -rf "${AK3_DIR}/.git" \
         "${AK3_DIR}/modules/"* \
         "${AK3_DIR}/patch/"* \
         "${AK3_DIR}/ramdisk/"* 2>/dev/null || true
  # Keep directory placeholders if present
  mkdir -p "${AK3_DIR}/modules" "${AK3_DIR}/patch" "${AK3_DIR}/ramdisk"

  cp -f "${image}" "${AK3_DIR}/Image"

  RESUKISU_VERSION="${RESUKISU_VERSION:-$(cat "${WORK_DIR}/resukisu_version.txt" 2>/dev/null || echo unknown)}"
  RESUKISU_DISPLAY="${RESUKISU_DISPLAY:-$(cat "${WORK_DIR}/resukisu_display.txt" 2>/dev/null || echo "${RESUKISU_VERSION}@ReSukiSU")}"
  LOS_DATE="${LOS_DATE:-$(cat "${WORK_DIR}/los_date.txt" 2>/dev/null || echo unknown)}"
  local safe_ver
  safe_ver="$(echo "${RESUKISU_VERSION}" | tr '/:' '--')"
  local zip_name="AnyKernel3-${DEVICE}-ReSukiSU-${safe_ver}-LOS-${LOS_DATE}.zip"
  local zip_path="${WORK_DIR}/release/${zip_name}"

  rm -f "${zip_path}"
  (
    cd "${AK3_DIR}"
    zip -r9 "${zip_path}" . \
      -x '*.git*' \
      -x 'README.md' \
      -x 'LICENSE' \
      -x '*.md'
  )
  [[ -f "${zip_path}" ]] || die "failed to create ${zip_path}"

  # Stable alias
  cp -f "${zip_path}" "${WORK_DIR}/release/AnyKernel3.zip"

  AK3_ZIP="${zip_path}"
  export AK3_ZIP
  gh_env AK3_ZIP "${AK3_ZIP}"
  gh_env AK3_COMMIT "${AK3_COMMIT:-}"
  info "AnyKernel3 zip: ${AK3_ZIP} ($(du -h "${AK3_ZIP}" | awk '{print $1}'))"
}

main() {
  command -v zip >/dev/null || die "zip is required (apt install zip)"
  command -v git >/dev/null || die "git is required"

  local image
  image="$(resolve_image)"
  info "Using kernel Image: ${image}"

  # Load version metadata if present from prior build steps
  if [[ -z "${RESUKISU_VERSION:-}" && -f "${WORK_DIR}/resukisu_version.txt" ]]; then
    RESUKISU_VERSION="$(cat "${WORK_DIR}/resukisu_version.txt")"
  fi
  if [[ -z "${RESUKISU_DISPLAY:-}" && -f "${WORK_DIR}/resukisu_display.txt" ]]; then
    RESUKISU_DISPLAY="$(cat "${WORK_DIR}/resukisu_display.txt")"
  fi
  if [[ -z "${LOS_DATE:-}" && -f "${WORK_DIR}/los_date.txt" ]]; then
    LOS_DATE="$(cat "${WORK_DIR}/los_date.txt")"
  fi
  export RESUKISU_VERSION RESUKISU_DISPLAY LOS_DATE

  clone_anykernel3
  write_anykernel_sh
  pack_zip "${image}"
  info "AnyKernel3 pack done."
}

# Allow sourcing for function reuse, or direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
