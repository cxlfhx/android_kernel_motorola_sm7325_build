# android_kernel_motorola_sm7325_build

GitHub Actions for building xpeng LineageOS 23.2 kernel with [ReSukiSU](https://github.com/ReSukiSU/ReSukiSU), then packing it into the latest official `boot.img`.

## Source

- Kernel: https://github.com/LuoJuly/android_kernel_motorola_sm7325 (`lineage-23.2-ReSukiSU`)
- Device: xpeng (moto g200 5G)

## Schedule

Runs every Sunday 00:00 UTC, and can be triggered manually from the Actions tab.

## Output

Release assets:

- `boot-xpeng-ReSukiSU-<version>-LOS-<date>.img`
- `Image`
