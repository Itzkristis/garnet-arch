# Make GL apps use the Adreno 710 (turnip/zink) by default in login shells and
# any Xorg session started from one. Does NOT reach sway (launched as a
# non-login session) — and Wayland apps cannot use turnip here anyway (no
# DRM/GBM), so this cleanly targets the accelerated path: Xorg + GL apps.
# Override for a one-off software run with: LIBGL_ALWAYS_SOFTWARE=1 <app>
export LD_LIBRARY_PATH=/usr/local/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
export VK_DRIVER_FILES=/usr/local/share/vulkan/icd.d/freedreno_icd.aarch64.json
export LIBGL_DRIVERS_PATH=/usr/local/lib/dri
export MESA_LOADER_DRIVER_OVERRIDE=zink
export LIBGL_KOPPER_DRI2=1
export MESA_VK_WSI_DEBUG=sw   # fbdev X has no DRI3 -> WSI CPU-copy present
export __GLX_VENDOR_LIBRARY_NAME=mesa
