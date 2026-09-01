#!/usr/bin/env bash
# Two-stage build of the DE0-Nano Quartus image on Apple Silicon.
#
# Stage 1 — a minimal Debian base image (via Dockerfile).
# Stage 2 — start that base image as a container with a bind-mount over
#           /proc/cpuinfo (fake x86 descriptor) and the Quartus installer,
#           run the installer, apply federunco's Rosetta patches (patched
#           libccl_sqlite3.so + qenv.sh aarch64 detection), commit the
#           container as the final image.
#
# We can't do stage 2 in a plain Dockerfile RUN because BuildKit doesn't
# let us bind-mount over virtual /proc entries, and without the shim the
# installer sees the ARM host's /proc/cpuinfo and aborts with
#   "The Quartus Prime software is optimized for the Intel Nehalem processor
#    and newer processors. The required extensions were not found on: ''".
#
# The install itself works under either QEMU or Rosetta emulation. For the
# resulting image to be *usable* (able to open a project without
# segfaulting), Docker Desktop must be set to use Rosetta and the patched
# libccl_sqlite3.so from docker/vendor/ must be applied over the stock one.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE_IMAGE="de0nano-quartus-base:latest"
FINAL_IMAGE="${1:-de0nano-quartus:latest}"
INSTALL_DIR="/opt/intelFPGA_lite"
INSTALLER_DIR="$REPO_ROOT/instructions"
FAKE_CPUINFO="$REPO_ROOT/docker/fake_cpuinfo"

if [ ! -f "$FAKE_CPUINFO" ]; then
    echo "ERROR: fake cpuinfo missing at $FAKE_CPUINFO" >&2
    exit 1
fi

# Accept any of three drop-in formats Altera ships:
#   - qinst bootstrap (~126 MB, downloads payload from Altera CDN)
#   - combined tarball (~7 GB, bundles .run + all .qdz)
#   - individual files (QuartusLiteSetup-*.run + cyclone-*.qdz side-by-side)
STAGE_DIR="$INSTALLER_DIR/_extracted"
QINST=$(ls "$INSTALLER_DIR"/qinst-lite-linux-*.run 2>/dev/null | head -n1 || true)
TARBALL=$(ls "$INSTALLER_DIR"/*.tar 2>/dev/null | head -n1 || true)
INSTALLER=$(ls "$INSTALLER_DIR"/QuartusLiteSetup-*.run 2>/dev/null | head -n1 || true)
QDZ=$(ls "$INSTALLER_DIR"/cyclone-*.qdz 2>/dev/null | head -n1 || true)

if [ -n "$QINST" ]; then
    echo "==> Found qinst bootstrap: $(basename "$QINST")"
    MODE=qinst
    VENDOR_MOUNT="$INSTALLER_DIR"
elif [ -n "$TARBALL" ]; then
    echo "==> Found combined tarball: $(basename "$TARBALL")"
    if [ -d "$STAGE_DIR" ] && find "$STAGE_DIR" -maxdepth 4 -name 'QuartusLiteSetup-*-linux.run' -print -quit 2>/dev/null | grep -q .; then
        echo "==> Reusing existing host extraction at $STAGE_DIR"
    else
        echo "==> Extracting on host into $STAGE_DIR (~2-3 min, uses ~7 GB of host disk)..."
        rm -rf "$STAGE_DIR"
        mkdir -p "$STAGE_DIR"
        tar -xf "$TARBALL" -C "$STAGE_DIR"
    fi
    MODE=classic
    VENDOR_MOUNT="$STAGE_DIR"
elif [ -n "$INSTALLER" ] && [ -n "$QDZ" ]; then
    echo "==> Found pre-extracted installer + Cyclone IV device package"
    MODE=classic
    VENDOR_MOUNT="$INSTALLER_DIR"
else
    echo "ERROR: no usable Quartus artifacts under $INSTALLER_DIR" >&2
    echo "Need one of:" >&2
    echo "  (a) qinst bootstrap:   qinst-lite-linux-*.run  (downloads on demand)" >&2
    echo "  (b) Combined tarball:  *.tar" >&2
    echo "  (c) Individual files:  QuartusLiteSetup-*.run + cyclone-*.qdz" >&2
    echo "See instructions/INSTRUCTIONS.md." >&2
    exit 1
fi

echo "==> [1/3] Building base image..."
docker build --platform=linux/amd64 -t "$BASE_IMAGE" "$REPO_ROOT/docker/"

echo "==> [2/3] Installing Quartus Prime Lite in a scratch container..."
echo "    (~20-40 min under QEMU emulation)"

if [ "$MODE" = "qinst" ]; then
    INSTALL_CMD='
        set -eux
        cd /tmp
        # qinst bootstrap: downloads Quartus + selected device family from
        # Altera CDN, then installs. Needs internet during this step.
        RUN_FILE=$(find /vendor -maxdepth 2 -type f -name "qinst-lite-linux-*.run" | head -n1)
        cp "$RUN_FILE" /tmp/qsetup.run
        chmod +x /tmp/qsetup.run
        mkdir -p /tmp/qdl
        ./qsetup.run --accept --nox11 --noprogress -- \
            --cli --accept-eula \
            --download-dir /tmp/qdl \
            --install-dir '"${INSTALL_DIR}"' \
            --components quartus,cyclone \
            --auto-install --bypass --delete-downloads
        rm -rf /tmp/qsetup.run /tmp/qdl
    '
else
    INSTALL_CMD='
        set -eux
        cd /tmp
        RUN_FILE=$(find /vendor -type f -name "QuartusLiteSetup-*-linux.run" 2>/dev/null | head -n1)
        QDZ_FILE=$(find /vendor -type f -name "cyclone-*.qdz" 2>/dev/null | head -n1)
        if [ -z "$RUN_FILE" ] || [ -z "$QDZ_FILE" ]; then
            echo "ERROR: missing QuartusLiteSetup-*.run + cyclone-*.qdz under /vendor" >&2
            find /vendor -maxdepth 3 -type f \( -name "*.run" -o -name "*.qdz" \) 2>/dev/null >&2
            exit 1
        fi
        echo "Installer: $RUN_FILE"
        echo "Device:    $QDZ_FILE"
        cp "$RUN_FILE" /tmp/qsetup.run
        ln -s "$QDZ_FILE" /tmp/  # installer picks up .qdz from cwd
        chmod +x /tmp/qsetup.run
        ./qsetup.run --mode unattended \
            --unattendedmodeui none \
            --accept_eula 1 \
            --installdir '"${INSTALL_DIR}"' \
            --disable-components quartus_help,questa_fse,questa_fe,quartus_update
        rm -f /tmp/qsetup.run /tmp/cyclone-*.qdz
    '
fi

POST_INSTALL_CMD='
    QBIN=$(find '"${INSTALL_DIR}"' -type f -name quartus_sh -path "*/quartus/bin/*" 2>/dev/null | head -n1)
    if [ -z "$QBIN" ]; then
        echo "ERROR: quartus_sh not found after install" >&2
        find '"${INSTALL_DIR}"' -maxdepth 4 -type d 2>/dev/null | sort >&2
        exit 1
    fi
    QDIR=$(dirname $(dirname "$QBIN"))
    ln -sfn "$QDIR" /opt/quartus

    # federunco Apple-Silicon fixes for Rosetta compatibility.
    # (1) Replace libccl_sqlite3.so — the stock one hits Illegal Instruction
    #     on Rosetta because Rosetta does not emulate x87 extended precision.
    # (2) Patch qenv.sh — add aarch64 detection so Quartus stops trying to
    #     re-detect its bit-type from the wrong uname.
    # Source: https://gist.github.com/federunco/f2bde2e25342c6284b68ce4ecf305e5d
    if [ -f /vendor/libccl_sqlite3.so ]; then
        echo "==> Applying patched libccl_sqlite3.so (federunco)"
        cp /vendor/libccl_sqlite3.so /opt/quartus/linux64/libccl_sqlite3.so
    else
        echo "WARN: /vendor/libccl_sqlite3.so missing — Rosetta will crash Quartus on startup" >&2
    fi
    QENV=/opt/quartus/adm/qenv.sh
    if [ -f "$QENV" ] && ! grep -q "aarch64" "$QENV"; then
        echo "==> Patching qenv.sh (aarch64 detection)"
        sed -i "2i if test \\\`uname -m\\\` = \"aarch64\" ; then export QUARTUS_BIT_TYPE=64 ; fi" "$QENV"
    fi

    /opt/quartus/bin/quartus_sh --version
'

CID=$(docker create \
    --platform=linux/amd64 \
    -e QEMU_CPU=max \
    -v "$FAKE_CPUINFO":/proc/cpuinfo:ro \
    -v "$VENDOR_MOUNT":/vendor:ro \
    "$BASE_IMAGE" \
    bash -c "${INSTALL_CMD}${POST_INSTALL_CMD}")

cleanup() { docker rm -f "$CID" >/dev/null 2>&1 || true; }
trap cleanup EXIT

if ! docker start -a "$CID"; then
    echo "ERROR: install container exited non-zero" >&2
    exit 1
fi

STATUS=$(docker inspect -f '{{.State.ExitCode}}' "$CID")
if [ "$STATUS" -ne 0 ]; then
    echo "ERROR: install container exit code $STATUS" >&2
    exit 1
fi

echo "==> [3/3] Committing container as $FINAL_IMAGE..."
docker commit \
    --change 'ENV PATH=/opt/quartus/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
    --change 'ENV QUARTUS_ROOTDIR=/opt/quartus' \
    --change 'ENV QSYS_ROOTDIR=/opt/quartus/sopc_builder/bin' \
    --change 'WORKDIR /work' \
    --change 'CMD ["bash"]' \
    "$CID" "$FINAL_IMAGE" >/dev/null

echo ""
echo "==> Done. Image: $FINAL_IMAGE"
echo "    Runtime containers need the fake /proc/cpuinfo mount too."
echo "    The Makefile handles this via -v docker/fake_cpuinfo:/proc/cpuinfo:ro."
