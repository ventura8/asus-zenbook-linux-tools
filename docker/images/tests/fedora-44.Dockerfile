FROM fedora:44@sha256:6c75d5bf57cb0fa5aa4b92c6a83c86c791644496d9ac230de7711f5b8ec3b898

# Use version globs for hadolint DL3041. Fedora 44 ships Python 3.14 as
# python3 — pin python3-3.14* / python3-devel-3.14*. Do NOT use systemd-* —
# it pulls systemd-tests and systemd-standalone-* and conflicts across
# fedora/updates; constrain to systemd-<digit>… . Use git-[0-9]* (not bare
# git-*): the broad glob also pulls git-extras and git-pull-request, which
# conflict on /usr/bin/git-pull-request.
RUN dnf -y install --setopt=install_weak_deps=False --nodocs \
    bash-* \
    python3-3.14* \
    python3-pip-* \
    python3-devel-3.14* \
    gcc-* \
    git-[0-9]* \
    curl-* \
    sudo-* \
    ca-certificates-* \
    systemd-[0-9]* \
    kcov-* \
    which-* \
    dbus-daemon-* \
    dbus-devel-* \
    pkgconf-pkg-config-* \
    glib2-* \
    glib2-devel-* \
    gsettings-desktop-schemas-* \
    libnotify-* \
    python3-evdev-* \
    python3-gobject-* \
    gettext-* \
    # Prefer alsa-utils-[0-9]* (NEVRA) over a trailing-star name glob: the latter
    # only pulls subpackages such as alsa-utils-alsabat and skips main alsa-utils.
    alsa-tools-* \
    alsa-utils-[0-9]* \
    ydotool-* \
    xdotool-* \
    xfconf-* \
    kf6-kconfig-* \
    && dnf clean all

COPY docker/images/tests/scripts/install-poetry-deps.sh \
     docker/images/tests/scripts/create-asusci-user.sh \
     docker/images/tests/scripts/install-de-family.sh /tmp/
COPY pyproject.toml poetry.lock /opt/asus-zenbook-deps/
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
