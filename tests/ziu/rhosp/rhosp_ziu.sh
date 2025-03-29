#!/bin/bash -e

export log_path='output/logs/ziu'

if [ ! -d $log_path ]; then
     mkdir -p $log_path
fi

exec 3>&1 1> >(tee ${log_path}/run.log) 2>&1

[ "${DEBUG,,}" == "true" ] && set -x

my_file="$(readlink -e "$0")"
my_dir="$(dirname "$my_file")"

source /tmp/test.env
[[ "$DEBUG" != true ]] || set -x

export CONTRAIL_NEW_IMAGE_TAG="$CONTRAIL_CONTAINER_TAG_ORIGINAL"
export SSH_OPTIONS=${SSH_OPTIONS:-"-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"}

function wait_cmd_success() {
    i=0
    while ! eval $3; do
        sleep $1
        printf "."
        i=$((i + 1))
        if (( i >= $2 )); then
            echo -e "\nERROR: wait failed in $((i*$1))s"
            return 1
        fi
    done
    echo -e "\nINFO: done in $((i*$1))s"
    return 0
}

function check_tf_active() {
    local machine
    local line=
    for machine in $(echo "$AGENT_NODES,$CONTROLLER_NODES" | sed "s/,/ /g"); do
        if ! ssh $SSH_OPTIONS $machine "command -v opensdn-status" 2>/dev/null ; then
            return 1
        fi
        for line in $(ssh $SSH_OPTIONS $machine "sudo opensdn-status" 2>/dev/null | egrep ": " | grep -v "WARNING" | awk '{print $2}'); do
            if [ "$line" != "active" ] && [ "$line" != "backup" ] ; then
                return 1
            fi
        done
    done
    return 0
}

if [ "$OPENSTACK_VERSION" == "queens" ]; then
    RHOSP_DIR="rhosp13_ziu"
elif [ "$OPENSTACK_VERSION" == "train" ]; then
    RHOSP_DIR="rhosp16_ziu"
fi

$my_dir/../../../rhosp/$RHOSP_DIR/run.sh

if ! wait_cmd_success 120 4 "check_tf_active" ; then
    echo "ERROR: tf is not active after ziu"
    exit 1
fi

