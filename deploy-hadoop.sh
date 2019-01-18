#!/bin/bash
set -ex


CENTOS_VERSION="7"
if [ -z $HDP_VERSION ]; then
  HDP_VERSION="3.0.1"
fi
# Prompt users for info to create nodes

prelim(){
  read -p "Number of Nodes: " nnode
  read -p "Cluster Name: " clustname
  read -p "Cluster Prefix [hdp]: " prefix

  if [  -z $prefix ]; then
     prefix="hdp"
  fi
  NODES=""
  for ((i=0; i< $nnode; i++)) ;
  do
     #node=hdp-$clustname-$i
     NODES="$NODES ${prefix}-${clustname}-${i}"
  done
  echo "NODES='$NODES'" > ~/.$clustname
  cat ~/.$clustname
}


mkdirs(){
for host in $NODES; do
   if [ $(lxc list $host | grep -c ${host} ) -gt 0 ]; then
      lxc delete $host --force ;
   fi
done
  for dir in scripts ssh apps conf; do mkdir -p /tmp/$dir; done
}

launchContainers(){
for host in $NODES; do
    if [ $(lxc list | grep ${host} -c ) -gt 0 ]; then
        echo "$host is already launched. Skipping .."
    else
      lxc launch images:centos/$CENTOS_VERSION/amd64 $host
    fi
done
export HDFS_PATH="/home/hadoop/hdfs"
sleep 10

}


installUpdates(){

for hosts in $NODES
do
lxc exec $hosts -- yum update -y
lxc exec $hosts -- yum install -y java-1.8.0-openjdk  java-1.8.0-openjdk-devel sshd openssh-server wget curl epel-release less which
done

}

getHadoop(){
if [ ! -e /tmp/apps/hadoop-${HDP_VERSION}.tar.gz ]; then
  wget  http://apache.claz.org/hadoop/common/hadoop-${HDP_VERSION}/hadoop-${HDP_VERSION}.tar.gz -O /tmp/apps/hadoop-${HDP_VERSION}.tar.gz
fi
sleep 2

for host in $NODES; do
        lxc file push /tmp/apps/hadoop-${HDP_VERSION}.tar.gz ${host}/usr/local/hadoop-${HDP_VERSION}.tar.gz
        lxc exec ${host} -- tar xf /usr/local/hadoop-${HDP_VERSION}.tar.gz -C /usr/local/
        lxc exec ${host} -- rm -rf /usr/local/hadoop/
        lxc exec ${host} -- mv /usr/local/hadoop-${HDP_VERSION} /usr/local/hadoop
done
}


createScripts(){

cat > /tmp/scripts/setup-user.sh << EOF
export JAVA_HOME="/usr/lib/jvm/jre-1.8.0-openjdk"
export PATH="\$PATH:\$JAVA_HOME/bin"
useradd -m -s /bin/bash -G wheel hadoop
echo "hadoop:hadoop" | /usr/sbin/chpasswd
su -c "ssh-keygen -q -t rsa -f /home/hadoop/.ssh/id_rsa -N ''" hadoop
su -c "cat /home/hadoop/.ssh/id_rsa.pub >> /home/hadoop/.ssh/authorized_keys" hadoop
su -c "mkdir -p /home/hadoop/hdfs/{namenode,datanode}" hadoop
su -c "chown -R hadoop:hadoop /home/hadoop" hadoop
EOF

echo "127.0.0.1 localhost" > /tmp/scripts/hosts
> /tmp/scripts/ssh.sh
for host in $NODES; do
        IP=$(lxc list ${host}| grep RUNNING | awk '{print $6}')
        echo "$IP   $host" >> /tmp/scripts/hosts
    echo "su - hadoop -c \"ssh -o 'StrictHostKeyChecking no' ${host} 'echo 1 > /dev/null'\" hadoop" >> /tmp/scripts/ssh.sh
done

cat > /tmp/scripts/set_env.sh << EOF
# Source global definitions
if [ -f /etc/bashrc ]; then
        . /etc/bashrc
fi

# Uncomment the following line if you don't like systemctl's auto-paging feature:
# export SYSTEMD_PAGER=


export JAVA_HOME=/usr/lib/jvm/jre-1.8.0-openjdk
export HADOOP_HOME=/usr/local/hadoop
export HADOOP_CONF_DIR=\$HADOOP_HOME/etc/hadoop
export HADOOP_MAPRED_HOME=\$HADOOP_HOME
export HADOOP_COMMON_HOME=\$HADOOP_HOME
export HADOOP_HDFS_HOME=\$HADOOP_HOME
export YARN_HOME=\$HADOOP_HOME
export PATH=\$PATH:\$JAVA_HOME/bin:\$HADOOP_HOME/sbin:\$HADOOP_HOME/bin
EOF

# generate hadoop/slave files
echo "hdp-$clustname-0" > /tmp/conf/masters
> /tmp/conf/slaves

for host in $(echo $NODES | sed 's/hdp-$clustname-0//g'); do
echo ${host} >> /tmp/conf/slaves
done

cat > /tmp/scripts/source.sh << EOF
#!/bin/bash
export JAVA_HOME=/usr/lib/jvm/jre-1.8.0-openjdk
export HADOOP_HOME=/usr/local/hadoop
export HADOOP_CONF_DIR=\$HADOOP_HOME/etc/hadoop
export HADOOP_MAPRED_HOME=\$HADOOP_HOME
export HADOOP_COMMON_HOME=\$HADOOP_HOME
export HADOOP_HDFS_HOME=\$HADOOP_HOME
export YARN_HOME=\$HADOOP_HOME
export PATH=\$PATH:\$JAVA_HOME/bin:\$HADOOP_HOME/sbin:\$HADOOP_HOME/bin

cat /root/set_env.sh > /home/hadoop/.bashrc
chown -R hadoop:hadoop /home/hadoop/
su - hadoop -c "source /home/hadoop/.bashrc" hadoop
EOF

cat > /tmp/scripts/start-hadoop.sh << EOF
#!/bin/bash
export JAVA_HOME=/usr/lib/jvm/jre-1.8.0-openjdk
export HADOOP_HOME=/usr/local/hadoop
export HADOOP_CONF_DIR=\$HADOOP_HOME/etc/hadoop
export HADOOP_MAPRED_HOME=\$HADOOP_HOME
export HADOOP_COMMON_HOME=\$HADOOP_HOME
export HADOOP_HDFS_HOME=\$HADOOP_HOME
export YARN_HOME=\$HADOOP_HOME
export PATH=\$PATH:\$JAVA_HOME/bin:\$HADOOP_HOME/sbin:\$HADOOP_HOME/bin
EOF

echo 'sed -i "s/export JAVA_HOME=\${JAVA_HOME}/export JAVA_HOME=\/usr\/lib\/jvm\/jre-1.8.0-openjdk/g" /usr/local/hadoop/etc/hadoop/hadoop-env.sh' > /tmp/scripts/update-java-home.sh
echo 'chown -R hadoop:hadoop /usr/local/hadoop' >> /tmp/scripts/update-java-home.sh

echo 'echo "Executing: hadoop namenode -format: "' > /tmp/scripts/initial_setup.sh
echo 'sleep 2' >> /tmp/scripts/initial_setup.sh
echo 'hadoop namenode -format' >> /tmp/scripts/initial_setup.sh
echo 'echo "Executing: start-dfs.sh"' >> /tmp/scripts/initial_setup.sh
echo 'sleep 2' >> /tmp/scripts/initial_setup.sh
echo 'start-dfs.sh' >> /tmp/scripts/initial_setup.sh
echo 'echo "Executing: start-yarn.sh"' >> /tmp/scripts/initial_setup.sh
echo 'sleep 2' >> /tmp/scripts/initial_setup.sh
echo 'start-yarn.sh' >> /tmp/scripts/initial_setup.sh
echo "sed -i 's/bash \/home\/hadoop\/initial_setup.sh//g' /home/hadoop/.bashrc" >> /tmp/scripts/initial_setup.sh

}

generateHadoopConfig(){
  # hadoop configuration
#echo "<configuration>\n  <property>\n    <name>fs.defaultFS</name>\n     <value>hdfs://$N1:8020/</value>\n  </property>\n</configuration>" > /tmp/conf/core-site.xml

cat >  /tmp/conf/core-site.xml << EOF
<configuration>
  <property>
    <name>fs.defaultFS</name>
    <value>hdfs://hdp-${clustname}-0:8020/</value>
  </property>
</configuration>
EOF

#echo "<configuration>\n  <property>\n    <name>dfs.namenode.name.dir</name>\n    <value>file:$HDFS_PATH/namenode</value>\n  </property>\n  <property>\n    <name>dfs.datanode.data.dir</name>\n    <value>file:$HDFS_PATH/datanode</value>\n  </property>\n  <property>\n    <name>dfs.replication</name>\n    <value>${REPFACTOR}</value>\n  </property>\n  <property>\n    <name>dfs.block.size</name>\n    <value>134217728</value>\n  </property>\n  <property>\n    <name>dfs.namenode.datanode.registration.ip-hostname-check</name>\n    <value>false</value>\n  </property>\n</configuration>" > /tmp/conf/hdfs-site.xml

cat > /tmp/conf/hdfs-site.xml << EOF
<configuration>
  <property>
    <name>dfs.namenode.name.dir</name>
    <value>file:$HDFS_PATH/namenode</value>
  </property>
  <property>
    <name>dfs.datanode.data.dir</name>
    <value>file:$HDFS_PATH/datanode</value>
  </property>
  <property>
    <name>dfs.replication</name>
    <value>$((nnode - 1))</value>
    </property>
  <property>
    <name>dfs.block.size</name>
    <value>134217728</value>
  </property>\n  <property>
    <name>dfs.namenode.datanode.registration.ip-hostname-check</name>
    <value>false</value>
  </property>
</configuration>
EOF



cat > /tmp/conf/mapred-site.xml << EOF
<configuration>
  <property>
    <name>mapreduce.framework.name</name>
    <value>yarn</value>
  </property>
  <property>
    <name>mapreduce.jobhistory.address</name>
    <value>hdp-${clustname}-0:10020</value>
  </property>
  <property>
    <name>mapreduce.jobhistory.webapp.address</name>
    <value>hdp-${clustname}-0:19888</value>
  </property>
  <property>
    <name>mapred.child.java.opts</name>
    <value>-Djava.security.egd=file:/dev/../dev/urandom</value>
  </property>
</configuration>
EOF

cat > /tmp/conf/yarn-site.xml << EOF
<configuration>
  <property>
    <name>yarn.resourcemanager.hostname</name>
    <value>hdp-${clustname}-0</value>
  </property>
  <property>
    <name>yarn.resourcemanager.bind-host</name>
    <value>0.0.0.0</value>
  </property>
  <property>
    <name>yarn.nodemanager.bind-host</name>
    <value>0.0.0.0</value>
  </property>
  <property>
    <name>yarn.nodemanager.aux-services</name>
    <value>mapreduce_shuffle</value>
  </property>
  <property>
    <name>yarn.nodemanager.aux-services.mapreduce_shuffle.class</name>
    <value>org.apache.hadoop.mapred.ShuffleHandler</value>
  </property>
  <property>
    <name>yarn.nodemanager.remote-app-log-dir</name>
    <value>hdfs://hdp-${clustname}-0:8020/var/log/hadoop-yarn/apps</value>
  </property>
</configuration>
EOF
}

moveScripts(){
for host in $NODES; do
     lxc file push /tmp/scripts/hosts ${host}/etc/hosts
     lxc file push /tmp/scripts/setup-user.sh ${host}/root/setup-user.sh
     lxc file push /tmp/scripts/set_env.sh ${host}/root/set_env.sh
     lxc file push /tmp/scripts/source.sh ${host}/root/source.sh
     lxc file push /tmp/scripts/ssh.sh ${host}/root/ssh.sh
     lxc file push /tmp/scripts/update-java-home.sh ${host}/root/update-java-home.sh
done
lxc file push /tmp/scripts/ssh.sh hdp-${clustname}-0/root/ssh.sh

}

moveHadoopConfs(){
for host in $NODES; do
        lxc file push /tmp/conf/masters ${host}/usr/local/hadoop/etc/hadoop/masters
        lxc file push /tmp/conf/slaves ${host}/usr/local/hadoop/etc/hadoop/slaves
        lxc file push /tmp/conf/core-site.xml ${host}/usr/local/hadoop/etc/hadoop/core-site.xml
        lxc file push /tmp/conf/hdfs-site.xml ${host}/usr/local/hadoop/etc/hadoop/hdfs-site.xml
        lxc file push /tmp/conf/mapred-site.xml ${host}/usr/local/hadoop/etc/hadoop/mapred-site.xml
        lxc file push /tmp/conf/yarn-site.xml ${host}/usr/local/hadoop/etc/hadoop/yarn-site.xml
done
}

setupUsers(){
for host in $NODES; do
        lxc exec ${host} -- bash /root/setup-user.sh
        lxc exec ${host} -- systemctl start sshd
        lxc exec ${host} -- chown -R hadoop:hadoop /usr/local/hadoop
done
}

configureSSH(){
for ctrs in $NODES; do
   lxc exec $ctrs -- sed -i "s/PasswordAuthentication no/PasswordAuthentication yes/g" /etc/ssh/sshd_config
   lxc exec $ctrs -- /usr/bin/systemctl restart sshd
done
}

setupPasswordlessSSH(){
echo "" > /tmp/authorized_keys

for host in $NODES; do
    lxc file pull ${host}/home/hadoop/.ssh/id_rsa.pub /tmp/ssh/id_rsa_${host}.pub
    cat /tmp/ssh/id_rsa_${host}.pub >> /tmp/authorized_keys
done

for host in $NODES; do
    lxc file push /tmp/authorized_keys ${host}/home/hadoop/.ssh/authorized_keys
    lxc exec ${host} -- chown hadoop:hadoop /home/hadoop/.ssh/authorized_keys
    lxc exec ${host} -- chmod 600 /home/hadoop/.ssh/authorized_keys
done
}

ensureSSH(){
for host in $NODES; do
        lxc exec ${host} -- bash /root/ssh.sh
done
}

moveInitialScript(){
lxc file push /tmp/scripts/initial_setup.sh hdp-${clustname}-0/home/hadoop/initial_setup.sh
lxc exec hdp-${clustname}-0 -- chown hadoop:hadoop /home/hadoop/initial_setup.sh
lxc exec hdp-${clustname}-0 -- chmod +x /home/hadoop/initial_setup.sh
}

updateJavaHome(){
for host in $NODES; do
        lxc exec ${host} -- bash /root/update-java-home.sh
done
}

executeScripts(){

for host in $NODES; do
        lxc exec ${host} -- bash /root/source.sh
        lxc exec ${host} -- chown -R hadoop:hadoop /usr/local/hadoop
done
}

startHadoop(){
  lxc exec hdp-${clustname}-0 -- JAVA_HOME=/usr/lib/jvm/jre-1.8.0-openjdk bash /root/start-hadoop.sh
}

printInstructions(){
echo "Deployment Done"
echo "---------------"
echo ""
echo "1. Access Master:"
echo " $ lxc exec hdp-${clustname}-0 bash"
echo ""
echo "2. Switch user to hadoop:"
echo " $ su hadoop"
echo ""
echo "With the inital login namenode will be formatted and hadoop"
echo "daemons will be started."
}

prelim
mkdirs
launchContainers
installUpdates
createScripts
getHadoop
moveScripts
generateHadoopConfig
moveHadoopConfs
setupUsers
setupPasswordlessSSH
ensureSSH
moveInitialScript
executeScripts
updateJavaHome
startHadoop
printInstructions
