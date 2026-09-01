# DE0-Nano on macOS — TerosHDL to real hardware

Compile Verilog/VHDL on an Apple Silicon Mac and flash it to a Terasic
DE0-Nano (Cyclone IV E, `EP4CE22F17C6`). Uses VSCode + TerosHDL for
editing, a Docker container running Quartus Prime Lite 24.1std for
synthesis, and native `openFPGALoader` for programming.

## Setup

See **[instructions/INSTRUCTIONS.md](instructions/INSTRUCTIONS.md)** for
the full step-by-step guide, including which Docker Desktop settings to
flip, why we use Quartus 24.1 and not 25.1, and the emulator-swap dance
required to get Altera's binaries running under Apple Silicon.

## Everyday workflow (after setup)

```sh
make build         # HDL → project/de0_nano.sof  (~2 min under Rosetta)
make program       # .sof → DE0-Nano             (~5 sec, over USB)
make check-usb     # sanity: does openFPGALoader see the board?
make clean         # nuke synthesis artefacts
make help          # list all targets
```

Or from inside VSCode: **Cmd+Shift+B** runs Build; the palette
(**Cmd+Shift+P → Tasks: Run Task**) lists everything else including
**FPGA: Build & Program**.

## Layout

```
.
├── Makefile                    # entry points
├── instructions/
│   ├── INSTRUCTIONS.md         # ← start here for first-time setup
│   ├── libccl_sqlite3.so       # federunco patched SQLite (required)
│   └── qinst-lite-linux-*.run  # Altera Quartus installer (~126 MB, not in git)
├── docker/
│   ├── Dockerfile              # base image (Debian + i386 libs)
│   ├── build-image.sh          # two-stage install script (Docker doesn't do bind-mounts in build)
│   └── fake_cpuinfo            # x86 CPU descriptor for the install phase
├── project/
│   ├── de0_nano.qpf            # Quartus project
│   ├── de0_nano.qsf            # device + pin assignments
│   └── de0_nano.sof            # built bitstream (gitignored)
├── src/
│   └── blink.v                 # example: 8-LED counter
├── .vscode/
│   ├── tasks.json              # build / program / clean tasks
│   └── settings.json           # file associations + TerosHDL linter picks
└── .gitignore
```
