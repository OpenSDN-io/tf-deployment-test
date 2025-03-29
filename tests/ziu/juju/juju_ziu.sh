#!/bin/bash -e
my_file="$(readlink -e "$0")"
my_dir="$(dirname "$my_file")"

export PATH=$PATH:/snap/bin
source /tmp/test.env

export CONTAINER_REGISTRY="$CONTAINER_REGISTRY_ORIGINAL"
export CONTRAIL_CONTAINER_TAG="$CONTRAIL_CONTAINER_TAG_ORIGINAL"
export DEPLOYER_CONTAINER_REGISTRY="$DEPLOYER_CONTAINER_REGISTRY_ORIGINAL"
export CONTRAIL_DEPLOYER_CONTAINER_TAG="$CONTRAIL_DEPLOYER_CONTAINER_TAG_ORIGINAL"
export SSH_OPTIONS=${SSH_OPTIONS:-"-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"}

function ziu_status_for_pattern() {
    # juju 2.9.0 started to return similar messages in applications as in units - cut app section first
    if [[ $(juju status | grep -A 2000 "Unit *Workload" | grep "$1" | wc -l) != "$2" ]]; then
        return 1
    fi
    return 0
}

function juju_status_absent_pattern() {
    # juju 2.9.0 started to return similar messages in applications as in units - cut app section first
    # remove docker app/units from output - in case of hybrid env it's always in maintenance state
    if juju status | grep -A 2000 "Unit *Workload" | grep -v "docker" | grep -q "$1" ; then
        return 1
    fi
    return 0
}

function fetch_deployer() {
    # pull deployer src container locally and extract files to path
    # Functions get two required params:
    #  - deployer image
    #  - directory path deployer have to be extracted to
    if [[ $# != 2 ]] ; then
        echo "ERROR: Deployer image name and path to deployer directory are required for fetch_deployer"
        return 1
    fi

    local deployer_image=$1
    local deployer_dir=$2

    sudo rm -rf $deployer_dir

    local image="$DEPLOYER_CONTAINER_REGISTRY/$deployer_image"
    [ -n "$CONTRAIL_DEPLOYER_CONTAINER_TAG" ] && image+=":$CONTRAIL_DEPLOYER_CONTAINER_TAG"
    if which docker >/dev/null 2>&1 ; then
        sudo docker create --name $deployer_image --entrypoint /bin/true $image || return 1
        sudo docker cp $deployer_image:/src $deployer_dir
        sudo docker rm -fv $deployer_image
    elif which ctr >/dev/null 2>&1 ; then
        sudo ctr -n k8s.io container create $image $deployer_image || return 1
        mkdir /tmp/$deployer_image_$RANDOM
        sudo ctr -n k8s.io snapshot mounts /tmp/$deployer_image_$RANDOM $deployer_image | xargs sudo
        cp /tmp/$deployer_image_$RANDOM/src $deployer_dir
        sudo ctr -n k8s.io container rm $deployer_image
    fi
    sudo chown -R $UID $deployer_dir
}

function get_start_times() {
    local service=$1
    local container_name=$2

    local start_times=""
    local unit_list=$(echo "$juju_status" | grep $service/ | awk '{print $1}' | sed 's/*//g')
    for unit in $unit_list ; do
        start_times+=" ${unit}: "
        start_times+=$(juju ssh $unit "sudo docker inspect $container_name" | jq '.[0]["State"]["StartedAt"]')
    done

    echo $start_times
}

function wait_cmd_success() {
    local i=0
    while ! eval $3; do
        sleep $1
        printf "."
        i=$((i + 1))
        if (( i >= $2 )); then
            echo ''
            echo "ERROR: wait failed in $((i*$1))s"
            return 1
        fi
    done
    echo ''
    echo "INFO: done in $((i*$1))s"
    return 0
}

function sync_time() {
    local machine
    for machine in $(echo "$CONTROLLER_NODES $AGENT_NODES" | tr " " "\n" | sort -u) ; do
        scp $SSH_OPTIONS ${my_dir}/../../../common/scripts/sync_time.sh $SSH_USER@$machine:/tmp/sync_time.sh
        ssh $SSH_OPTIONS $SSH_USER@$machine /tmp/sync_time.sh
    done
}

echo "INFO: current env  $(date)"
env|sort
echo ''

juju_status=$(juju status)

cc=$(echo "$juju_status" | awk '/contrail-controller /{print $4}')
ac=$(echo "$juju_status" | awk '/contrail-analytics /{print $4}')
adbc=0
if echo "$juju_status" | grep -q "contrail-analyticsdb " ; then
    adbc=$(echo "$juju_status" | awk '/contrail-analyticsdb /{print $4}')
fi
kmc=0
if echo "$juju_status" | grep -q "contrail-kubernetes-master " ; then
    kmc=$(echo "$juju_status" | awk '/contrail-kubernetes-master /{print $4}')
fi
units_count=$((ac + adbc + cc + kmc))
echo "INFO: Count of units in control plane = $units_count. Start ZIU...  $(date)"

# load last charms
tf_charms_src_image=${TF_CHARMS_SRC:-"opensdn-charms-src"}
tf_charms_dir=${TF_CHARMS_DIR:-"${HOME}/tf-charms"}
charms_to_upgrade="analytics analyticsdb controller agent keystone-auth kubernetes-node openstack"

pushd $tf_charms_dir
echo "INFO: charms branch"
git branch -a -vv
popd
fetch_deployer $tf_charms_src_image $tf_charms_dir
pushd $tf_charms_dir
echo "INFO: charms branch"
git branch -a -vv
popd

# upgrade kubernetes-master
# now it should be upgraded before ziu start, R2011 charm do not have ziu info in config
# TODO: try to fix it
if echo "$juju_status" | grep -q "tf-kubernetes-master " ; then
    juju upgrade-charm tf-kubernetes-master --path $tf_charms_dir/contrail-kubernetes-master
fi
sleep 30

juju run-action tf-controller/leader upgrade-ziu

# wait for all charms get ziu
sleep 60

agent_start_times=$(get_start_times tf-agent vrouter_vrouter-agent_1)
control_start_times=$(get_start_times tf-controller control_control_1)

for charm in $charms_to_upgrade ; do
    if echo "$juju_status" | grep -q "tf-$charm " ; then
        juju upgrade-charm tf-$charm --path $tf_charms_dir/contrail-$charm
    fi
done

# wait for all charms are finished upgrade
sleep 60

# check that agent and control were not restarted
if [[ $agent_start_times != $(get_start_times tf-agent vrouter_vrouter-agent_1) ]] ; then
    echo "ERROR: some of agent containers were restarted"
    exit 1
fi

if [[ $control_start_times != $(get_start_times tf-controller control_control_1) ]] ; then
    echo "ERROR: some of control containers were restarted"
    exit 1
fi
echo "INFO: Agent and control containers were not restarted"

if ! wait_cmd_success 10 60 "ziu_status_for_pattern \"ziu is in progress - stage\/done = 0\/None\" $units_count" ; then
    echo "ERROR: ziu have not started"
    exit 1
fi

echo "INFO: required units are in maintenance state. Update image tags...  $(date)"

juju config tf-analytics image-tag=$CONTRAIL_CONTAINER_TAG docker-registry=$CONTAINER_REGISTRY
if [[ $adbc != '0' ]]; then
    juju config tf-analyticsdb image-tag=$CONTRAIL_CONTAINER_TAG docker-registry=$CONTAINER_REGISTRY
fi
juju config tf-agent image-tag=$CONTRAIL_CONTAINER_TAG docker-registry=$CONTAINER_REGISTRY
juju config tf-openstack image-tag=$CONTRAIL_CONTAINER_TAG docker-registry=$CONTAINER_REGISTRY
if [[ $kmc != '0' ]]; then
    juju config tf-kubernetes-master image-tag=$CONTRAIL_CONTAINER_TAG docker-registry=$CONTAINER_REGISTRY
    juju config tf-kubernetes-node image-tag=$CONTRAIL_CONTAINER_TAG docker-registry=$CONTAINER_REGISTRY
fi
# controller must last - it starts ZIU with this event
juju config tf-controller image-tag=$CONTRAIL_CONTAINER_TAG docker-registry=$CONTAINER_REGISTRY

echo "INFO: wait for control plane done  $(date)"

if ! wait_cmd_success 20 540 "ziu_status_for_pattern \"ziu is in progress - stage\/done = 5\/5\" $units_count" ; then
    echo "ERROR: ziu've got an error before stage 5"
    exit 1
fi
# wait a bit when all agents consume stage 5
sleep 60

echo "INFO: Control plane is done. Run upgrade for agents...  $(date)"

for agent in $(juju status | grep -o "tf-agent/[0-9]*"); do
    juju run-action --wait $agent upgrade
done

if ! wait_cmd_success 20 40 "juju_status_absent_pattern ziu" ; then
    echo "ERROR: ziu haven't finished"
    exit 1
fi

echo "INFO: agents are ready. Sync time and wait for active state  $(date)"

sync_time

if ! wait_cmd_success 60 40 "juju_status_absent_pattern \"waiting\|blocked\|maintenance\|unknown\|error\"" ; then
    echo "ERROR: tf is not active after ziu"
    exit 1
fi

echo "INFO: ZIU is done  $(date)"
