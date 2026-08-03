# android_kernel_motorola_sm7325_build

GitHub Actions for building xpeng LineageOS 23.2 kernel with [ReSukiSU](https://github.com/ReSukiSU/ReSukiSU), then packing:

1. Official LineageOS `boot.img` with replaced kernel
2. [AnyKernel3](https://github.com/osm0sis/AnyKernel3) zip (latest upstream) for flashing on any ROM

## Source

- Kernel: https://github.com/LuoJuly/android_kernel_motorola_sm7325 (`lineage-23.2-ReSukiSU`)
- Device: xpeng (moto g200 5G)
- AnyKernel3: https://github.com/osm0sis/AnyKernel3 (`master`, fetched at build time)

## Schedule

Runs every Sunday 00:00 UTC, and can be triggered manually from the Actions tab.

## Release assets

- `boot-xpeng-ReSukiSU-<version>-LOS-<date>.img` — fastboot flashable boot image
- `AnyKernel3-xpeng-ReSukiSU-<version>-LOS-<date>.zip` — recovery / kernel-flasher zip
- `Image` — raw kernel image
