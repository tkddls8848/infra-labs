# Hadoop Ubuntu Vagrant

Minimal personal Hadoop test cluster.

| Node | Role | Spec |
| --- | --- | --- |
| `hadoop-master` | NameNode, ResourceManager | 2 vCPU, 2 GB |
| `hadoop-worker1` | DataNode, NodeManager | 1 vCPU, 1.5 GB |
| `hadoop-worker2` | DataNode, NodeManager | 1 vCPU, 1.5 GB |

Stack: Ubuntu 24.04, OpenJDK 17, Apache Hadoop 3.5.0.

## Run

```bash
vagrant up
```

UIs:

- HDFS: http://localhost:9870
- YARN: http://localhost:8088

## Smoke test

```bash
vagrant ssh hadoop-master
sudo -iu hadoop
hdfs dfs -put $HADOOP_HOME/etc/hadoop/*.xml /tmp/
hadoop jar $HADOOP_HOME/share/hadoop/mapreduce/hadoop-mapreduce-examples-*.jar grep /tmp /tmp/grep-out 'dfs[a-z.]+'
hdfs dfs -cat /tmp/grep-out/*
```

## Stop

```bash
vagrant halt
```

Destroy:

```bash
vagrant destroy -f
```
