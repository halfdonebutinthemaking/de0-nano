# DE0-Nano FPGA build & program pipeline for macOS
#
# Split of responsibilities:
#   - Synthesis + place & route: Quartus Prime Lite inside a Linux/amd64
#     Docker container (Rosetta on Apple Silicon). See docker/Dockerfile.
#   - Programming: openFPGALoader running natively on macOS, talking to
#     the DE0-Nano's onboard FT245 (USB Blaster) over USB.

PROJECT         := de0_nano
PROJECT_DIR     := project
SRC_DIR         := src
SOF             := $(PROJECT_DIR)/$(PROJECT).sof

DOCKER_IMAGE    := de0nano-quartus:latest
DOCKER_PLATFORM := linux/amd64

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

.PHONY: help build program clean docker-image shell check-usb rebuild

help:
	@echo "DE0-Nano bridge targets:"
	@echo "  make docker-image  Build the Quartus Docker image (one-time, ~30 min)"
	@echo "  make build         Synthesize -> $(SOF)"
	@echo "  make program       Flash the .sof to the DE0-Nano (volatile, SRAM)"
	@echo "  make rebuild       clean + build"
	@echo "  make check-usb     Verify openFPGALoader sees the DE0-Nano"
	@echo "  make shell         Interactive shell inside the Quartus container"
	@echo "  make clean         Remove synthesis artifacts"

docker-image:
	bash docker/build-image.sh $(DOCKER_IMAGE)

build: $(SOF)

$(SOF): $(SOURCES) $(PROJECT_DIR)/$(PROJECT).qsf $(PROJECT_DIR)/$(PROJECT).qpf
	@if ! docker image inspect $(DOCKER_IMAGE) >/dev/null 2>&1; then \
	    echo "Docker image '$(DOCKER_IMAGE)' not found. Run: make docker-image"; \
	    exit 1; \
	fi
	$(DOCKER_RUN) bash -c "cd $(PROJECT_DIR) && quartus_sh --flow compile $(PROJECT)"
	@echo ""
	@echo "Built: $(SOF)"

program: $(SOF)
	@command -v openFPGALoader >/dev/null 2>&1 || { \
	    echo "openFPGALoader not installed. Run: brew install openFPGALoader"; exit 1; }
	openFPGALoader -b de0nano $(SOF)

check-usb:
	@command -v openFPGALoader >/dev/null 2>&1 || { \
	    echo "openFPGALoader not installed. Run: brew install openFPGALoader"; exit 1; }
	openFPGALoader --detect -b de0nano

shell:
	$(DOCKER_RUN) bash

rebuild: clean build

clean:
	rm -rf $(PROJECT_DIR)/db $(PROJECT_DIR)/incremental_db $(PROJECT_DIR)/output_files
	rm -f  $(PROJECT_DIR)/*.rpt $(PROJECT_DIR)/*.summary $(PROJECT_DIR)/*.smsg \
	       $(PROJECT_DIR)/*.done $(PROJECT_DIR)/*.pin $(PROJECT_DIR)/*.jdi \
	       $(PROJECT_DIR)/*.qws  $(PROJECT_DIR)/*.sopcinfo $(PROJECT_DIR)/*.sof \
	       $(PROJECT_DIR)/*.sld  $(PROJECT_DIR)/*.pof
