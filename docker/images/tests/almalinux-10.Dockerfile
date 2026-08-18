FROM almalinux:10@sha256:cc24bc5b6ac7e284f2f62a07bdaa1b15d3319fdcf46413c6b8fe9fa245068ddd
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG KCOV_VERSION=v43
ARG KCOV_SHA256=4cbba86af11f72de0c7514e09d59c7927ed25df7cebdad087f6d3623213b95bf

# EL10 peer to Rocky 10: no ydotool/alsa-tools/xdotool/python3-evdev RPMs in base+EPEL.
# Poetry installs evdev; PyGObject via pip against 3.13 (platform python3 is 3.12).
# Prefer NEVRA-style -[0-9]* / exact python3.13 names (bare name-* pulls toolchains).
# kcov needs libcurl-devel matching installed libcurl (EL10 appstream/baseos skew).
COPY docker/images/tests/scripts/el10-kcov-libcurl.sh /tmp/el10-kcov-libcurl.sh
RUN chmod +x /tmp/el10-kcov-libcurl.sh \
    && dnf -y install \
        dnf-plugins-core-* \
        epel-release-* \
    && dnf config-manager --set-enabled crb \
    && dnf -y install \
        bash-[0-9]* \
        python3.13 \
        python3.13-pip \
        python3.13-devel \
        gcc-[0-9]* \
        gcc-c++-[0-9]* \
        make-[0-9]* \
        cmake-[0-9]* \
        sudo-* \
        ca-certificates-* \
        systemd-[0-9]* \
        binutils-[0-9]* \
        binutils-devel-[0-9]* \
        elfutils-devel-* \
        elfutils-libelf-devel-* \
        sqlite-* \
        zlib-devel \
        openssl-devel-* \
        which-* \
        git-[0-9]* \
        dbus-daemon-* \
        dbus-devel-* \
        pkgconf-pkg-config-* \
        glib2-[0-9]* \
        gsettings-desktop-schemas-* \
        libnotify-* \
        gettext-* \
        gobject-introspection-* \
        gobject-introspection-devel-* \
        cairo-gobject-* \
        cairo-gobject-devel-* \
        alsa-utils-[0-9]* \
    && /tmp/el10-kcov-libcurl.sh \
    && rm -f /tmp/el10-kcov-libcurl.sh \
    && curl -fL --retry 8 --retry-all-errors --retry-delay 2 \
        "https://github.com/SimonKagstrom/kcov/archive/refs/tags/${KCOV_VERSION}.tar.gz" \
        -o /tmp/kcov.tar.gz \
    && echo "${KCOV_SHA256}  /tmp/kcov.tar.gz" | sha256sum -c - \
    && mkdir -p /tmp/kcov \
    && tar -xzf /tmp/kcov.tar.gz -C /tmp/kcov --strip-components=1 \
    && rm -f /tmp/kcov.tar.gz \
    && cmake -S /tmp/kcov -B /tmp/kcov/build -DCMAKE_BUILD_TYPE=Release \
    && cmake --build /tmp/kcov/build -- -j"$(nproc)" \
    && cmake --install /tmp/kcov/build \
    && rm -rf /tmp/kcov \
    && dnf clean all

COPY docker/images/tests/scripts/install-poetry-deps.sh \
     docker/images/tests/scripts/create-asusci-user.sh \
     docker/images/tests/scripts/install-de-family.sh /tmp/
COPY pyproject.toml poetry.lock /opt/asus-zenbook-deps/
RUN chmod +x /tmp/install-poetry-deps.sh /tmp/create-asusci-user.sh /tmp/install-de-family.sh \
    && PYTHON_BIN=python3.13 /tmp/install-poetry-deps.sh \
    && /opt/asus-zenbook-deps/.venv/bin/pip install --no-cache-dir --root-user-action=ignore \
        'PyGObject>=3.42,<3.52' \
    && /opt/asus-zenbook-deps/.venv/bin/python -c 'import evdev; import gi' \
    && rm -f /tmp/install-poetry-deps.sh \
    && kcov --version >/dev/null \
    && dnf -y remove --setopt=clean_requirements_on_remove=0 \
        cmake \
        gcc \
        "gcc-c++" \
        make \
        binutils-devel \
        elfutils-devel \
        elfutils-libelf-devel \
        zlib-devel \
        openssl-devel \
        libcurl-devel \
        gobject-introspection-devel \
        cairo-gobject-devel \
    && kcov --version >/dev/null \
    && dnf clean all
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
