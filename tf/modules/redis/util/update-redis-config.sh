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
cp /redis/redis.conf /redis-config/redis.conf
# $1 - sentinel nodes
echo "Finding master..."
CURRENT_FQDN_HOSTNAME=`hostname -f`
echo "Current hostname: ${CURRENT_FQDN_HOSTNAME}"
# https://linux.die.net/man/1/hostname
FQDN=`hostname -f | sed -e 's:dnc-redis-[0-9]\.:dnc-redis-0.:'`
echo "FQDN: $FQDN"
echo "Nodes: $1"
for node in $(echo $1 | sed -e "s:,: :g")
do
  echo "Sentinel: $node"
  # https://www.mankier.com/1/redis-cli
  if [ "$(redis-cli -h $node -p 26379 ping)" == "PONG" ]; then
    echo "Sentinel found, finding master..."
    MASTER_IP="$(redis-cli -h $node -p 26379 sentinel get-master-addr-by-name mymaster | \
                 grep -E '(^dnc-redis-*)|([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})')"
    HOSTNAME_IP=$(hostname -i)
    echo "Hostname: $HOSTNAME"
    echo "Hostname IP: $HOSTNAME_IP"
    echo "Master IP: $MASTER_IP"
    if [ ${HOSTNAME_IP} == ${MASTER_IP} ]; then
      echo "$HOSTNAME is the master..."
    else
      echo "Master found: $MASTER_IP, updating redis-master.conf"
      echo >> /redis-config/redis.conf
      echo "replicaof $MASTER_IP 6379" >> /redis-config/redis.conf
    fi
    exit 0
  fi
done
echo "Sentinel not found..."
echo "Master not found..."
if [ ${HOSTNAME} == "dnc-redis-0" ]; then
  echo "$HOSTNAME is the master..."
else
  # Ensure the key "replicaof" in the config file is commented out; it needs to be set dynamically!!!
  echo "$HOSTNAME is not the master; updating the config file..."
  echo >> /redis-config/redis.conf
  echo "replicaof $FQDN 6379" >> /redis-config/redis.conf
fi
