FROM almalinux:9

# Install EPEL, enable CRB, and development tools
RUN dnf install -y epel-release dnf-plugins-core && \
    dnf update -y && \
    dnf config-manager --set-enabled crb && \
    dnf group install -y 'Development Tools'

# Add ALICE dependency repo
RUN cat <<'EOF' > /etc/yum.repos.d/alice-system-deps.repo
[alice-system-deps]
name=alice-system-deps
baseurl=https://s3.cern.ch/swift/v1/alibuild-repo/RPMS/o2-full-deps_el9.x86-64/
enabled=1
gpgcheck=0
EOF

# Install ALICE O2 full dependencies and alibuild
RUN dnf update -y && \
    dnf install -y alice-o2-full-deps alibuild && \
    dnf clean all

RUN useradd -m -s /bin/bash alice

USER alice
RUN mkdir -p ~/.ssh && chmod 700 ~/.ssh && \
    ssh-keyscan -t rsa,ecdsa,ed25519 github.com >> ~/.ssh/known_hosts 2>/dev/null && \
    chmod 644 ~/.ssh/known_hosts
RUN --mount=type=secret,id=github_ssh_key,uid=1000,gid=1000,mode=0600 mkdir -p ~/alice && \
    cd ~/alice && \
    export GIT_SSH_COMMAND='ssh -i /run/secrets/github_ssh_key -o IdentitiesOnly=yes' && \
    git clone --branch otel-tracing git@github.com:mconcas/AliceO2.git O2 && \
    git clone --branch master git@github.com:mconcas/alidist.git && \
    git clone --branch master git@github.com:mconcas/Tracing.git && \
    git clone --branch traceable-logs git@github.com:mconcas/InfoLogger.git libInfoLogger

ENV ALIBUILD_WORK_DIR="/home/alice/sw"
RUN cd ~/alice && aliBuild build O2 -d

COPY --chown=alice:alice run-dpl.sh /home/alice/alice/run-dpl.sh
RUN chmod +x /home/alice/alice/run-dpl.sh

ENTRYPOINT ["/home/alice/alice/run-dpl.sh"]