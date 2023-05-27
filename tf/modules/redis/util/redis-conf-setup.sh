#!/bin/bash
set +vx

# https://kubernetes.io/docs/tasks/debug/debug-application/debug-init-containers/
# kubectl get pod nginx --template '{{.status.initContainerStatuses}}'
# kubectl logs pod/dnc-redis-0 -c init-redis -n dot-net-core


# Copy the original config file so that it is unmodified for reuse; the copy will be modified as
# needed.
# cp /redis-config/redis.conf /redis-etc/redis.conf

# Ensure the key "replicaof" in the config file is commented out; it needs to be set dynamically!!!
# echo "Find the master..."
echo "Current hostname: `hostname -f`"
# https://linux.die.net/man/1/hostname
FQDN=`hostname -f | sed -e 's:dnc-redis-[0-9]\.:dnc-redis-0.:'`
echo "FQDN: $FQDN"
#
# Get the pod ordinal index.
[[ `hostname` =~ -([0-9]+)$ ]] || exit 1
ordinal=${BASH_REMATCH[1]}
echo "Ordinal=$ordinal..."
# $${ordinal} now holds the replica number
# echo "Got the ordinal number..."
# Copy appropriate conf file.
echo Hostname=$HOSTNAME
echo Hostname=`hostname -f`
echo Hostname=`hostname`
# FQDN=`hostname -f | sed -e 's/dnc-redis-[0-9]\./dnc-redis-0./'`
# echo "FQDN: $FQDN"
# echo "Current node: `hostname -f`"
# Copy the original config file so that it is unmodified for reuse; the copy will be modified as
# needed.
if [[ $ordinal -eq 0 ]]; then
  # cp /redis-config/master.conf /redis-etc/redis.conf
  cp /redis/redis.conf /redis-config/redis.conf
  echo "It is dnc-redis-0; do not update the config file..."
else
  # cp /redis-config/slave.conf /redis-etc/redis.conf
  cp /redis/redis.conf /redis-config/redis.conf
  echo "It is not dnc-redis-0; need to update the conf file..."
  echo >> /redis-config/redis.conf
  echo "replicaof $FQDN 6379" >> /redis-config/redis.conf
fi
