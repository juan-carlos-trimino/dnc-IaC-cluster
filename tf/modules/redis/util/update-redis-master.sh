#!/bin/sh
set +vx
#
# Redis connects to Sentinel and checks whether it is the master or not; update the config file as
# appropriate.
#
# This script runs in the init container, see
# https://kubernetes.io/docs/tasks/debug/debug-application/debug-init-containers/ for debugging tips.
# kubectl logs dnc-redis-0 -c init-redis -n dot-net-core
#
# Copy the original config file so that it is unmodified for reuse; the copy will be modified as
# needed.
# The redis-master.conf file is used by Redis.
cp /redis/redis-master.conf /redis-config/redis-master.conf
# $1 - password
# $2 - sentinel nodes
echo >> /redis-config/redis-master.conf
echo "requirepass $1" >> /redis-config/redis-master.conf
echo "masterauth $1" >> /redis-config/redis-master.conf
CURRENT_FQDN_HOSTNAME=`hostname -f`
echo "Finding master..."
echo "Current hostname: ${CURRENT_FQDN_HOSTNAME}"
# https://linux.die.net/man/1/hostname
FQDN=`hostname -f | sed -e 's:dnc-redis-[0-9]\.:dnc-redis-0.:'`
echo "FQDN: $FQDN"
echo "Nodes: $2"
#
for node in $(echo $2 | sed -e "s:,: :g")
do
  echo "Sentinel: $node"
  # https://www.mankier.com/1/redis-cli
  if [ "$(timeout 5 redis-cli -h $node -p 5000 ping)" == "PONG" ]; then
    echo "Sentinel found, finding master..."
    MASTER="$(redis-cli -h $node -p 5000 sentinel get-master-addr-by-name mymaster | \
           grep -E '(^dnc-redis-*)|([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})')"
    HOSTNAME_IP=$(hostname -i)
    echo "Hostname IP: $HOSTNAME_IP"
    echo "Master: $MASTER"
    echo "${HOSTNAME}.dnc-redis-headless.dot-net-core"
    # if [ "${HOSTNAME}.dnc-redis-headless.dot-net-core" == ${MASTER} ]; then
    if [ ${HOSTNAME_IP} == ${MASTER} ]; then
      echo "This is master..."
    else
      echo "Master found: $MASTER, updating redis-master.conf"
      echo >> /redis-config/redis-master.conf
      echo "replicaof $MASTER 6379" >> /redis-config/redis-master.conf
    fi
    exit 0
  fi
done
echo "Sentinel not found..."
if [ ${HOSTNAME} == "dnc-redis-0" ]; then
  echo "$HOSTNAME is the master..."
else
  # Ensure the key "replicaof" in the config file is commented out; it needs to be set dynamically!!!
  echo "$HOSTNAME is not the master; updating the config file..."
  echo >> /redis-config/redis-master.conf
  echo "replicaof $FQDN 6379" >> /redis-config/redis-master.conf
fi
