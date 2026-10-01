# JetPack 7 (r39) port — status

Goal: run the GA10B (Orin) GPU on JetPack 7.2 (Jetson Linux r39.2, CUDA 13) under Talos. The r36.5 build stays unchanged until r39 is proven on hardware.

Tracking plan (home-ops repo): `docs/superpowers/plans/2026-10-01-talos-jetson-r39-port.md`.

## A1: target release and source pins (decided 2026-10-01)

### Decision

| Layer | Release | Why |
|---|---|---|
| Flashed firmware, UEFI and DTB | r39.2.0 (Seeed's `Linux_for_Tegra` branch `r39.2.0`, "built on JetPack 7.2 (L4T R39.2.0)") | Seeed's board DTS and flash configs exist for r39.2.0 only. |
| `nvidia-oot`, `nvgpu`, `hwpm` module sources | r39.2.1 (`jetson_39.2.1`) | Same GPU/host1x device-tree contract as r39.2.0 (see below). r39.2.1 carries three nvmap fixes (below) that the r36.5 stack never had; we expose `/dev/nvmap` to unprivileged pods through CDI. |
| Userspace libs and firmware debs | r39.2.1 BSP | Taken from the same release as the modules. nvgpu source is identical in 39.2.0 and 39.2.1, so the kernel/user ABI is the same. |

Mixing r39.2.1 modules with r39.2.0 firmware is deliberate and low-risk, but unverified on hardware. If bring-up shows a mismatch, fall back to the r39.2.0 pins in the second table.

### Pins (verified 2026-10-01 against NVIDIA's gitlab; commit = what the tag points at)

Use the commit SHA, not the tag object SHA, in tarball URLs.

| Repo (gitlab.com/nvidia/nv-tegra/...) | `jetson_39.2.1` commit | `jetson_39.2.0` commit |
|---|---|---|
| `linux-nv-oot` | `e71bacb7c611f880c5f341263967f13de54de3a9` | `2385c9c5cb99c44636cb5b738bfad5572b38386b` |
| `linux-hwpm` | `80b966b1bdc20f896cc9625a84708cbbe4638e38` | `80b966b1bdc20f896cc9625a84708cbbe4638e38` |
| `tegra/kernel-src/linux-nvgpu` | `fc23d33512d3bf1361b201e31406c47762102429` | `74a58d0f4dc6f0a1e6137cb0be9b95599cdb1fd6` |
| `device/hardware/nvidia/t23x-public-dts` (reference only) | `0e155aa7767cba2595faf05a8ab14c4cee5a7a27` | `3897df11a86397704db8685071de46559cfb3c6e` |

Archive URLs resolve (HTTP 200), pattern `https://gitlab.com/nvidia/nv-tegra/<repo>/-/archive/<sha>/<name>-<sha>.tar.gz`. sha256/sha512 still to be computed when the package is written (task A3).

### What changed between r39.2.0 and r39.2.1

- `linux-nvgpu`: no source change (two metadata-only commits).
- `linux-hwpm`: same commit.
- `linux-nv-oot` (one commit, 3 source files):
  - `drivers/video/tegra/nvmap/nvmap_handle.c`: fixes an off-by-one (`offs > tot_sz` to `>=`) and a copy that could run past the end of a source handle and the destination `pages[]` array.
  - `drivers/video/tegra/nvmap/nvmap_ioctl.c`: `nvmap_ioctl_get_fd_from_list` now rejects a non-page-aligned offset (kernel-heap out-of-bounds write otherwise).
  - `drivers/gpu/power/tegra/nv-gpu-static-pg.c`: T264 (Thor) only, irrelevant for Orin.
- `t23x-public-dts`: `tegra234-p3701-0000.dtsi`, `tegra234-p3767-0000.dtsi` and the soc thermal-slowdown dtsi files change. No GPU, host1x or memory-controller node changes.

### Facts found while resolving A1 (needed by later tasks)

- **Userspace packaging differs from r36.** r39 has no `t234` apt component; NVIDIA's apt repo for r39.2 (`https://repo.download.nvidia.com/jetson/common/dists/r39.2`, component `main`) has only a few L4T packages. The GPU userspace debs ship in the BSP tarball (`https://developer.nvidia.com/downloads/embedded/l4t/r39_release_v2.1/release/Jetson_Linux_r39.2.1_aarch64.tbz2`, under `Linux_for_Tegra/nv_tegra/l4t_deb_packages/`; r39.2.0 equivalent: `r39_release_v2.0/.../Jetson_Linux_r39.2.0_aarch64.tbz2`). Both URLs return HTTP 200.
- **Driver split.** Orin uses the `-nvgpu` package variants (`nvidia-l4t-cuda-nvgpu`, `-init-nvgpu`, `-firmware-nvgpu`, `-kernel-nvgpu`, `-bsp-nvgpu`); the `-openrm` variants are Thor. Do not use OpenRM for Orin.
- **Where the libs are.** `nvidia-l4t-cuda-nvgpu` installs `libcuda.so.1.1` (22 MB) and `libcuda_instrumentation.so` under `/opt/nvidia/l4t-gpu-libs/nvgpu/`, not `/usr/lib/aarch64-linux-gnu/nvidia/`. `nvidia-l4t-cuda` (212 KB) and `nvidia-l4t-core` (4 MB) provide the other `libnv*` libraries and depend on the nvgpu variant. The CDI spec and `LD_LIBRARY_PATH` in `manifests/gpu/cdi-setup.yaml` must be updated for this layout (task A8).
- **GA10B firmware.** In `nvidia-l4t-firmware` at `/lib/firmware/nvidia/ga10b/` (`NETA..NETD_img_prod_encrypted.bin` and others), not in `nvidia-l4t-firmware-nvgpu` (documentation only, 24 KB). Re-check the full list against the r36 firmware extension step in `.github/workflows/build-extensions.yaml`.
- **Device tree.** Between r36.5 and r39.2.0 the GPU, memory-controller and HWPM nodes of the standard Seeed J401 / Orin NX 16 GB DTB are unchanged; `host1x@13e00000` loses the `actmon` region/clock and gains `nvidia,syncpoint-shim` (new `nvidia,tegra234-syncpoint-shim` node at `memory@60000000`). r39 `drivers/gpu/host1x/dev.c` parses that phandle.
- **Module tree layout.** r39 `nvidia-oot` has `drivers/gpu/{drm,host1x,host1x-emu,host1x-fence,host1x-nvhost,power}`, `drivers/video/tegra/{camera,dc,host,nvmap,tsec,virt}`; `host1x-emu` is new relative to what the r36 package builds.

## Next (task A2/A3)

Add an r39 package next to `nvidia-tegra-nvgpu/` using the r39.2.1 pins above, mirroring its conftest/`oot()` build steps, and rebase the three existing patches.
