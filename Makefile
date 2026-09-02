# DE0-Nano FPGA build & program pipeline for macOS
#
# Split of responsibilities:
#   - Synthesis + place & route: Quartus Prime Lite inside a Linux/amd64
#     Docker container (Rosetta on Apple Silicon). See docker/Dockerfile.
#   - Programming: openFPGALoader running natively on macOS, talking to
#     the DE0-Nano's onboard FT245 (USB Blaster) over USB.
#
# Sample selection: each directory under samples/ is a self-contained
# design (own .qsf, .qpf, and HDL sources, all in the same directory).
# Pick one by setting SAMPLE=samples/<name>, e.g.:
#
#     make build SAMPLE=samples/02_uart
#     make program SAMPLE=samples/02_uart
#
# Without SAMPLE, defaults to the first entry alphabetically. Use
# `make list` to see what's available.

PROJECT         := de0_nano

# ─────────────────────────────────────────────────────────────────
#  Edit this line to change which sample Cmd+Shift+B (and bare
#  `make build`) targets. Override on the command line for one-offs:
#      make build SAMPLE=samples/02_uart
# ─────────────────────────────────────────────────────────────────
ACTIVE_SAMPLE   := samples/01_hello_world

SAMPLE          ?= $(ACTIVE_SAMPLE)
SRC_DIR         := $(SAMPLE)/src
BUILT_DIR       := $(SAMPLE)/built
SOF             := $(BUILT_DIR)/$(PROJECT).sof
SVF             := $(BUILT_DIR)/$(PROJECT).svf
JIC             := $(BUILT_DIR)/$(PROJECT).jic
RPD             := $(BUILT_DIR)/$(PROJECT)_auto.rpd

DOCKER_IMAGE    := de0nano-quartus:latest
DOCKER_PLATFORM := linux/amd64

# VSCode tasks (Cmd+Shift+B) don't source ~/.zshrc, so `docker context`
# defaults to the missing "default" socket at /var/run/docker.sock instead
# of Docker Desktop's real socket. Pin it explicitly. Override in your
# environment if you're using a different docker install (colima, orbstack).
export DOCKER_HOST ?= unix://$(HOME)/.docker/run/docker.sock

SOURCES := $(wildcard $(SRC_DIR)/*.v $(SRC_DIR)/*.sv $(SRC_DIR)/*.vhd)

# On Apple Silicon Quartus runs under Rosetta (with a federunco-patched
# libccl_sqlite3.so applied at image-build time to work around Rosetta's
# missing x87 long-double support). Rosetta's own /proc/cpuinfo already
# advertises SSE/AVX correctly, so no cpuinfo shim is needed here — in fact
# bind-mounting one over Rosetta's /proc/cpuinfo breaks things.
DOCKER_RUN = docker run --rm \
    --platform=$(DOCKER_PLATFORM) \
    --user $(shell id -u):$(shell id -g) \
    -e HOME=/tmp \
    -v $(CURDIR):/work \
    -w /work \
    $(DOCKER_IMAGE)

.PHONY: help list build program program-flash clean docker-image shell check-usb rebuild

help:
	@echo "DE0-Nano bridge targets  (active sample: $(SAMPLE))"
	@echo ""
	@echo "  make docker-image                Build Quartus Docker image (one-time, ~30 min)"
	@echo "  make list                        List available samples under samples/"
	@echo "  make build [SAMPLE=samples/<x>]  Synthesize -> <sample>/$(PROJECT).sof"
	@echo "  make program                     Flash to FPGA SRAM (volatile, ~5 sec)"
	@echo "  make program-flash               Burn to EPCS16 config flash (non-volatile)"
	@echo "  make rebuild                     clean + build"
	@echo "  make check-usb                   Verify openFPGALoader sees the DE0-Nano"
	@echo "  make shell                       Interactive shell inside the Quartus container"
	@echo "  make clean                       Remove synthesis artifacts from active sample"
	@echo ""
	@echo "Sample selection: set SAMPLE=samples/<name> to pick a design."
	@echo "Example:  make build program SAMPLE=samples/02_uart"

list:
	@echo "Available samples:"
	@for d in samples/*/; do \
	    top=$$(grep -E '^set_global_assignment -name TOP_LEVEL_ENTITY' $$d*.qsf 2>/dev/null | head -n1 | awk '{print $$NF}'); \
	    printf "  %-30s  top=%s\n" "$${d%/}" "$${top:-?}"; \
	done

docker-image:
	bash docker/build-image.sh $(DOCKER_IMAGE)

build: $(SOF)

$(SOF): $(SOURCES) $(SAMPLE)/$(PROJECT).qsf $(SAMPLE)/$(PROJECT).qpf
	@if ! docker image inspect $(DOCKER_IMAGE) >/dev/null 2>&1; then \
	    if ! command -v docker >/dev/null 2>&1; then \
	        echo "docker CLI not in PATH (PATH=$$PATH)"; \
	    elif ! docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then \
	        echo "docker daemon not reachable (DOCKER_HOST=$$DOCKER_HOST)"; \
	        echo "Is Docker Desktop running?"; \
	    else \
	        echo "Docker image '$(DOCKER_IMAGE)' not found. Run: make docker-image"; \
	    fi; \
	    exit 1; \
	fi
	@echo "==> Building $(SAMPLE)"
	# Quartus scatters ~20 different artefacts across the project root and
	# an output_files/ subdir. Compile from sample root, then sweep them all
	# into built/ so src/ + the two .qsf/.qpf files are all that stay clean.
	# We capture quartus's exit code so the sweep still runs on failure
	# (so we can inspect the reports), and then propagate the code so make
	# fails when the compile fails.
	$(DOCKER_RUN) bash -c 'cd $(SAMPLE); \
	    quartus_sh --flow compile $(PROJECT); rc=$$?; \
	    mkdir -p built; \
	    for f in db incremental_db output_files \
	             *.rpt *.summary *.smsg *.done *.pin *.jdi *.qws \
	             *.sopcinfo *.sof *.sld *.pof *.jic *.rpd *.map *.svf \
	             *_assignment_defaults.qdf; do \
	        if [ -e "$$f" ]; then mv "$$f" built/; fi; \
	    done; \
	    exit $$rc'
	@# If the .sof ended up in built/output_files/ (Quartus 24.1 sometimes
	@# does), lift it out so downstream targets find it at the expected path.
	@if [ -f $(BUILT_DIR)/output_files/$(PROJECT).sof ] && [ ! -f $(SOF) ]; then \
	    mv $(BUILT_DIR)/output_files/$(PROJECT).sof $(SOF); \
	fi
	@echo ""
	@echo "Built: $(SOF)"

# openFPGALoader (<=v1.1.x) doesn't auto-detect Altera .sof, so we convert
# to .svf (JTAG serial-vector format) inside the container and program that.
# -q 12MHz : JTAG TCK frequency (well within USB Blaster's 24 MHz max)
# -g 3.3   : bank voltage
# -n p     : programming operation
$(SVF): $(SOF)
	$(DOCKER_RUN) bash -c "cd $(BUILT_DIR) && quartus_cpf -c -q 12MHz -g 3.3 -n p $(PROJECT).sof $(PROJECT).svf"

program: $(SVF)
	@command -v openFPGALoader >/dev/null 2>&1 || { \
	    echo "openFPGALoader not installed. Run: brew install openFPGALoader"; exit 1; }
	openFPGALoader -b de0nano $(SVF)

# EPCS16 = 128 Mbit on-board config flash, active-serial x1 interface.
# quartus_cpf converts the .sof to a .jic (JTAG Indirect Config) via the
# SFL (Serial Flash Loader) on the FPGA. -d = flash chip, -s = SFL host
# FPGA. auto_create_rpd=on also emits <name>_auto.rpd — the raw byte
# stream that openFPGALoader can push directly to the flash chip.
$(RPD): $(SOF)
	$(DOCKER_RUN) bash -c "cd $(BUILT_DIR) && quartus_cpf -c -d EPCS16 -s EP4CE22 -o auto_create_rpd=on $(PROJECT).sof $(PROJECT).jic"

program-flash: $(RPD)
	@command -v openFPGALoader >/dev/null 2>&1 || { \
	    echo "openFPGALoader not installed. Run: brew install openFPGALoader"; exit 1; }
	openFPGALoader --write-flash -b de0nano $(RPD)

check-usb:
	@command -v openFPGALoader >/dev/null 2>&1 || { \
	    echo "openFPGALoader not installed. Run: brew install openFPGALoader"; exit 1; }
	openFPGALoader --detect -b de0nano

shell:
	$(DOCKER_RUN) bash

rebuild: clean build

clean:
	@echo "==> Cleaning $(SAMPLE)/built"
	rm -rf $(BUILT_DIR)
	@# In case a previous compile leaked artefacts at the sample root
	@# (older layout, or an aborted build), sweep those too.
	rm -rf $(SAMPLE)/db $(SAMPLE)/incremental_db $(SAMPLE)/output_files
	rm -f  $(SAMPLE)/*.rpt $(SAMPLE)/*.summary $(SAMPLE)/*.smsg \
	       $(SAMPLE)/*.done $(SAMPLE)/*.pin $(SAMPLE)/*.jdi \
	       $(SAMPLE)/*.qws  $(SAMPLE)/*.sopcinfo $(SAMPLE)/*.sof \
	       $(SAMPLE)/*.sld  $(SAMPLE)/*.pof $(SAMPLE)/*.jic \
	       $(SAMPLE)/*.rpd  $(SAMPLE)/*.map  $(SAMPLE)/*.svf $(SAMPLE)/*_assignment_defaults.qdf
