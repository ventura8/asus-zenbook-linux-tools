FROM archlinux:base-devel@sha256:ee205c220399524a683cf495d411691b921baed8ab47cdc6d732efa782fae484

COPY docker/images/tests/scripts/archlinux-mirrorlist /etc/pacman.d/mirrorlist
COPY docker/images/tests/scripts/pacman-retry.sh /tmp/pacman-retry.sh
RUN chmod +x /tmp/pacman-retry.sh \
    && /tmp/pacman-retry.sh -Syu --noconfirm \
    && /tmp/pacman-retry.sh -S --noconfirm \
        bash \
        python \
        python-pip \
        gcc \
        git \
        curl \
        sudo \
        ca-certificates \
        systemd \
        kcov \
        which \
        dbus \
        pkgconf \
        glib2 \
        gsettings-desktop-schemas \
        libnotify \
        python-evdev \
        python-gobject \
        gettext \
        alsa-utils \
        alsa-tools \
        ydotool \
        xdotool \
        xfconf \
        kconfig \
    && pacman -Scc --noconfirm

COPY docker/images/tests/scripts/install-poetry-deps.sh \
     docker/images/tests/scripts/create-asusci-user.sh \
     docker/images/tests/scripts/install-de-family.sh \
     docker/images/tests/scripts/pacman-retry.sh /tmp/
COPY VERSION pyproject.toml poetry.lock /opt/asus-zenbook-deps/
RUN chmod +x /tmp/install-poetry-deps.sh /tmp/create-asusci-user.sh \
        /tmp/install-de-family.sh /tmp/pacman-retry.sh \
    && PYTHON_BIN=python /tmp/install-poetry-deps.sh \
    && rm -f /tmp/install-poetry-deps.sh
ENV PATH="/opt/asus-zenbook-deps/.venv/bin:/opt/poetry-venv/bin:${PATH}"

ARG ASUS_CI_DE_FAMILY=
RUN ASUS_CI_DE_FAMILY="${ASUS_CI_DE_FAMILY}" /tmp/install-de-family.sh \
    && rm -f /tmp/install-de-family.sh /tmp/pacman-retry.sh

# Matrix smoke runs as the host UID (non-root) but must exercise real package
# install/remove. Create a matching account and grant only that UID passwordless sudo.
ARG ASUS_CI_UID=1000
ARG ASUS_CI_GID=1000
ARG ASUS_CI_USER=asusci
RUN /tmp/create-asusci-user.sh && rm -f /tmp/create-asusci-user.sh
WORKDIR /workspace
CMD ["/bin/bash"]
