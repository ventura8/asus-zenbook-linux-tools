FROM opensuse/tumbleweed@sha256:6e40218854d0ef063cfbd0a05898c04d8cb7e4ec823f40cfe19f0c60ddb317e0

RUN zypper --non-interactive refresh \
    && zypper --non-interactive install -y \
        'bash>=0' \
        'python313>=0' \
        'python313-pip>=0' \
        'python313-devel>=0' \
        'gcc>=0' \
        'git>=0' \
        'curl>=0' \
        'sudo>=0' \
        'ca-certificates>=0' \
        'systemd>=0' \
        'kcov>=0' \
        'which>=0' \
        'dbus-1>=0' \
        'dbus-1-devel>=0' \
        'pkgconf-pkg-config>=0' \
        'glib2-devel>=0' \
        'glib2-tools>=0' \
        'gsettings-desktop-schemas>=0' \
        'libnotify-tools>=0' \
        'python313-evdev>=0' \
        'python313-gobject>=0' \
        'python313-curses>=0' \
        'gettext-tools>=0' \
        'hda-verb>=0' \
        'alsa-utils>=0' \
        'ydotool>=0' \
        'xdotool>=0' \
        'xfconf>=0' \
        'kf6-kconfig>=0' \
    && zypper clean --all

COPY docker/images/tests/scripts/install-poetry-deps.sh \
     docker/images/tests/scripts/create-asusci-user.sh \
     docker/images/tests/scripts/install-de-family.sh /tmp/
COPY VERSION pyproject.toml poetry.lock /opt/asus-zenbook-deps/
RUN chmod +x /tmp/install-poetry-deps.sh /tmp/create-asusci-user.sh /tmp/install-de-family.sh \
    && PYTHON_BIN=python3.13 /tmp/install-poetry-deps.sh \
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
