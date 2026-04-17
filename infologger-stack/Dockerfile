FROM almalinux:9

ARG INFOLOGGER_REPO=https://github.com/mconcas/InfoLogger.git
ARG INFOLOGGER_BRANCH=traceable-logs

# ── Build stage: compile InfoLogger from source ───────────────────────────────
# Enable CRB for boost-devel and other -devel packages
RUN dnf install -y 'dnf-command(config-manager)' \
    && dnf config-manager --set-enabled crb

RUN dnf install -y \
        gcc gcc-c++ cmake ninja-build git \
        boost-devel \
        mariadb-connector-c-devel mariadb \
        tcl-devel \
        tcl socat \
        pcre2-devel automake autoconf bison \
    && dnf clean all

# Build SWIG >= 4.2.0 from source (AlmaLinux 9 ships 4.0.2, CMake requires >= 4.2.0)
ARG SWIG_VERSION=4.2.1
RUN git clone --depth 1 --branch v${SWIG_VERSION} https://github.com/swig/swig.git /tmp/swig \
    && cd /tmp/swig \
    && ./autogen.sh && ./configure --prefix=/usr/local && make -j"$(nproc)" && make install \
    && rm -rf /tmp/swig

# Clone and build
RUN git clone --depth 1 --branch "${INFOLOGGER_BRANCH}" "${INFOLOGGER_REPO}" /tmp/InfoLogger \
    && cmake -S /tmp/InfoLogger -B /tmp/InfoLogger/build -G Ninja \
        -DCMAKE_INSTALL_PREFIX=/opt/o2-InfoLogger \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    && ninja -C /tmp/InfoLogger/build install \
    && rm -rf /tmp/InfoLogger

# Default config location (matches the InfoLogger convention)
RUN mkdir -p /etc/o2.d/infologger

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# 6006 – infoLoggerD clients push messages to the server
# 6102 – browsers / bridge subscribe to the live message stream
# 6007 – socat bridge: TCP → abstract infoLoggerD socket (for macOS host clients)
EXPOSE 6006 6102 6007

ENTRYPOINT ["/entrypoint.sh"]
