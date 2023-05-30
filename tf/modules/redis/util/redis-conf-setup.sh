#!/bin/bash
set +vx

# https://kubernetes.io/docs/tasks/debug/debug-application/debug-init-containers/
# kubectl get pod nginx --template '{{.status.initContainerStatuses}}'
# kubectl logs pod/dnc-redis-0 -c init-redis -n dot-net-core


# Copy the original config file so that it is unmodified for reuse; the copy will be modified as
# needed.
cp /redis/redis.conf /redis-config/redis.conf
echo "Finding master..."
echo "Current hostname: `hostname -f`"
# https://linux.die.net/man/1/hostname
FQDN=`hostname -f | sed -e 's:dnc-redis-[0-9]\.:dnc-redis-0.:'`
echo "FQDN: $FQDN"
# https://www.mankier.com/1/redis-cli
# if [ "$(timeout 5 redis-cli -h sentinel -p 5000 -a ${REDIS_PASSWORD} ping)" != "PONG" ]; then
if [ "$(redis-cli -h sentinel -p 5000 ping)" != "PONG" ]; then
  echo "Sentinel not found..."
  if [ ${HOSTNAME} == "dnc-redis-0" ]; then
    echo "$HOSTNAME; not updating config..."
  else
    # Ensure the key "replicaof" in the config file is commented out; it needs to be set dynamically!!!
    echo "$HOSTNAME; updating the config file..."
    cp /redis/redis.conf /redis-config/redis.conf
    echo >> /redis-config/redis.conf
    # echo "repl-ping-replica-period 3" >> /redis-config/redis.conf
    # echo "slave-read-only no" >> /redis-config/redis.conf
    echo "replicaof $FQDN 6379" >> /redis-config/redis.conf
  fi
else
  echo "Sentinel found, finding master..."
  # MASTER="$(redis-cli -h sentinel -p 5000 -a ${REDIS_PASSWORD} sentinel get-master-addr-by-name mymaster | grep -E '(^redis-*)|([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})')"
  MASTER="$(sentinel get-master-addr-by-name mymaster | grep -E '(^dnc-redis-*)|([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})')"
  if [ "${HOSTNAME}" == ${MASTER} ]; then
    echo "This is master, not updating config..."
  else
    echo "Master found: ${MASTER}, updating redis.conf"
    echo >> /redis-config/redis.conf
    # echo "repl-ping-replica-period 3" >> /redis-config/redis.conf
    # echo "slave-read-only no" >> /redis-config/redis.conf
    echo "replicaof $MASTER 6379" >> /redis-config/redis.conf
  fi
fi
