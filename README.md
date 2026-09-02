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

## Sample projects

Each folder under `samples/` is a self-contained design (own `.qsf`,
`.qpf`, and HDL sources, all in one directory).

```sh
make list                              # show what's available
make build                             # build the first sample (default)
make build SAMPLE=samples/02_uart      # build a specific one
make program SAMPLE=samples/02_uart    # flash it
```

To add a new sample: copy `samples/01_hello_world/` to
`samples/02_your_thing/`, edit the HDL under `src/`, update
`TOP_LEVEL_ENTITY` and the `VERILOG_FILE` lines in the `.qsf`, and it's
picked up automatically by `make list`.

## Everyday workflow (after setup)

```sh
make build         # HDL → <sample>/de0_nano.sof  (~2 min under Rosetta)
make program       # .sof → DE0-Nano SRAM         (~5 sec, volatile)
make program-flash # .sof → EPCS16 config flash   (~30-60 sec, permanent)
make check-usb     # sanity: does openFPGALoader see the board?
make clean         # nuke synthesis artefacts in the active sample
make help          # list all targets, show active sample
```

Or from inside VSCode: **Cmd+Shift+B** runs Build; the palette
(**Cmd+Shift+P → Tasks: Run Task**) lists everything else including
**FPGA: Build & Program**.

## Layout

```
.
├── Makefile                    # entry points, SAMPLE selection
├── instructions/
│   ├── INSTRUCTIONS.md         # ← start here for first-time setup
│   ├── libccl_sqlite3.so       # federunco patched SQLite (required)
│   └── qinst-lite-linux-*.run  # Altera Quartus installer (~126 MB, gitignored)
├── docker/
│   ├── Dockerfile              # base image (Debian + i386 libs)
│   ├── build-image.sh          # two-stage install script
│   └── fake_cpuinfo            # x86 CPU descriptor for the install phase
├── samples/
│   └── 01_hello_world/
│       ├── de0_nano.qsf        # device + pin assignments + source list
│       ├── de0_nano.qpf        # Quartus project file
│       ├── src/                # HDL sources (edit here)
│       │   └── blink.v         # 8-LED counter, XOR'd with DIP switches
│       └── built/              # all Quartus outputs (gitignored)
│           └── de0_nano.sof    # bitstream
├── .vscode/
│   ├── tasks.json              # build / program / clean tasks
│   └── settings.json           # file associations + TerosHDL linter picks
└── .gitignore
```
