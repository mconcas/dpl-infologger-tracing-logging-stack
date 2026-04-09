FROM registry.access.redhat.com/ubi9/ubi

ARG INFOLOGGER_VERSION=2.10.1-1772699054

# Add the o2-flp repos and install the standalone InfoLogger package
COPY o2-flp.repo /etc/yum.repos.d/o2-flp.repo

RUN dnf install -y \
        "o2-InfoLogger-standalone-${INFOLOGGER_VERSION}" \
    && dnf clean all

# Default config location (matches the InfoLogger convention)
RUN mkdir -p /etc/o2.d/infologger

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# 6006 – infoLoggerD clients push messages to the server
# 6102 – browsers / bridge subscribe to the live message stream
EXPOSE 6006 6102

ENTRYPOINT ["/entrypoint.sh"]
