#!/bin/bash
# Bastion: ansible-core + boto3 + Ansible collections 설치
set -e
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
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

echo "bastion AMI 패키지 설치 완료 (ansible-core + collections)"
