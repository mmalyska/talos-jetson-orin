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

## A2/A3: r39 package skeleton (2026-10-01)

- **A2:** the fork's `main` was already identical to `schwankner/talos-jetson-orin` `main` (`ecf0921`), so there was nothing to sync. Work is on branch `feat/jetpack7-r39`.
- **A3:** `nvidia-tegra-nvgpu-r39/pkg.yaml` (package name `nvidia-tegra-nvgpu-r39`) is a copy of `nvidia-tegra-nvgpu/pkg.yaml` with:
  - the three sources replaced by the r39.2.1 gitlab tarballs, with sha256/sha512 computed from the downloaded archives (nvgpu 4.1 MB, nv-oot 19.7 MB, hwpm 0.2 MB);
  - the patch loop tolerating empty patch directories (`patches/{nvgpu,nvidia-oot}/` hold only `.gitkeep` for now);
  - the `-I .../drivers/gpu/host1x/include` flag dropped, because r39 has no such directory (`drivers/gpu/host1x-emu/include` and `host1x-fence/include` exist; add them if the build asks for them);
  - everything else unchanged: the conftest step, the `oot()` build helper, the module list and order, signing, the install step.
- **Static checks done:** every module directory the build step references exists in the extracted r39.2.1 trees (`host1x`, `platform/tegra/mc-utils`, `host1x-fence`, `host1x-nvhost`, `hwpm/drivers/tegra/hwpm`, `gpu/drm/tegra`, `video/tegra/nvmap`, `devfreq`, `nvgpu/drivers/gpu/nvgpu`); `scripts/conftest/Makefile` exists; the nvgpu Makefile still has the `CONFIG_TEGRA_GK20A_NVHOST*` switches the build sets. **Not done:** no real build (needs the Talos kernel-build stage, Docker and a few hours), so nothing here is proven to compile.
- **Not wired in yet (task A7):** nothing builds this package. CI (`.github/workflows/build-extensions.yaml`) clones `siderolabs/pkgs` at a pinned commit, copies in `nvidia-tegra-nvgpu/` and builds `--target nvidia-tegra-nvgpu`; `auto-tag.yaml` watches `nvidia-tegra-nvgpu/pkg.yaml`. A second package needs the same injection and its own target/tag. `host1x-emu` (new in r39) is not built; decide in A5 whether Orin needs it.

### Preview of A4: the existing patches against r39.2.1 (dry run, nothing applied)

| Patch | Result | Action |
|---|---|---|
| `nvidia-oot/0001-tegra-drm-headless-no-fbdev.patch` | applies (offset of 4 lines) | keep, copy into `nvidia-tegra-nvgpu-r39/patches/nvidia-oot/` |
| `nvgpu/0002-netlist-flexible-array.patch` | already applied in r39 (patch detected as reversed) | drop |
| `nvgpu/0001-nvhost-syncpt-retry-and-skip-id0.patch` | both hunks fail: `nvhost_host1x.c` changed in r39 | needs a rewrite, and first a decision whether it is still needed |

On the last one: r36's problem was that `host1x_syncpt_alloc()` returned NULL early and handed out syncpoint id 0, which GA10B rejects (`NVGPU_ERRATA_SYNCPT_INVALID_ID_0`). In r39, `nvgpu_nvhost_get_syncpt_client_managed()` already allocates with `HOST1X_SYNCPT_CLIENT_MANAGED | HOST1X_SYNCPT_GPU`, the DTB gained a syncpoint-shim node, and the r39 `host1x` parses it. The failure may be gone; the GA10B errata flag and its checks in `channel_user_syncpt.c` and `channel_sync_syncpt.c` are still present, so a hardware run decides. Plan: port the patch only if the first CUDA smoke test (error 999 on the first `cudaStreamSynchronize()`) shows the same failure.

## A5: CI validation run (set up 2026-10-01)

Workflow `.github/workflows/validate-r39-build.yaml` ("Validate r39 build"): clones `siderolabs/pkgs` at the commit pinned for the current Talos version, injects `nvidia-tegra-nvgpu-r39/`, wires the signing keys from the repository secrets `SIGNING_KEY_PEM`/`SIGNING_KEY_X509` the same way the release build does, builds `--target nvidia-tegra-nvgpu-r39` on the arm64 runner, then verifies the output (all eight expected modules, the `host1x` and `tegra-drm` shadow paths, a signature and the right vermagic on every `.ko`, `modprobe.d/nvidia-tegra.conf`). It writes the first compiler errors to the job summary and uploads the full log and the `.ko` files as the `nvgpu-r39-build` artifact even on failure. It only reads the kernel layers from the shared BuildKit cache and writes its own `nvgpu-r39-validate-k<kernel>` tag.

Triggers: a push to `feat/jetpack7-r39` that touches `nvidia-tegra-nvgpu-r39/**` or the workflow file (a newer push cancels a running build), and `workflow_dispatch` once the file is on the default branch (GitHub does not offer dispatch for workflows that only exist on another branch).

### Run log

1. [Run 36856422399](https://github.com/mmalyska/talos-jetson-orin/actions/runs/36856422399): failed after 1h24m. Setup, key restore and the pkgs clone passed; the release kernel cache tag (`kernel-v1.14.0-k6.18.48`) does not exist in ghcr, so the kernel stage built cold (79 min, stage #54); the tarball checksums, conftest step and patch loop passed. First real compile error: `host1x/dev.c` (`.reserve_vblank_syncpts` not a field of `struct host1x_info`). Cause: the field exists only under `CONFIG_DRM_TEGRA_HAVE_DISPLAY`, which `nvidia-oot/drivers/gpu/Makefile` defines (together with `CONFIG_HOST1X_HAVE_SYNCPT_BASE`) when any Tegra 2x..194 SoC option is enabled; the package builds module directories individually and never reads that Makefile. Talos enables the 132/210/186/194/234 options, so NVIDIA's own build would define both. Fix: both added to `KCFLAGS` in the package. Also added a separate kernel-stage step that exports all layers to `kernel-r39-validate-*`, because BuildKit does not export cache from a failed build.
2. [Run 36865915462](https://github.com/mmalyska/talos-jetson-orin/actions/runs/36865915462): the runner lost contact with GitHub at 1h20m (about 79.7 min in), during the kernel warm-up step, so no module compile happened and no log was recovered. The kernel stage takes about 79 min, so the loss lines up with the end of the kernel build and the start of the `mode=max` cache export; that is a guess, not a finding. Warm-up step removed.
3. [Run 36876340886](https://github.com/mmalyska/talos-jetson-orin/actions/runs/36876340886): first run of the new fast job (`scripts/r39-compile-check.sh`: Talos config + `make modules_prepare` + the package's own prepare/build scripts). It got through setup and the package prepare script and stopped in the build script's conftest step: conftest probes kernel exports and needs the real `Module.symvers` (only a full kernel build makes one), and it compares compiler version strings (distro Clang 21.1.8 vs the Talos LLVM). Fix: `IGNORE_CC_MISMATCH=1` in the script; the full job now exports `Module.symvers` from the kernel-build stage into the Actions cache (key: Talos version, kernel version, pkgs commit) and the fast job restores it.
4. [Run 36876689653](https://github.com/mmalyska/talos-jetson-orin/actions/runs/36876689653): no cached `Module.symvers` yet, so the fast job only printed a notice and the full job compiled the kernel (the runner survived), got `host1x.ko` to compile (the `-D` fix worked) and failed in modpost: `tegra_mipi_driver [host1x.ko] undefined`. `host1x/Makefile` adds `mipi.o` only when the *make variable* `CONFIG_DRM_TEGRA_HAVE_DISPLAY` is set; the first fix had only passed the compiler define. The export and cache steps worked: `Module.symvers` (256 KB) is in the Actions cache under `r39-symvers-<talos>-k<kernel>-pkgs<commit>`.
5. [Run 36892156238](https://github.com/mmalyska/talos-jetson-orin/actions/runs/36892156238): the make variables are now exported in the build script. First run of the fast job with the cached `Module.symvers`: **every module compiled** (about 10 min). Its modpost warnings (35 undefined symbols, warn-only in the fast path) were exactly what the full build would fail on: `tegra_fbdev_driver_fbdev_probe` (headless patch not yet in the r39 package), `tegra_hv_*`/`is_tegra_hypervisor_mode` (needed by nvgpu, tegra-drm, nvmap, mc-utils), `nvmap_init_ivc_queue` and friends (only in `nvmap_sci_ipc.c`), and `nvhost_*` in host1x-fence (provided by host1x-nvhost, which is built after it).
6. [Run 36893583028](https://github.com/mmalyska/talos-jetson-orin/actions/runs/36893583028): headless patch copied, `0002-nvmap-ivc-stubs-without-sciipc.patch` added, `tegra_hv.ko` built from `drivers/virt/tegra` (only that module, `obj-m=tegra_hv.o`), modpost made warn-only for the module builds plus a final unresolved-symbol check (kernel `Module.symvers` plus the modules built here). The check worked and found only `tegra_hv.ko` with eight undefined `tegra_ivc_*` symbols.
7. [Run 36895200467](https://github.com/mmalyska/talos-jetson-orin/actions/runs/36895200467): `ivc_ext.ko` (`drivers/firmware/tegra`, NVIDIA's extended IVC API) added before `tegra_hv`. **Fast job passes: 12 modules build and "all module symbols resolve"** (host1x, host1x-fence, host1x-nvhost, mc-utils, nvhwpm, tegra-drm, nvmap, nvgpu, tegra_hv, ivc_ext, governor_pod_scaling, tegra_wmark). The full BuildKit job passed too: the whole run is green (about 1h40m, from a cold kernel stage).

### Result of the full job (run 36895200467, 2026-10-01)

- All 12 modules are in `rootfs/usr/lib/modules/6.18.48-talos/extra/nvidia-tegra/`, all signed (trailer present), all with vermagic `6.18.48-talos SMP mod_unload modversions aarch64`; the `host1x.ko` and `tegra-drm.ko` copies under `kernel/drivers/gpu/...` that shadow the in-tree modules are byte-identical to the ones in `extra/`; the build's own verify step (modules, shadow paths, signature, vermagic, `modprobe.d/nvidia-tegra.conf` with the softdeps) passed.
- `depends=` as recorded at link time: `tegra_hv` needs `ivc_ext`; `nvgpu` needs `tegra_hv`, `nvmap`, `host1x-fence`, `mc-utils`; `tegra-drm` needs `host1x`, `nvhwpm`, `tegra_hv`; `nvmap` and `mc-utils` need `tegra_hv`; `host1x-fence` and `host1x-nvhost` need `host1x`. `host1x-fence` also uses the `nvhost_*` exports of `host1x-nvhost`; that dependency is only visible to `depmod` (symbol based), not in the `depends=` line, because modpost ran in warn mode for it. Load `host1x-nvhost` before `host1x-fence` explicitly, as the r36 module list does.
- **Size:** the modules are not stripped (the r36 package does not strip either, and the Talos kernel config has `CONFIG_DEBUG_INFO=y` with uncompressed DWARF4): `nvgpu.ko` is 434 MB, `tegra-drm.ko` 12.7 MB, `nvmap.ko` 7.0 MB, `host1x.ko` 5.3 MB, the rest under 3 MB. The kernel reads the whole file into memory when it loads a module, so the nv1 node would briefly need that much for `nvgpu`. `llvm-strip --strip-debug` before signing (what the kernel's `INSTALL_MOD_STRIP=1` does) removes the debug sections without touching what loads; added in commit `1e16e1a` together with the NvSciIpc change so the modules are only rebuilt once, and the CI verify step now fails if `nvgpu.ko` exceeds 50 MB. Symbols stay, so oopses show function names; line-level decoding of a crash needs an unstripped rebuild.

8. [Run 36985440688](https://github.com/mmalyska/talos-jetson-orin/actions/runs/36985440688): `nvsciipc.ko` added, `nvmap` built with `NVMAP_CONFIG_SCIIPC=y` (stub patch removed), `llvm-strip --strip-debug` before signing. Fast job: everything compiled; the unresolved-symbol check flagged `nvsciipc.ko` (`ivc_cdev_get_peer_vmid`, `ivc_cdev_get_noti_type`).
9. [Run 36986752860](https://github.com/mmalyska/talos-jetson-orin/actions/runs/36986752860): `ivc-cdev.ko` (same directory as `tegra_hv`, `obj-m=ivc-cdev.o`) added before `nvsciipc`. Fast job passes with 14 modules (adds `ivc-cdev` and `nvsciipc`) and "all module symbols resolve". The full job (first run with the strip step and the `nvgpu.ko` size guard) was running at the time of writing.

### NvSciIpc userspace (for A8)

`libcuda.so` needs `libnvrm_gpu`, `libnvrm_sync`, `libnvrm_mem`, `libnvrm_host1x`; `libnvrm_mem.so` needs `libnvsciipc.so` and `libnvrm_gpu.so` needs `libnvtegrahv.so`, so those libraries must be present for CUDA to start. `libnvsciipc.so` is in `nvidia-l4t-core` (with the `libnvrm_*` libs), not in `nvidia-l4t-nvsci` (NvSciBuf, NvSciSync, NvSciStream, `/etc/nvsciipc.cfg` and a systemd `nvsciipc_init` that creates users and `chmod 666 /dev/nvsciipc`), which CUDA does not need. Whether `libnvsciipc` fails at CUDA init without `/dev/nvsciipc` is unknown (test on hardware); `/dev/nvsciipc` is not exposed through CDI for now (NvSciIpc on in `nvmap` adds ioctls reachable from pods).

### Differences from the r36 package that the Talos side must follow up

- Two new modules, `ivc_ext.ko` and `tegra_hv.ko` (the real `tegra_hv`, not NVIDIA's dummy: nvgpu, tegra-drm, nvmap and mc-utils need its exports even on bare metal). Loading goes by symbol dependency, and the package's `modprobe.d` softdeps now also name `tegra_hv`. The node's `machine.kernel.modules` list (see `nv1.yaml` in home-ops) will need `ivc_ext` and `tegra_hv` added before `host1x`.
- `tegra_hv.ko` registers a platform driver for `nvidia,tegra-hv` and `is_tegra_hypervisor_mode()` reads `nvidia,tegra-hypervisor-mode` from `/chosen`. On bare metal neither exists, so it should load and do nothing; unverified until the first boot.
- Patches in `nvidia-tegra-nvgpu-r39/patches/`: `nvidia-oot/0001-tegra-drm-headless-no-fbdev` (r36 patch, applies with an offset) and `nvidia-oot/0002-nvmap-ivc-stubs-without-sciipc` (new). Dropped: `nvgpu/0002-netlist-flexible-array` (already upstream in r39). Deferred: `nvgpu/0001-nvhost-syncpt-retry-and-skip-id0`, only if the first CUDA smoke test shows error 999 on `cudaStreamSynchronize()`.
- The fast job builds with the distro Clang 21.1.8, not the Talos LLVM, and with signing and BTF off. It cannot show anything about the real kernel's module-signing key, the final `.ko` paths or vermagic: the full job does.

## A6: ABI, dependencies and load order (2026-10-02, on the run 7 output)

- **host1x / tegra-drm ABI.** Compared the `__versions` CRCs each module imports with the CRCs the providing module exports (`__kcrctab` / `__kcrctab_gpl`), across the 12 built modules: 138 cross-module symbol imports, 0 mismatches. `tegra-drm` uses 61 `host1x` symbols (including `host1x_job_alloc`, the one whose mismatch broke r36 with the vanilla host1x), 2 of `nvhwpm`, 8 of `tegra_hv`. The two shadow copies (`kernel/drivers/gpu/host1x/host1x.ko`, `kernel/drivers/gpu/drm/tegra/tegra-drm.ko`) are byte-identical to the ones in `extra/nvidia-tegra/`. In the Talos 6.18.48 config only `CONFIG_TEGRA_HOST1X=m` and `CONFIG_DRM_TEGRA=m` use host1x (no `VIDEO_TEGRA`, no `TEGRA_VDE`), and both are shadowed, so no module built against the vanilla ABI remains. `host1x-fence` imports the `nvhost_*` symbols from `host1x-nvhost` without a CRC (modpost ran in warn mode for it), so those are matched by name only; both come from the same tree.
- **Against NVIDIA's own r39 Orin build** (prebuilt modules in Seeed's `Linux_for_Tegra` branch `r39.2.0`): the module set is identical (`governor_pod_scaling`, `tegra_wmark`, `ivc_ext`, `tegra-drm`, `host1x`, `host1x-fence`, `host1x-nvhost`, `mc-utils`, `nvmap`, `tegra_hv`, `nvhwpm`, `nvgpu`). Differences in `depends=`:
  - NVIDIA's `nvgpu.ko` imports exactly the same 11 `tegra_hv_*`/`is_tegra_hypervisor_mode` symbols as ours, but its kernel (`drivers/virt/tegra/` and `drivers/firmware/tegra` built in, tree `kernel-noble`) exports them, so NVIDIA's `tegra_hv.ko` and `ivc_ext.ko` are 8 KB empty placeholders. The Talos kernel is mainline-based and lacks those exports, so the real OOT `tegra_hv.ko` and `ivc_ext.ko` (the sources NVIDIA ships for kernels without them) are the right substitute.
  - NVIDIA's `nvmap` depends on `nvsciipc` (built with NvSciIpc). Ours was first built without it (stub patch), then switched to match NVIDIA: `nvsciipc.ko` and `ivc-cdev.ko` are built (NVIDIA's `nvsciipc.ko` depends on `ivc-cdev` too) and `nvmap` uses `NVMAP_CONFIG_SCIIPC=y` (run 36986752860 onwards).
  - NVIDIA's `tegra-drm` depends on `drm_display_helper`, `cec`, `drm_dp_aux_bus`; ours does not, because `DRM_DISPLAY_HELPER` and `CEC_CORE` are built into the Talos kernel.
  - NVIDIA's kernel is `6.8.12-1021-tegra` with `preempt`; Talos is `6.18.48-talos` without it.
- **`tegra_hv` on bare metal.** `tegra_hv_init()` only registers a platform driver, so module load always succeeds. `tegra_hv_probe()` runs only for a DT node `nvidia,tegra-hv` (absent on Orin) and returns `-ENODEV` unless `/chosen` has `nvidia,tegra-hypervisor-mode`. `is_tegra_hypervisor_mode()` therefore returns false, which is what nvgpu, nvmap, tegra-drm and mc-utils use to skip their virtualization paths, and the IVC/mempool entry points return an error because nothing probed. Still to be confirmed on a boot.
- **Load order for the node config** (`machine.kernel.modules`; symbol-dependency correct, which matters if Talos loads strictly in list order; r36's list had `host1x_fence` before `host1x_nvhost`, which no longer works because fence needs nvhost's exports):

  ```yaml
  modules:
    - name: ivc_ext
    - name: tegra_hv
    - name: ivc_cdev
    - name: nvsciipc
    - name: host1x
    - name: host1x_nvhost
    - name: host1x_fence
    - name: nvhwpm
    - name: tegra_drm
    - name: nvmap
    - name: mc_utils
    - name: nvgpu
    - name: governor_pod_scaling
  ```

  `nvhwpm` was resolved as a dependency of `tegra_drm` in r36 (it is not in the current list); it is named here to be safe.
- **modprobe softdeps** in the package (`nvidia-tegra.conf`) now mirror these dependencies (commit `ee33f43`); the previous file missed the host1x-fence to host1x-nvhost ordering and the new modules. Validated by CI run 36981825061 (verify step greps it).

## Next

A7 (wire the r39 package into the release workflows and installer build), A8 (r39 userspace libs and firmware for the CDI setup), then the Phase B/C hardware steps in the home-ops plan.


