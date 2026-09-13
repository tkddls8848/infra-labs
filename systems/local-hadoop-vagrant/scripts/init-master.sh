#!/usr/bin/env bash
set -euo pipefail

HADOOP_VERSION="${1:-3.5.0}"
HADOOP_HOME="/opt/hadoop"
HADOOP_USER="hadoop"

run_hadoop() {
  runuser -l "$HADOOP_USER" -c "export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64 HADOOP_HOME=$HADOOP_HOME HADOOP_CONF_DIR=$HADOOP_HOME/etc/hadoop PATH=\$PATH:$HADOOP_HOME/bin:$HADOOP_HOME/sbin; $*"
}

if [[ ! -f /var/lib/hadoop/hdfs/namenode/current/VERSION ]]; then
  run_hadoop "hdfs namenode -format -force -nonInteractive"
fi

run_hadoop "stop-yarn.sh >/dev/null 2>&1 || true"
run_hadoop "stop-dfs.sh >/dev/null 2>&1 || true"
run_hadoop "start-dfs.sh"
run_hadoop "start-yarn.sh"

run_hadoop "hdfs dfs -mkdir -p /tmp /user/hadoop"
run_hadoop "hdfs dfs -chmod 1777 /tmp"

echo "Hadoop ${HADOOP_VERSION} cluster is running"
echo "HDFS UI: http://192.168.70.10:9870 or http://localhost:9870"
echo "YARN UI: http://192.168.70.10:8088 or http://localhost:8088"
