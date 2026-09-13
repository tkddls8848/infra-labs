#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y python3-pip pipx

su - ubuntu -c "
  pipx install ansible-core
  pipx inject ansible-core boto3 botocore
  /home/ubuntu/.local/bin/ansible-galaxy collection install --upgrade \
    amazon.aws \
    ansible.posix \
    community.general \
    community.crypto
"

touch /tmp/ansible-ready
