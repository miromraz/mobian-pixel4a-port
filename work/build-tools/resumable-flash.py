#!/usr/bin/env python3
# Resumable userdata flash for a marginal USB link. Splits the raw image into
# independent ~256MB pieces; each piece is a full-partition-size Android sparse
# file that writes ONLY its own region (everything else = DONT_CARE/skip). Each
# piece is flashed in its own fastboot session and retried individually, so a USB
# drop only costs the current piece, not the whole image.
import struct, os, sys, subprocess, time

RAW = "/home/realni/pixel-a4-linux/mobian/work/userdata-raw.img"
PIECE = "/home/realni/pixel-a4-linux/mobian/work/.piece.simg"
BLK = 4096
PIECE_BYTES = 32 * 1024 * 1024
SPARSE_MAGIC = 0xed26ff3a
CHUNK_RAW = 0xCAC1
CHUNK_DONT_CARE = 0xCAC3

total_bytes = os.path.getsize(RAW)
assert total_bytes % BLK == 0
total_blks = total_bytes // BLK
piece_blks = PIECE_BYTES // BLK

def is_zero(buf):
    return not any(buf)

def make_piece(start_blk, nblks):
    pre = start_blk
    post = total_blks - (start_blk + nblks)
    nchunks = (1 if pre else 0) + 1 + (1 if post else 0)
    with open(PIECE, "wb") as o, open(RAW, "rb") as f:
        o.write(struct.pack("<IHHHHIIII", SPARSE_MAGIC, 1, 0, 28, 12, BLK,
                             total_blks, nchunks, 0))
        if pre:
            o.write(struct.pack("<HHII", CHUNK_DONT_CARE, 0, pre, 12))
        o.write(struct.pack("<HHII", CHUNK_RAW, 0, nblks, 12 + nblks * BLK))
        f.seek(start_blk * BLK)
        rem = nblks * BLK
        while rem:
            b = f.read(min(1 << 20, rem)); o.write(b); rem -= len(b)
        if post:
            o.write(struct.pack("<HHII", CHUNK_DONT_CARE, 0, post, 12))

def wait_fastboot(timeout=120):
    t = time.time()
    while time.time() - t < timeout:
        r = subprocess.run(["fastboot", "devices"], capture_output=True, text=True)
        if "fastboot" in r.stdout:
            return True
        time.sleep(2)
    return False

def flash_piece(idx, start_blk, nblks, tries=30):
    for attempt in range(1, tries + 1):
        if not wait_fastboot():
            print(f"piece {idx}: no fastboot device", flush=True); return False
        r = subprocess.run(["fastboot", "flash", "userdata", PIECE],
                           capture_output=True, text=True)
        if r.returncode == 0 and "OKAY" in (r.stdout + r.stderr):
            return True
        print(f"piece {idx} attempt {attempt} failed: "
              f"{(r.stderr.strip().splitlines() or ['?'])[-1]}", flush=True)
        time.sleep(3)
    return False

# Build piece list (skip all-zero pieces -> they are unused ext4 free space / GPT pad)
pieces = []
with open(RAW, "rb") as f:
    blk = 0
    while blk < total_blks:
        n = min(piece_blks, total_blks - blk)
        f.seek(blk * BLK)
        data = f.read(n * BLK)
        pieces.append((blk, n, is_zero(data)))
        blk += n

nonzero = [p for p in pieces if not p[2]]
print(f"total {len(pieces)} pieces, {len(nonzero)} non-zero to flash "
      f"({total_bytes/1e9:.2f}GB image)", flush=True)

start_at = int(sys.argv[1]) if len(sys.argv) > 1 else 0
ok = 0
for idx, (blk, n, zero) in enumerate(pieces):
    if zero or idx < start_at:
        continue
    make_piece(blk, n)
    print(f"[{idx}/{len(pieces)}] flashing blocks {blk}..{blk+n} "
          f"({n*BLK/1e6:.0f}MB)", flush=True)
    if not flash_piece(idx, blk, n):
        print(f"FATAL: piece {idx} exhausted retries. Resume later with: "
              f"resumable-flash.py {idx}", flush=True)
        os.path.exists(PIECE) and os.remove(PIECE)
        sys.exit(1)
    ok += 1
os.path.exists(PIECE) and os.remove(PIECE)
print(f"ALL_PIECES_FLASHED ({ok} written)", flush=True)
