FROM python:3.13-slim@sha256:9662417aace5ae7b8e2609cce472b72a8958e134ba372808abe9cc1a0c0125e6

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
    && echo 'deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main' > /etc/apt/sources.list.d/nodesource.list \
    && rm -f /tmp/nodesource.asc \
    && apt-get update \
    && apt-get install -y --no-install-recommends nodejs=* \
    && npm install -g npm@12.0.2 markdownlint-cli@0.49.1 \
    && rm -rf /root/.npm \
    && rm -rf /var/lib/apt/lists/* \
    && case "${TARGETARCH}" in \
        amd64) \
            hadolint_arch=x86_64; \
            hadolint_sha256=56de6d5e5ec427e17b74fa48d51271c7fc0d61244bf5c90e828aab8362d55010; \
            ;; \
        arm64) \
            hadolint_arch=arm64; \
            hadolint_sha256=5798551bf19f33951881f15eb238f90aef023f11e7ec7e9f4c37961cb87c5df6; \
            ;; \
        *) echo "unsupported TARGETARCH for hadolint: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/hadolint/hadolint/releases/download/v2.12.0/hadolint-Linux-${hadolint_arch}" \
        -o /usr/local/bin/hadolint \
    && echo "${hadolint_sha256}  /usr/local/bin/hadolint" | sha256sum -c - \
    && chmod +x /usr/local/bin/hadolint

COPY docker/images/tests/scripts/install-poetry-deps.sh /tmp/
COPY pyproject.toml poetry.lock /opt/asus-zenbook-deps/
RUN chmod +x /tmp/install-poetry-deps.sh \
    && PYTHON_BIN=python /tmp/install-poetry-deps.sh \
    && rm -f /tmp/install-poetry-deps.sh
ENV PATH="/opt/asus-zenbook-deps/.venv/bin:/opt/poetry-venv/bin:${PATH}"

WORKDIR /workspace
CMD ["/bin/bash"]
