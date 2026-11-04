FROM almalinux:10@sha256:5a4b41a427c9717be8f4ac2a32aa22efbae5f9124fbcb79a6765394f312acfe8
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG KCOV_VERSION=v43
ARG KCOV_SHA256=4cbba86af11f72de0c7514e09d59c7927ed25df7cebdad087f6d3623213b95bf

# EL10 peer to Rocky 10: no ydotool/alsa-tools/xdotool/python3-evdev RPMs in base+EPEL.
# Poetry installs evdev; PyGObject via pip against 3.13 (platform python3 is 3.12).
# Exact name-version pins satisfy hadolint DL3041; bump them when the repos move on.
# kcov needs libcurl-devel matching installed libcurl (EL10 appstream/baseos skew).
COPY docker/images/tests/scripts/el10-kcov-libcurl.sh /tmp/el10-kcov-libcurl.sh
RUN chmod +x /tmp/el10-kcov-libcurl.sh \
    && dnf -y install \
        dnf-plugins-core-4.7.0 \
        epel-release-10 \
    && dnf config-manager --set-enabled crb \
    && dnf -y install \
        bash-5.2.26 \
        python3.13-3.13.16 \
        python3.13-pip-25.1.1 \
        python3.13-devel-3.13.16 \
        gcc-14.3.1 \
        gcc-c++-14.3.1 \
        make-4.4.1 \
        cmake-3.31.8 \
        sudo-1.9.17 \
        ca-certificates-2026.2.92_v9.0.319 \
        systemd-257 \
        binutils-2.41 \
        binutils-devel-2.41 \
        elfutils-devel-0.194 \
        elfutils-libelf-devel-0.194 \
        sqlite-3.46.1 \
        sqlite-devel-3.46.1 \
        zlib-ng-compat-devel-2.2.3 \
        openssl-devel-3.5.8 \
        which-2.21 \
        git-2.52.0 \
        dbus-daemon-1.14.10 \
        dbus-devel-1.14.10 \
        pkgconf-pkg-config-2.1.0 \
        glib2-2.80.4 \
        gsettings-desktop-schemas-47.1 \
        libnotify-0.8.6 \
        gettext-0.22.5 \
        gobject-introspection-1.79.1 \
        gobject-introspection-devel-1.79.1 \
        cairo-gobject-1.18.2 \
        cairo-gobject-devel-1.18.2 \
        alsa-utils-1.2.15.2 \
    && /tmp/el10-kcov-libcurl.sh \
    && rm -f /tmp/el10-kcov-libcurl.sh \
    && curl -fL --proto '=https' --tlsv1.2 --retry 8 --retry-all-errors --retry-delay 2 \
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
COPY VERSION pyproject.toml poetry.lock /opt/asus-zenbook-deps/
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
