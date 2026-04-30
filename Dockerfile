# syntax=docker/dockerfile:1.7
#
# 86Box + Open Watcom + Claude Code dev sandbox.
# Real-DOS execution via 86Box (headless: Xvfb + x11vnc), accessed by
# the agent through `86box-cmd` (file-based stdin/stdout) and the VNC
# port for human observation.
#
# Targets linux/amd64 even when the host is Apple Silicon: 86Box's
# Linux build is x86_64 and runs under QEMU user-mode emulation in
# Docker Desktop's amd64 container.

FROM --platform=linux/amd64 ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

# --------------------------------------------------------------------
# System packages.
# --------------------------------------------------------------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        software-properties-common; \
    install -d -m 0755 /etc/apt/keyrings; \
    curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x6D9CD73B401A130336ED0A56EBE1B5DED2AD45D6" \
        | gpg --dearmor -o /etc/apt/keyrings/dosemu2-ppa.gpg; \
    chmod 0644 /etc/apt/keyrings/dosemu2-ppa.gpg; \
    echo "deb [signed-by=/etc/apt/keyrings/dosemu2-ppa.gpg] https://ppa.launchpadcontent.net/dosemu2/ppa/ubuntu noble main" \
        > /etc/apt/sources.list.d/dosemu2-ppa.list; \
    apt-get update;

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        sudo \
        vim \
        nano \
        less \
        git \
        bash \
        coreutils \
        findutils \
        grep \
        sed \
        gawk \
        procps \
        unzip \
        zip \
        xz-utils \
        binutils \
        python3 \
        python3-serial \
        python3-pil \
        python3-pip \
        nodejs \
        npm \
        software-properties-common \
        # ── dosemu2 (PRIMARY emulator) + DOS core ──────────────────
        dosemu2 \
        fdpp \
        # window manager + terminal for the live-VNC mode of dosemu2
        fluxbox \
        xterm \
        xdotool \
        # 86Box runtime libraries (alternative emulator; AppImage ships
        # some, but apt versions are what the host loader picks up first).
        libpcre3 libxcb1 libxcb-image0 libxcb-keysyms1 libxcb-randr0 \
        libxcb-render0 libxcb-shape0 libxcb-shm0 libxcb-sync1 \
        libxcb-xfixes0 libxcb-xkb1 libxcb-render-util0 libxcb-icccm4 \
        libxkbcommon-x11-0 libfontconfig1 libxrender1 libdbus-1-3 \
        libslirp0 libsndfile1 libfluidsynth3 libopenal1 libfreetype6 \
        libpng16-16 libxi6 libwayland-client0 \
        # headless display + VNC bridge (shared by both emulators)
        xvfb x11vnc xauth x11-utils x11-apps \
        # disk image manipulation for 86box-cmd file pipeline
        qemu-utils mtools \
        # pixel-mode fallback if VGA-text decoder can't read a screen
        imagemagick tesseract-ocr \
        # serial / debug helpers
        socat netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

# vncdotool from PyPI; Ubuntu doesn't package it.
# --break-system-packages: PEP 668 marks /usr/bin/python3 as managed,
# but since this is a single-purpose container it's safe.
RUN pip install --break-system-packages --no-cache-dir vncdotool==1.3.0

# Claude Code (Node 18+, available in noble).
RUN npm install -g @anthropic-ai/claude-code

# --------------------------------------------------------------------
# Non-root user with passwordless sudo.
# --------------------------------------------------------------------
ARG USERNAME=coder
ARG USER_UID=1000
ARG USER_GID=1000

RUN useradd -m -s /bin/bash ${USERNAME} \
    && usermod -aG sudo ${USERNAME} \
    && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME} \
    && chmod 0440 /etc/sudoers.d/${USERNAME}

# Runtime folders.
RUN mkdir -p /workspace /dos/c /dos/src /opt/dos-c-base /opt/86box /opt/86box-app \
    && chown -R ${USERNAME}:${USERNAME} \
        /workspace /dos /opt/dos-c-base /opt/86box /opt/86box-app

# --------------------------------------------------------------------
# Bake 86Box: AppImage + ROMs.
# Versions are pinned for reproducibility. Bump via build args.
# --------------------------------------------------------------------
ARG BOX86_VERSION=v5.3
ARG BOX86_BUILD=b8200
ENV BOX86_VERSION=${BOX86_VERSION}
ENV BOX86_BUILD=${BOX86_BUILD}
ENV BOX86_INSTALL_DIR=/opt/86box
ENV BOX86_ROMS_DIR=/opt/86box/roms
ENV BOX86_APP_DIR=/opt/86box-app

# Setup script in its own layer for cache hits when only tools change.
COPY tools/86box/setup.sh /usr/local/bin/86box-setup
RUN chmod +x /usr/local/bin/86box-setup \
    && /usr/local/bin/86box-setup

# Rest of the 86Box helper toolkit. Naming convention: every tool lands
# at /usr/local/bin/86box-<name>; source filenames in tools/86box/ keep
# their natural extension (.sh, .py) for editor support. Scripts call
# each other by the on-PATH `86box-<name>` form, so they work whether
# invoked via /usr/local/bin/ or run from /workspace/tools/86box/.
COPY tools/86box/run.sh           /usr/local/bin/86box-run
COPY tools/86box/cmd              /usr/local/bin/86box-cmd
COPY tools/86box/pcmd             /usr/local/bin/86box-pcmd
COPY tools/86box/keys             /usr/local/bin/86box-keys
COPY tools/86box/screen.py        /usr/local/bin/86box-screen
COPY tools/86box/gen-config.py    /usr/local/bin/86box-gen-config
COPY tools/86box/build-fontmap.py /usr/local/bin/86box-build-fontmap
COPY tools/86box/pty-bridge.py    /usr/local/bin/86box-bridge
COPY tools/86box/install-dos.sh   /usr/local/bin/86box-install-dos
RUN chmod +x /usr/local/bin/86box-* \
    && chown -R ${USERNAME}:${USERNAME} /opt/86box /opt/86box-app

# DOS-side helper(s) — built once at image build so 86box-pcmd doesn't
# need to compile PCMDD.EXE on first start. Source lives in
# tools/86box/dos/; the build step (after Watcom is installed below)
# lands the .EXE at /opt/dos-c-base/pcmdd/PCMDD.EXE which 86box-pcmd
# locates by default.
COPY tools/86box/dos /opt/dos-c-base/pcmdd-src
RUN rm -rf /opt/dos-c-base/pcmdd-src/build \
    && chown -R ${USERNAME}:${USERNAME} /opt/dos-c-base/pcmdd-src \
    && mkdir -p /opt/dos-c-base/pcmdd \
    && chown ${USERNAME}:${USERNAME} /opt/dos-c-base/pcmdd

# Toolkit smoke tests — useful for CI / regression checks. Not run at
# build time (they require a live 86Box session); run them inside the
# container with `bash /workspace/tools/86box/tests/test-pcmd.sh` etc.
COPY tools/86box/tests /usr/local/share/86box-tests
RUN chmod +x /usr/local/share/86box-tests/*.sh \
    && chown -R ${USERNAME}:${USERNAME} /usr/local/share/86box-tests

# --------------------------------------------------------------------
# Open Watcom for cross-compiling DOS binaries on the Linux side.
# --------------------------------------------------------------------
ARG OPEN_WATCOM_URL="https://github.com/open-watcom/open-watcom-v2/releases/download/Current-build/open-watcom-2_0-c-linux-x64"
ENV WATCOM=/opt/watcom
ENV PATH="/opt/watcom/binl64:/opt/watcom/binl:${PATH}"
ENV INCLUDE="/opt/watcom/h"
ENV EDPATH="/opt/watcom/eddat"
ENV WIPFC="/opt/watcom/wipfc"

RUN mkdir -p /opt/watcom \
    && curl -fL --retry 5 --retry-all-errors --connect-timeout 30 \
         --speed-time 30 --speed-limit 1024 \
         "${OPEN_WATCOM_URL}" -o /tmp/open-watcom \
    && unzip -oq /tmp/open-watcom -d /opt/watcom \
    && find /opt/watcom/binl /opt/watcom/binl64 -type f \
        -exec chmod +x {} \; 2>/dev/null || true \
    && rm -f /tmp/open-watcom \
    && chown -R ${USERNAME}:${USERNAME} /opt/watcom

# Now that Watcom is in place, build PCMDD.EXE from /opt/dos-c-base/pcmdd-src.
# Run as the non-root user (uid 1000) so the resulting .EXE is readable
# by 86box-pcmd at runtime without an additional chown.
USER ${USERNAME}
ENV PATH="/opt/watcom/binl64:/opt/watcom/binl:${PATH}"
RUN cd /opt/dos-c-base/pcmdd-src \
    && wcl -bt=dos -ms -0 -os -s -d0 -we -wx \
           -fe=/opt/dos-c-base/pcmdd/PCMDD.EXE \
           pcmdd.c seruart.c \
    && rm -f /opt/dos-c-base/pcmdd-src/*.o \
             /opt/dos-c-base/pcmdd-src/*.obj \
             /opt/dos-c-base/pcmdd-src/*.map \
             /opt/dos-c-base/pcmdd-src/*.err
USER root

# --------------------------------------------------------------------
# Bake DOS template VHD into /opt/dos-c-base.
# entrypoint.sh seeds /dos/c/dos.vhd from this on first run of an empty
# project, so per-project state is preserved on rebuilds.
# --------------------------------------------------------------------
COPY template_dos-c.vhd /opt/dos-c-base/template_dos-c.vhd
RUN date > /opt/dos-c-base/BUILT.TXT \
    && chown -R ${USERNAME}:${USERNAME} /opt/dos-c-base

# --------------------------------------------------------------------
# Reference example project. Lives at /opt/dos-c-base/examples/hello/
# in the image; entrypoint.sh seeds /workspace/examples/hello/ from
# this on first run so the bind-mounted workspace gets a working
# starter regardless of which project the user opened. Sources are
# inert until built (`wmake`) + tested (`bash test.sh`).
# --------------------------------------------------------------------
COPY examples /opt/dos-c-base/examples
RUN chown -R ${USERNAME}:${USERNAME} /opt/dos-c-base/examples

# --------------------------------------------------------------------
# Container entry.
# --------------------------------------------------------------------
# --------------------------------------------------------------------
# dosemu2 helper toolkit (PRIMARY emulator path).
# Naming convention parallels the 86box layer: every script lands at
# /usr/local/bin/dosemu-<name>; source filenames in tools/dosemu/ keep
# their natural extension (.sh) for editor support.
# --------------------------------------------------------------------
COPY tools/dosemu/setup.sh                  /usr/local/bin/dosemu-setup
COPY tools/dosemu/run.sh                    /usr/local/bin/dosemu-run
COPY tools/dosemu/cmd                       /usr/local/bin/dosemu-cmd
COPY tools/dosemu/vnc-start.sh              /usr/local/bin/dosemu-vnc-start
COPY tools/dosemu/vnc-stop.sh               /usr/local/bin/dosemu-vnc-stop
COPY tools/dosemu/dosemurc.template         /opt/dosemu/dosemurc.template
COPY tools/dosemu/dosemu-vnc.rc.template    /opt/dosemu/dosemu-vnc.rc.template
RUN chmod +x /usr/local/bin/dosemu-* \
    && mkdir -p /opt/dosemu \
    && cp -n /opt/dosemu/dosemurc.template       /etc/skel/.dosemurc       || true \
    && cp -n /opt/dosemu/dosemu-vnc.rc.template  /etc/skel/.dosemu-vnc.rc  || true \
    && cp -n /opt/dosemu/dosemurc.template       /home/${USERNAME}/.dosemurc       \
    && cp -n /opt/dosemu/dosemu-vnc.rc.template  /home/${USERNAME}/.dosemu-vnc.rc  \
    && chown ${USERNAME}:${USERNAME} \
        /home/${USERNAME}/.dosemurc /home/${USERNAME}/.dosemu-vnc.rc

# Toolkit smoke tests for the dosemu2 path.
COPY tools/dosemu/tests /usr/local/share/dosemu-tests
RUN chmod +x /usr/local/share/dosemu-tests/*.sh 2>/dev/null || true \
    && chown -R ${USERNAME}:${USERNAME} /usr/local/share/dosemu-tests

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENV DOS_ROOT=/dos/c
ENV DOS_SRC=/dos/src
ENV BOX86_VM_PATH=/dos/c
ENV BOX86_VNC_PORT=5901
ENV SHELL=/bin/bash

USER ${USERNAME}
WORKDIR /workspace

# Volumes: /workspace, /dos/c, /dos/src, /home/coder/.claude.
EXPOSE 5901 5556

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/bin/bash"]
