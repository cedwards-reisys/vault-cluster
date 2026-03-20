# Amazon Linux 2023 container for Vault cluster management
# Includes: AWS CLI, OpenTofu, Vault CLI, jq, curl, openssl

FROM public.ecr.aws/amazonlinux/amazonlinux:2023

ARG TOFU_VERSION=1.6.2
ARG VAULT_VERSION=1.21.4

# Install base dependencies
RUN dnf install -y \
    curl \
    unzip \
    jq \
    openssl \
    tar \
    gzip \
    less \
    groff \
    bash-completion \
    && dnf clean all

# Install AWS CLI v2
RUN curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/aws /tmp/awscliv2.zip

# Install OpenTofu
RUN ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/') \
    && curl -sL "https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_linux_${ARCH}.zip" -o /tmp/tofu.zip \
    && unzip -q /tmp/tofu.zip -d /usr/local/bin \
    && chmod +x /usr/local/bin/tofu \
    && rm /tmp/tofu.zip

# Install Vault CLI
RUN ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/') \
    && curl -sL "https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_${ARCH}.zip" -o /tmp/vault.zip \
    && unzip -q /tmp/vault.zip -d /usr/local/bin \
    && chmod +x /usr/local/bin/vault \
    && rm /tmp/vault.zip

# Create non-root user
RUN useradd -m -s /bin/bash operator

# Set up working directory
WORKDIR /workspace

# Copy scripts and make executable
COPY --chown=operator:operator scripts/ /workspace/scripts/
RUN chmod +x /workspace/scripts/*.sh

# Copy Terraform files
COPY --chown=operator:operator terraform/*.tf /workspace/terraform/
COPY --chown=operator:operator terraform/terraform.tfvars.example /workspace/terraform/
COPY --chown=operator:operator terraform/modules/ /workspace/terraform/modules/
COPY --chown=operator:operator terraform/environments/ /workspace/terraform/environments/
COPY --chown=operator:operator terraform/backend-configs/ /workspace/terraform/backend-configs/

# Verify installations
RUN aws --version \
    && tofu --version \
    && vault --version \
    && jq --version

# Switch to non-root user
USER operator

# Default command
CMD ["/bin/bash"]
