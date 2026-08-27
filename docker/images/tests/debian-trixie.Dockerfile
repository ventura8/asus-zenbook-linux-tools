FROM debian:trixie@sha256:f324c7ff54321e8d9c588493a20244965938ce0aa50bbd1022d38010e9ffc4b1

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash=* \
        python3=* \
        python3-pip=* \
        python3-venv=* \
        python3-dev=* \
        gcc=* \
        linux-libc-dev=* \
        git=* \
        curl=* \
        sudo=* \
        ca-certificates=* \
        systemd=* \
        kcov=* \
        dbus=* \
        libdbus-1-dev=* \
        libglib2.0-dev=* \
        pkg-config=* \
        libglib2.0-bin=* \
        gsettings-desktop-schemas=* \
        libnotify-bin=* \
        python3-evdev=* \
        python3-gi=* \
        gettext=* \
        alsa-tools=* \
        alsa-utils=* \
        xdotool=* \
        xfconf=* \
        libkf6config-bin=* \
    && rm -rf /var/lib/apt/lists/*

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
