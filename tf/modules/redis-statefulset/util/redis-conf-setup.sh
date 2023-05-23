#!/bin/bash
# https://kubernetes.io/docs/tasks/debug/debug-application/debug-init-containers/
# kubectl get pod nginx --template '{{.status.initContainerStatuses}}'
#  kubectl logs pod/dnc-redis-0 -c init-redis -n dot-net-core
set -ex
# Get the pod ordinal index.
[[ `hostname` =~ -([0-9]+)$ ]] || exit 1
ordinal=${BASH_REMATCH[1]}
echo "Ordinal=$ordinal..."
# $${ordinal} now holds the replica number
# echo "Got the ordinal number..."
# Copy appropriate conf file.
echo "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF555555555555555555inding master..."
if [[ $ordinal -eq 0 ]]; then
  cp /redis-config/master.conf /redis-etc/redis.conf
else
  cp /redis-config/slave.conf /redis-etc/redis.conf
fi
