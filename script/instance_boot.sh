#!/bin/bash
# Redirect all outputs
exec > >(tee -i /tmp/cloud-init-bootstrap.log) 2>&1
set -xe

# Send signal to heat wait condition
# param:
#   $1 - status to send ("FAILURE" or "SUCCESS"
#   $2 - msg
function wait_condition_send() {
  local status=${1:-SUCCESS}
  local reason=${2:-empty}
  local data_binary="{\"status\": \"$status\", \"reason\": \"$reason\"}"
  echo "Sending signal to wait condition: $data_binary"
  $wait_condition_notify -k --data-binary "$data_binary"
  exit 1
}

# Add wrapper to apt-get to avoid race conditions
# with cron jobs running 'unattended-upgrades' script
aptget_wrapper() {
  local apt_wrapper_timeout=300
  local start_time=$(date '+%s')
  local fin_time=$((start_time + apt_wrapper_timeout))
  while true; do
    if (( "$(date '+%s')" > fin_time )); then
      msg="Timeout exceeded ${apt_wrapper_timeout} s. Lock files are still not released. Terminating..."
      wait_condition_send "FAILURE" "$msg"
    fi
    if fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || fuser /var/lib/dpkg/lock >/dev/null 2>&1; then
      echo "Waiting while another apt/dpkg process releases locks ..."
      sleep 30
      continue
    else
      apt-get $@
      break
    fi
  done
}

echo "Preparing base OS ..."
case "$node_os" in
    trusty)
        which wget > /dev/null || (aptget_wrapper update; aptget_wrapper install -y wget)

        echo "deb [arch=amd64] http://apt-mk.mirantis.com/trusty nightly salt extra" > /etc/apt/sources.list.d/mcp_salt.list
        wget -O - http://apt-mk.mirantis.com/public.gpg | apt-key add - || wait_condition_send "FAILURE" "Failed to add apt-mk key."

        echo "deb http://repo.saltstack.com/apt/ubuntu/14.04/amd64/2016.3 trusty main" > /etc/apt/sources.list.d/saltstack.list
        wget -O - https://repo.saltstack.com/apt/ubuntu/14.04/amd64/2016.3/SALTSTACK-GPG-KEY.pub | apt-key add - || wait_condition_send "FAILURE" "Failed to add salt apt key."

        aptget_wrapper clean
        aptget_wrapper update
        aptget_wrapper install -y salt-common
        aptget_wrapper install -y salt-minion
        ;;
    xenial)
        which wget > /dev/null || (aptget_wrapper update; aptget_wrapper install -y wget)

        echo "deb [arch=amd64] http://apt-mk.mirantis.com/xenial nightly salt extra" > /etc/apt/sources.list.d/mcp_salt.list
        wget -O - http://apt-mk.mirantis.com/public.gpg | apt-key add - || wait_condition_send "FAILURE" "Failed to add apt-mk key."

        echo "deb http://repo.saltstack.com/apt/ubuntu/16.04/amd64/2016.3 xenial main" > /etc/apt/sources.list.d/saltstack.list
        wget -O - https://repo.saltstack.com/apt/ubuntu/16.04/amd64/2016.3/SALTSTACK-GPG-KEY.pub | apt-key add - || wait_condition_send "FAILURE" "Failed to add saltstack apt key."

        aptget_wrapper clean
        aptget_wrapper update
        aptget_wrapper install -y salt-minion
        ;;
    *)
        msg="OS '$node_os' is not supported."
        wait_condition_send "FAILURE" "$msg"
esac

echo "Configuring Salt minion ..."
[ ! -d /etc/salt/minion.d ] && mkdir -p /etc/salt/minion.d
cat << "EOF" > /etc/salt/minion.d/minion.conf
id: $node_hostname.$node_domain
master: $config_host
EOF

service salt-minion restart || wait_condition_send "FAILURE" "Failed to restart salt-minion service."

$instance_cloud_init

sleep 1

echo "Classifying node ..."
node_ip=$(ip a | awk -F '[ \t\n]+|/' '($2 == "inet")  {print $3}' | grep -m 1 -v '127.0.0.1')
salt-call event.send 'reclass/minion/classify' "{'node_master_ip': '$config_host', 'node_ip': '${node_ip}', 'node_domain': '$node_domain', 'node_cluster': '$cluster_name', 'node_hostname': '$node_hostname', 'node_os': '$node_os'}"

wait_condition_send "SUCCESS" "Instance successfuly started."