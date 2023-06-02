#!/bin/sh
set +vx
#
# Sentinel searches for the Redis master pod by looping thru the REDIS_NODES, an environment
# variable that is passed to the script. Update the config file as appropriate.
#
# This script runs in the init container, see
# https://kubernetes.io/docs/tasks/debug/debug-application/debug-init-containers/ for debugging tips.
# kubectl logs dnc-redis-0 -c init-redis -n dot-net-core
#
# $1 - password.
# $2 - redis nodes.
echo "Nodes: $2"
for node in $(echo $2 | sed -e "s:,: :g")
do
  echo "Finding master at $node"
  echo "***---***"
  echo "$(redis-cli --no-auth-warning --raw -h $node -a $1 info replication)"
  echo "***---***"
  # Obtain information about the node | Skip the 1st line and print 1st column of every subsequent
  # line | Return the line with role:xxxx | Return the second field separate by ":"; e.g.,
  # role:slave will return slave
  ROLE=$(redis-cli --no-auth-warning --raw -h $node -a $REDIS_PASSWORD info replication | \
         awk '{print $1}' | grep role: | cut -d ":" -f2)
  MASTER=$node
  echo "Node: $node"
  echo "Role: $ROLE"
  if [ "$ROLE" = "master" ]; then
    echo "Master found."
    echo ""
    break;
  else
    echo "Master not found."
    echo ""
  fi
done
# FQDN_HOSTNAME=`hostname -f`
# Only Sentinel Version 6.2+ can resolve host names, but it is not enabled by default. To enable
# this feature, add "sentinel resolve-hostnames yes" to the sentinel.conf file.
#
# Overwrite the /sentinel-config/sentinel.conf file.
echo "port 5000
sentinel resolve-hostnames yes
sentinel monitor mymaster $MASTER 6379 2
sentinel down-after-milliseconds mymaster 1000
sentinel failover-timeout mymaster 10000
sentinel auth-pass mymaster $1
protected-mode no
" > /sentinel-config/sentinel.conf
cat /sentinel-config/sentinel.conf
