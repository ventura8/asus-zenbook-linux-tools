FROM ubuntu:26.04@sha256:2260313b31c8c011cd2eebe728008efac1b3982be73eb71348ea2648d2c0e09b

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
        alsa-tools=* \
        alsa-utils=* \
        ydotool=* \
        xdotool=* \
        xfconf=* \
        libkf6config-bin=* \
        gettext=* \
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
