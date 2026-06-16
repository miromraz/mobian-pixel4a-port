# Build tools — debos Plasma image → flashable nested-simg

Helpers used to turn a debos-built Plasma rootfs into a flashable sunfish image and
get it onto the device over a flaky USB link. Both have hardcoded paths under
`/home/realni/pixel-a4-linux/mobian/work/` (the live build dir) — adjust if relocated.

## Pipeline (full debos Plasma rebuild)
1. Build the Plasma rootfs tarball via the godebos/debos Docker image, from the build
   tree `mobian/mobian-recipes/` (NOT this git recipe — it lacks the 157M kernel
   `overlay-google-sunfish`). Copy the two `packages-plasma.yaml` from here into that
   tree first. Build pure trixie:
       docker run --rm --device /dev/kvm --workdir /recipes \
         --mount type=bind,source="$PWD",destination=/recipes --security-opt label=disable \
         godebos/debos -t architecture:arm64 -t family:sm7150 -t device:google-sunfish \
         -t partitiontable:mbr -t filesystem:ext4 -t rootfs:rootfs-arm64-plasma-nonfree.tar.gz \
         -t debian_suite:trixie -t suite:trixie -t nonfree:true -t environment:plasma \
         --scratchsize=8G rootfs.yaml
2. `prep-plasma-base.sh` — expand the existing (Phosh) userdata-nested.simg template,
   wipe p2, untar the Plasma rootfs, inject the kernel overlay (modules/fw/dtb),
   `depmod`, repack. Reuses the template's known-good ESP (same kernel version).
3. `bash patch.sh` (the one in ../) — applies all device + Plasma fixes, produces the
   final flashable userdata-nested.simg.

## Flashing (marginal-USB resilient)
`resumable-flash.py` — sunfish fastboot USB drops under sustained transfer, and plain
`fastboot flash` restarts from scratch on every drop so it never finishes. This splits
the raw image into independent small Android-sparse pieces (each writes only its region
via DONT_CARE chunks) and retries only the failed piece. 32MB pieces completed with zero
failures. Usage: `simg2img userdata-nested.simg userdata-raw.img` first, then
`python3 resumable-flash.py [start_piece_index]`. After: `fastboot --set-active=a; fastboot reboot`.
