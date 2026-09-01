# Base image for the Quartus Prime Lite container.
#
# This file only sets up the OS + libs. The actual Quartus install has to
# happen at container-*runtime* (not build-time) so we can bind-mount a fake
# /proc/cpuinfo over the ARM host's real one — required to fool Altera's
# CPU-capability check under qemu-user emulation. See docker/build-image.sh.
#
# Explicit linux/amd64 so Docker Desktop's x86 emulator (Rosetta or QEMU)
# handles it on Apple Silicon. Rosetta *does not* emulate x87 80-bit long
# double, which Quartus's SQLite fork uses on startup — so this container
# must be run with QEMU. In Docker Desktop: Settings → General → uncheck
# "Use Rosetta for x86_64/amd64 emulation".

FROM --platform=linux/amd64 debian:bullseye-slim

RUN dpkg --add-architecture i386 \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        locales \
        procps \
        make \
        libc6:i386 \
        libncurses5:i386 \
        libstdc++6:i386 \
        libx11-6:i386 \
        libxau6:i386 \
        libxdmcp6:i386 \
        libxext6:i386 \
        libxft2:i386 \
        libxrender1:i386 \
        libxtst6:i386 \
        zlib1g:i386 \
        libglib2.0-0 \
        libfreetype6 \
        libsm6 \
        libxi6 \
        libfontconfig1 \
 && sed -i '/en_US.UTF-8/s/^# //' /etc/locale.gen \
 && locale-gen \
 && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    QEMU_CPU=max

WORKDIR /work
CMD ["bash"]
