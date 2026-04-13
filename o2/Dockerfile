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

# Configure alibuild work directory
ENV ALIBUILD_WORK_DIR=/alice/sw

RUN useradd -m -s /bin/bash alice
USER alice
WORKDIR /home/alice

# Initialize alibuild shell helper in bashrc
RUN echo 'export ALIBUILD_WORK_DIR="$HOME/alice/sw"' >> ~/.bashrc && \
    echo 'eval "$(alienv shell-helper)"' >> ~/.bashrc
