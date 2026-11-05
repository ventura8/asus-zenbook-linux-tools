FROM fedora:44@sha256:15da97ed9aa94dd3d92c3925eb89520f6c80e07ea7ee24cba848d1f8b6912b3e

# Exact name-version pins satisfy hadolint DL3041 (globs do not); bump them when
# the repos move on. Fedora 44 ships Python 3.14 as python3.
RUN dnf -y install --setopt=install_weak_deps=False --nodocs \
    bash-5.3.9 \
    python3-3.14.10 \
    python3-pip-26.0.1 \
    python3-devel-3.14.10 \
    gcc-16.2.1 \
    git-2.56.0 \
    curl-8.18.0 \
    sudo-1.9.17 \
    ca-certificates-2026.2.92_v9.0.319 \
    systemd-259.10 \
    kcov-43 \
    which-2.25 \
    dbus-daemon-1.16.2 \
    dbus-devel-1.16.2 \
    pkgconf-pkg-config-2.5.1 \
    glib2-2.88.4 \
    glib2-devel-2.88.4 \
    gsettings-desktop-schemas-50.1 \
    libnotify-0.8.9 \
    python3-evdev-1.9.3 \
    python3-gobject-3.56.3 \
    gettext-0.26 \
    alsa-tools-1.2.15 \
    alsa-utils-1.2.16 \
    ydotool-1.0.4 \
    xdotool-3.20211022.1 \
    xfconf-4.20.0 \
    kf6-kconfig-6.31.0 \
    && dnf clean all

COPY docker/images/tests/scripts/install-poetry-deps.sh \
     docker/images/tests/scripts/create-asusci-user.sh \
     docker/images/tests/scripts/install-de-family.sh /tmp/
COPY VERSION pyproject.toml poetry.lock /opt/asus-zenbook-deps/
RUN chmod +x /tmp/install-poetry-deps.sh /tmp/create-asusci-user.sh /tmp/install-de-family.sh \
    && PYTHON_BIN=python3 /tmp/install-poetry-deps.sh \
    && rm -f /tmp/install-poetry-deps.sh
ENV PATH="/opt/asus-zenbook-deps/.venv/bin:/opt/poetry-venv/bin:${PATH}"

ARG ASUS_CI_DE_FAMILY=
RUN ASUS_CI_DE_FAMILY="${ASUS_CI_DE_FAMILY}" /tmp/install-de-family.sh \
    && rm -f /tmp/install-de-family.sh

# Matrix smoke runs as the host UID (non-root) but must exercise real package
# install/remove. Create a matching account and grant only that UID passwordless sudo.
ARG ASUS_CI_UID=1000
ARG ASUS_CI_GID=1000
ARG ASUS_CI_USER=asusci
RUN /tmp/create-asusci-user.sh && rm -f /tmp/create-asusci-user.sh
WORKDIR /workspace
CMD ["/bin/bash"]
