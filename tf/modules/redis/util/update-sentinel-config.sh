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
# $1 - redis nodes.
echo "Nodes: $1"
for node in $(echo $1 | sed -e "s:,: :g")
do
  echo "Finding master at $node"
  echo "***---***"
  echo "$(redis-cli --no-auth-warning --raw -h $node info replication)"
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

# Older versions of Sentinel did not support host names and required IP addresses to be specified
# everywhere. Starting with version 6.2, Sentinel has optional support for host names. This
# capability is disabled by default. To enable this capability, add "sentinel resolve-hostnames yes"
# to the sentinel.conf file.
#
# Overwrite the /sentinel-config/sentinel.conf file.
echo "port 26379
sentinel resolve-hostnames yes
sentinel monitor mymaster $MASTER 6379 2
sentinel down-after-milliseconds mymaster 5000
sentinel failover-timeout mymaster 60000
sentinel parallel-syncs mymaster 1
protected-mode no
" > /sentinel-config/sentinel.conf
cat /sentinel-config/sentinel.conf
