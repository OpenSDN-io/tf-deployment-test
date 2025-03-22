#!/bin/bash
# all deployers, k8s orchestrator smoke test

# Some deployers use k8s from home directory
PATH="$HOME:$PATH"

kubectl_cmd='kubectl'
if ! $kubectl_cmd get all ; then
  kubectl_cmd='sudo kubectl'
  if ! $kubectl_cmd get all ; then
    echo "ERROR: kubectl is not accessible by user and root. Test failed."
    exit 1
  fi
fi

function create_centos() {
  local pod_name=$1

  cat <<EOF | $kubectl_cmd apply -f -
apiVersion: v1
kind: Pod
metadata:
    name: $pod_name
spec:
    containers:
    - name: centos
      image: centos:7
      imagePullPolicy: IfNotPresent
      args:
      - sleep
      - infinity
EOF
}

function is_running() {
  local pod_name=$1
  [ $($kubectl_cmd get pod $pod_name -o jsonpath='{.status.phase}') == "Running" ]
}

function wait() {
  local check=$1
  local max_time=$2
  while [[ $max_time != 0 ]]; do
    if eval $check; then
      return 0
    fi
    sleep 1
    max_time=$((max_time-1))
  done
  return 1
}

function cleanup() {
  $kubectl_cmd delete pod pingtest-sender
  $kubectl_cmd delete pod pingtest-receiver
}

create_centos pingtest-sender
create_centos pingtest-receiver

if ! wait "is_running pingtest-sender && is_running pingtest-receiver" 60; then
  echo "ERROR: created pods are not in the running state"
  #cleanup
  exit 1
fi

receiver_ip=$($kubectl_cmd get pod pingtest-receiver -o jsonpath='{.status.podIP}')
if ! wait "$kubectl_cmd exec pingtest-sender -- ping $receiver_ip -c1 &>/dev/null" 30; then
  echo "ERROR: ping failed"
  #cleanup
  exit 1
fi

cleanup
