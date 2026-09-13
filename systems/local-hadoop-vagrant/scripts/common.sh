#!/usr/bin/env bash
set -euo pipefail

ROLE="${1:?role is required}"
HADOOP_VERSION="${2:-3.5.0}"
HADOOP_HOME="/opt/hadoop"
HADOOP_USER="hadoop"
JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64"
DOWNLOAD_URL="https://downloads.apache.org/hadoop/common/hadoop-${HADOOP_VERSION}/hadoop-${HADOOP_VERSION}.tar.gz"
KEY_DIR="/vagrant/.lab/ssh"

cat >/etc/hosts <<'EOF'
127.0.0.1 localhost
192.168.70.10 hadoop-master
192.168.70.21 hadoop-worker1
192.168.70.22 hadoop-worker2
EOF

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y openjdk-17-jdk openssh-server rsync curl tar

id -u "$HADOOP_USER" >/dev/null 2>&1 || useradd --create-home --shell /bin/bash "$HADOOP_USER"

if [[ ! -d "/opt/hadoop-${HADOOP_VERSION}" ]]; then
  tmp_dir="$(mktemp -d)"
  curl -fsSL "$DOWNLOAD_URL" -o "$tmp_dir/hadoop.tar.gz"
  curl -fsSL "${DOWNLOAD_URL}.sha512" -o "$tmp_dir/hadoop.tar.gz.sha512"
  expected_sha512="$(awk '{print $NF}' "$tmp_dir/hadoop.tar.gz.sha512")"
  actual_sha512="$(sha512sum "$tmp_dir/hadoop.tar.gz" | awk '{print $1}')"
  [[ "$actual_sha512" == "$expected_sha512" ]]
  tar -xzf "$tmp_dir/hadoop.tar.gz" -C /opt
  rm -rf "$tmp_dir"
fi
ln -sfn "/opt/hadoop-${HADOOP_VERSION}" "$HADOOP_HOME"

install -d -m 0755 /var/lib/hadoop/hdfs/namenode /var/lib/hadoop/hdfs/datanode /var/log/hadoop /var/run/hadoop
chown -R "$HADOOP_USER:$HADOOP_USER" "/opt/hadoop-${HADOOP_VERSION}" /var/lib/hadoop /var/log/hadoop /var/run/hadoop

install -d -m 0700 "$KEY_DIR"
if [[ ! -f "$KEY_DIR/id_ed25519" ]]; then
  ssh-keygen -t ed25519 -N "" -f "$KEY_DIR/id_ed25519"
fi

install -d -m 0700 "/home/$HADOOP_USER/.ssh"
install -m 0600 "$KEY_DIR/id_ed25519" "/home/$HADOOP_USER/.ssh/id_ed25519"
install -m 0644 "$KEY_DIR/id_ed25519.pub" "/home/$HADOOP_USER/.ssh/id_ed25519.pub"
cat "$KEY_DIR/id_ed25519.pub" >"/home/$HADOOP_USER/.ssh/authorized_keys"
chmod 0600 "/home/$HADOOP_USER/.ssh/authorized_keys"
cat >"/home/$HADOOP_USER/.ssh/config" <<'EOF'
Host hadoop-master hadoop-worker1 hadoop-worker2
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
EOF
chmod 0600 "/home/$HADOOP_USER/.ssh/config"
chown -R "$HADOOP_USER:$HADOOP_USER" "/home/$HADOOP_USER/.ssh"

cat >/etc/profile.d/hadoop.sh <<EOF
export JAVA_HOME=$JAVA_HOME
export HADOOP_HOME=$HADOOP_HOME
export HADOOP_CONF_DIR=$HADOOP_HOME/etc/hadoop
export PATH=\$PATH:\$HADOOP_HOME/bin:\$HADOOP_HOME/sbin
EOF

cat >"$HADOOP_HOME/etc/hadoop/hadoop-env.sh" <<EOF
export JAVA_HOME=$JAVA_HOME
export HADOOP_LOG_DIR=/var/log/hadoop
export HADOOP_PID_DIR=/var/run/hadoop
EOF

cat >"$HADOOP_HOME/etc/hadoop/core-site.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <property>
    <name>fs.defaultFS</name>
    <value>hdfs://hadoop-master:8020</value>
  </property>
</configuration>
EOF

cat >"$HADOOP_HOME/etc/hadoop/hdfs-site.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <property>
    <name>dfs.replication</name>
    <value>2</value>
  </property>
  <property>
    <name>dfs.namenode.name.dir</name>
    <value>file:///var/lib/hadoop/hdfs/namenode</value>
  </property>
  <property>
    <name>dfs.datanode.data.dir</name>
    <value>file:///var/lib/hadoop/hdfs/datanode</value>
  </property>
  <property>
    <name>dfs.namenode.rpc-address</name>
    <value>hadoop-master:8020</value>
  </property>
</configuration>
EOF

cat >"$HADOOP_HOME/etc/hadoop/mapred-site.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <property>
    <name>mapreduce.framework.name</name>
    <value>yarn</value>
  </property>
  <property>
    <name>mapreduce.map.memory.mb</name>
    <value>512</value>
  </property>
  <property>
    <name>mapreduce.reduce.memory.mb</name>
    <value>512</value>
  </property>
</configuration>
EOF

cat >"$HADOOP_HOME/etc/hadoop/yarn-site.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <property>
    <name>yarn.resourcemanager.hostname</name>
    <value>hadoop-master</value>
  </property>
  <property>
    <name>yarn.nodemanager.aux-services</name>
    <value>mapreduce_shuffle</value>
  </property>
  <property>
    <name>yarn.nodemanager.resource.memory-mb</name>
    <value>1024</value>
  </property>
  <property>
    <name>yarn.scheduler.maximum-allocation-mb</name>
    <value>1024</value>
  </property>
</configuration>
EOF

cat >"$HADOOP_HOME/etc/hadoop/workers" <<'EOF'
hadoop-worker1
hadoop-worker2
EOF

chown -R "$HADOOP_USER:$HADOOP_USER" "$HADOOP_HOME/etc/hadoop"
systemctl enable --now ssh

echo "Configured Hadoop ${HADOOP_VERSION} ${ROLE} node"
