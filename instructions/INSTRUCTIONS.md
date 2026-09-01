# DE0-Nano on macOS — end-to-end setup instructions

Compile Verilog/VHDL on an Apple Silicon Mac and flash it to a Terasic
DE0-Nano board (Altera Cyclone IV E, `EP4CE22F17C6`). Uses VSCode +
TerosHDL for editing, a Docker container running Quartus Prime Lite
24.1std for synthesis, and native `openFPGALoader` for programming over
the board's onboard USB.

## Files in this folder

| File | What it is | Where it came from |
|------|------------|---------------------|
| `INSTRUCTIONS.md` | This guide | — |
| `libccl_sqlite3.so` | Patched Altera SQLite fork with the x87 long-double CPU check removed. Required — without it, Quartus crashes with *Illegal Instruction* under Rosetta. | [github.com/federunco/federunco](https://github.com/federunco/federunco/raw/refs/heads/main/libccl_sqlite3.so) — 1 MB, tracked in git |
| `qinst-lite-linux-24.1std-1077.run` | Altera's qinst bootstrap installer for Quartus Prime Lite 24.1std. Downloads the actual Quartus payload from Altera's CDN during the Docker build. | [altera.com Quartus Prime Lite downloads](https://www.altera.com/downloads/fpga-development-tools/quartus-prime-lite-edition-design-software.html) — 126 MB, **not** committed to git (Altera-licensed) |

If you got this repo without the `.run`, download it yourself from the
link above (free Altera account required) and drop it here. The `.so` is
tracked in git and should already be present.

## Prerequisites (macOS host)

You need three things installed on the Mac:

```sh
brew install --cask docker            # Docker Desktop
brew install openFPGALoader           # native x86 or arm64 programmer, no drivers needed
```

Start Docker Desktop. Give the Docker VM at least **60 GB of disk** and
**4 GB of RAM** in Settings → Resources — the Quartus install alone is
~16 GB and peaks around ~20 GB during install.

## The two-emulator dance

Docker Desktop can emulate x86_64 on Apple Silicon via **Rosetta** or
**QEMU**. Neither one on its own gets us all the way through:

- **Rosetta** can run Quartus at ~2 min/compile (fast!) but doesn't
  emulate x87 80-bit extended precision, which Quartus's stock SQLite
  fork uses on startup → *Illegal Instruction* crash.
- **QEMU** emulates x87 correctly but has a memory-layout quirk that
  makes Altera's PDB deserializer crash with a sign-extended 32-bit
  pointer segfault whenever it tries to open a project.

The workaround is:

1. Use **QEMU** for the one-time Quartus install (Rosetta would crash
   the qinst installer before it even starts).
2. Apply the patched `libccl_sqlite3.so` on top of the install.
3. Switch to **Rosetta** for actual synthesis (patched SQLite + Rosetta
   works, and it's much faster than QEMU).

So you'll toggle the Docker Desktop emulator setting exactly once during
setup, then leave it on Rosetta forever after.

## Step-by-step setup

### 1. Copy the vendor files into place

The build script reads from `../instructions/` (relative to `docker/`)
so no copying is needed — both files should already be here:

```
instructions/
├── libccl_sqlite3.so
├── qinst-lite-linux-24.1std-1077.run
└── INSTRUCTIONS.md
```

### 2. Disable Rosetta in Docker Desktop (temporary, for install only)

- **Docker Desktop → Settings → General**
- **Uncheck** "Use Rosetta for x86_64/amd64 emulation on Apple Silicon"
- Click **Apply & restart**
- Wait for Docker to come back up

### 3. Build the Docker image

From the repo root:

```sh
make docker-image
```

This will:

- Build a small Debian base image (~1 min)
- Start a container with a fake `/proc/cpuinfo` shim (needed under QEMU
  so Altera's Intel-CPU check passes)
- Run the qinst installer, which downloads ~2.55 GB of Quartus + Cyclone
  IV device support from Altera and installs it into
  `/opt/intelFPGA_lite` inside the container
- Apply the patched `libccl_sqlite3.so`
- Patch `qenv.sh` to add aarch64 detection
- Commit the container as `de0nano-quartus:latest` (~13 GB final image)

**Expected duration: ~40-50 min end-to-end** (mostly the Altera CDN
download + install under QEMU emulation). It's OK to leave it and come
back later — the script is unattended.

If it fails, check `docker/vendor/README.md`... wait, that's gone. Check
back with the maintainer (or read the top of `docker/build-image.sh`).

### 4. Re-enable Rosetta in Docker Desktop

- **Docker Desktop → Settings → General**
- **Check** "Use Rosetta for x86_64/amd64 emulation on Apple Silicon"
- Click **Apply & restart**

### 5. Verify Quartus runs

```sh
docker run --rm --platform=linux/amd64 de0nano-quartus:latest quartus_sh --version
```

Should print:

```
Quartus Prime Shell
Version 24.1std.0 Build 1077 04/23/2025 SC Lite Edition
Copyright (C) 2025  Altera Corporation. All rights reserved.
```

### 6. Test the compile flow

```sh
make build
```

Expected: ~2 minutes, ending with `Quartus Prime Full Compilation was
successful. 0 errors, N warnings`, and `project/de0_nano.sof` appears.

That `.sof` is the bitstream — ready to program to the board.

### 7. Plug in the DE0-Nano

Connect the mini-USB port on the DE0-Nano (labelled J1, next to the USB
Blaster jumpers) to your Mac. Confirm the Mac sees it:

```sh
make check-usb
```

You should get a device listing from openFPGALoader. If not, see the
troubleshooting section below.

### 8. Flash the board

```sh
make program
```

The 8 on-board LEDs should start doing a ~1.5 Hz sweep pattern (XOR'd
with the DIP switches — flip them to see the pattern change without
recompiling).

Note: this programs the FPGA's SRAM, not its config flash — so the
design is lost on power cycle. To burn it to the EPCS16 flash instead
(non-volatile), use `openFPGALoader --write-flash -b de0nano
project/de0_nano.sof`.

## Everyday workflow (after setup)

From then on, whenever you want to iterate on HDL:

```sh
make build         # HDL → .sof (~2 min under Rosetta)
make program       # .sof → DE0-Nano (~5 sec)
```

Or from VSCode: **Cmd+Shift+B** runs the default build task; the
command palette lists all tasks (Build, Program, Build & Program,
Detect USB, Clean, Docker image, Quartus shell).

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `make docker-image` fails with *Illegal Instruction* during the qinst install phase | You're on Rosetta. Disable it in Docker Desktop → General. |
| `make docker-image` succeeds but `make build` fails with *Segment Violation* in `PDB_SEGMENT_READER` | You're on QEMU. Re-enable Rosetta. |
| `make build` fails with *"required extensions were not found on: ''"* | You have `-v .../fake_cpuinfo:/proc/cpuinfo:ro` in the Makefile *and* Rosetta is on. The runtime Makefile shouldn't have the mount; only `build-image.sh` uses it. |
| `openFPGALoader: unable to open device` | Board not plugged in, or another process is holding the FTDI handle (kill any Quartus Programmer). |
| `openFPGALoader --detect` finds no board | Try `-b usb-blaster` instead of `-b de0nano` if you're using an external USB Blaster dongle rather than the DE0-Nano's onboard mini-USB. |
| Docker build fails mid-download | Just re-run `make docker-image`. The base image + partial installer state are cached; the qinst installer resumes downloads. |
| Compile succeeds but LEDs don't light | `KEY[0]` on the board is an active-low async reset. Don't wire it to GND. |

## Why 24.1std specifically

- **25.1** (current Lite release) has a hard incompatibility with QEMU:
  its PDB deserializer crashes on `project_open`. No workaround at the
  container level.
- **22.1** works past install but has the same PDB crash under QEMU;
  under Rosetta it hits the SQLite Illegal Instruction, and the
  federunco patched `.so` wasn't built for 22.1 (ABI may not match).
- **24.1std** is the version the federunco Apple-Silicon guide targets
  successfully, and the patched `libccl_sqlite3.so` in this folder was
  built against it.

Reference: <https://gist.github.com/federunco/f2bde2e25342c6284b68ce4ecf305e5d>

## What was in this rabbit hole

- Rosetta 2 does not emulate x87 80-bit extended precision. Altera's
  `libccl_sqlite3.so` uses it via a `hasHighPrecisionDouble` FPU probe.
- QEMU emulates x87 but its virtual address layout can put data at
  addresses where `int32_t` sign-extends to a bogus `void*`, tripping
  Altera's PDB serialization code that assumes 32→64 bit is safe.
- Neither emulator alone gets Quartus 25.1 running; 24.1 + federunco
  patch + Rosetta does.
- `/proc/cpuinfo` under QEMU is passed through from the ARM host, so
  Altera's Intel-CPU check has to be tricked with a bind-mounted fake
  during install. Under Rosetta, `/proc/cpuinfo` shows the emulated
  `VirtualApple` CPU with plenty of SSE/AVX flags, so no shim is
  needed at runtime.
