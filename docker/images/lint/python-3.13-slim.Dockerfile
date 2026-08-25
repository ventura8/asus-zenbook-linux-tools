FROM python:3.13-slim@sha256:ffb752e139c0a19692a43af8d8523b274222dd68eebad5d583b45c2201c6e30a

ARG TARGETARCH
ARG DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash=* \
        build-essential=* \
        ca-certificates=* \
        curl=* \
        gettext=* \
        git=* \
        gnupg=* \
        libdbus-1-dev=* \
        libglib2.0-dev=* \
        linux-libc-dev=* \
        pkg-config=* \
        shellcheck=* \
        systemd=* \
    && install -d -m 0755 /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key -o /tmp/nodesource.asc \
    && gpg --batch --show-keys --with-fingerprint --with-colons /tmp/nodesource.asc | grep -Fqx 'fpr:::::::::6F71F525282841EEDAF851B42F59B5F99B1BE0B4:' \
    && gpg --batch --dearmor -o /etc/apt/keyrings/nodesource.gpg /tmp/nodesource.asc \
    && echo 'deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x nodistro main' > /etc/apt/sources.list.d/nodesource.list \
    && rm -f /tmp/nodesource.asc \
    && apt-get update \
    && apt-get install -y --no-install-recommends nodejs=* \
    && npm install -g npm@12.0.2 markdownlint-cli@0.49.1 \
    && rm -rf /root/.npm \
    && rm -rf /var/lib/apt/lists/* \
    && case "${TARGETARCH}" in \
        amd64) \
            hadolint_arch=x86_64; \
            hadolint_sha256=c7187db94eeeeca956519a6af171adc31453941a1e777961f6e680f697c8c507; \
            ;; \
        arm64) \
            hadolint_arch=arm64; \
            hadolint_sha256=f6198ef8090f404dbb771abfee086eb8c48ac177f30da7fd3510aca35b344b5d; \
            ;; \
        *) echo "unsupported TARGETARCH for hadolint: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/hadolint/hadolint/releases/download/v2.15.1/hadolint-linux-${hadolint_arch}" \
        -o /usr/local/bin/hadolint \
    && echo "${hadolint_sha256}  /usr/local/bin/hadolint" | sha256sum -c - \
    && chmod +x /usr/local/bin/hadolint

COPY docker/images/tests/scripts/install-poetry-deps.sh /tmp/
COPY VERSION pyproject.toml poetry.lock /opt/asus-zenbook-deps/
RUN chmod +x /tmp/install-poetry-deps.sh \
    && PYTHON_BIN=python /tmp/install-poetry-deps.sh \
    && rm -f /tmp/install-poetry-deps.sh
ENV PATH="/opt/asus-zenbook-deps/.venv/bin:/opt/poetry-venv/bin:${PATH}"

WORKDIR /workspace
CMD ["/bin/bash"]
