#!/bin/bash -xe
my_file="$(readlink -e "$0")"
my_dir="$(dirname "$my_file")"

TF_CONFIG_DIR=${TF_CONFIG_DIR:-"$HOME/.tf"}
source /tmp/test.env

export CONTAINER_REGISTRY="$CONTAINER_REGISTRY_ORIGINAL"
export CONTRAIL_CONTAINER_TAG="$CONTRAIL_CONTAINER_TAG_ORIGINAL"
export SSH_OPTIONS=${SSH_OPTIONS:-"-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"}

# working environment
tf_deployer_dir=${TF_ANSIBLE_DEPLOYER_DIR:-"${HOME}/opensdn-ansible-deployer"}
openstack_deployer_dir=${HOME}/opensdn-kolla-ansible
tf_deployer_image=${TF_ANSIBLE_DEPLOYER:-"opensdn-ansible-deployer-src"}
openstack_deployer_image=${OPENSTACK_DEPLOYER:-"opensdn-kolla-ansible-src"}

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

  local image="$CONTAINER_REGISTRY/$deployer_image"
  [ -n "$CONTRAIL_CONTAINER_TAG" ] && image+=":$CONTRAIL_CONTAINER_TAG"
  sudo docker create --name $deployer_image --entrypoint /bin/true $image || return 1
  sudo docker cp $deployer_image:/src $deployer_dir
  sudo docker rm -fv $deployer_image
  sudo chown -R $UID $deployer_dir
}

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
  for machine in $(echo "$CONTROLLER_NODES $AGENT_NODES" | tr " " "\n" | sort -u) ; do
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

fetch_deployer $tf_deployer_image $tf_deployer_dir
fetch_deployer $openstack_deployer_image $openstack_deployer_dir

cd $tf_deployer_dir

# Upgrade contrail_container_tag in ziu_instances.yaml
cp $TF_CONFIG_DIR/instances.yaml $TF_CONFIG_DIR/ziu_instances.yaml
sed -i "s/CONTRAIL_CONTAINER_TAG:.*/CONTRAIL_CONTAINER_TAG: $CONTRAIL_CONTAINER_TAG/g" $TF_CONFIG_DIR/ziu_instances.yaml
sed -i "s/CONTAINER_REGISTRY:.*/CONTAINER_REGISTRY: $CONTAINER_REGISTRY/g" $TF_CONFIG_DIR/ziu_instances.yaml

# Run controller stage of ziu.yml
sudo -E ansible-playbook -v -e stage=controller -e orchestrator=openstack -e config_file=$TF_CONFIG_DIR/ziu_instances.yaml playbooks/ziu.yml

# Run openstack stage of ziu.yml
sudo -E ansible-playbook -v -e stage=openstack -e orchestrator=openstack -e config_file=$TF_CONFIG_DIR/ziu_instances.yaml playbooks/ziu.yml

# Run compute stage of ziu.yml
sudo -E ansible-playbook -v -e stage=compute -e orchestrator=openstack -e config_file=$TF_CONFIG_DIR/ziu_instances.yaml playbooks/ziu.yml

if ! wait_cmd_success 10 60 "check_tf_active" ; then
    echo "ERROR: tf is not active after ziu"
    exit 1
fi
