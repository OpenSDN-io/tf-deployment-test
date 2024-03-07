#!/bin/bash -e

my_file="$(readlink -e "$0")"
my_dir="$(dirname "$my_file")"

cd
source $my_dir/../common/functions.sh

checkForVariable CONTAINER_REGISTRY
checkForVariable CONTRAIL_CONTAINER_TAG
checkForVariable OPENSTACK_CONTAINER_REGISTRY
checkForVariable ENVIRONMENT_OS
checkForVariable PROVIDER
if [[ "$ENVIRONMENT_OS" != 'rhel82' && "$ENVIRONMENT_OS" != 'rhel84' ]] ; then
  echo "ERROR: update ENVIRONMENT_OS to target release rhel82 or rhel84"
  exit 1
fi

#backup previous version of rhosp-environment.sh
if [ ! -f rhosp-environment.sh.backup ]; then
  cp rhosp-environment.sh rhosp-environment.sh.backup
fi

#Check tf-devstack repo
DEVSTACK_PATH=${DEVSTACK_PATH:-"$HOME/tf-devstack"}

if [[ -d $DEVSTACK_PATH ]]; then
  #Updating ENVIRONMENT_OS, rhosp and rhel versions in rhosp-environment.sh
  update_rhosp_environment_sh rhosp-environment.sh
else 
  echo "ERROR: tf-devstack not found at $DEVSTACK_PATH. Make cd; git clone https://github.com/opensdn-io/tf-devstack.git or define variable DEVSTACK_PATH"
  exit 1
fi

add_variable rhosp-environment.sh CONTAINER_REGISTRY $CONTAINER_REGISTRY
add_variable rhosp-environment.sh CONTRAIL_CONTAINER_TAG $CONTRAIL_CONTAINER_TAG
add_variable rhosp-environment.sh OPENSTACK_CONTAINER_REGISTRY $OPENSTACK_CONTAINER_REGISTRY
add_variable rhosp-environment.sh OPENSTACK_CONTAINER_TAG $OPENSTACK_CONTAINER_TAG

if [[ -n "$EXTERNAL_CONTROLLER_NODES" ]] ; then
  add_variable rhosp-environment.sh EXTERNAL_CONTROLLER_NODES $EXTERNAL_CONTROLLER_NODES
  add_variable rhosp-environment.sh CONTROL_PLANE_ORCHESTRATOR 'operator'
  add_variable rhosp-environment.sh overcloud_ctrlcont_instance ''
fi

if [[ -n "$RHOSP_EXTRA_HEAT_ENVIRONMENTS" ]] ; then
  add_variable rhosp-environment.sh RHOSP_EXTRA_HEAT_ENVIRONMENTS "$RHOSP_EXTRA_HEAT_ENVIRONMENTS"
fi

#Reading updated rhosp-environment.sh
source rhosp-environment.sh

#Red Hat Registration case
if [[ "${ENABLE_RHEL_REGISTRATION,,}" == 'true' ]] ; then
  checkForVariable RHEL_USER
  checkForVariable RHEL_PASSWORD
  checkForVariable RHEL_POOL_ID
  checkForVariable RHEL_REPOS
fi

#Adding and RHOSP16 variables
undercloud_local_ip=$(grep -o "export prov_ip=.*" ~/rhosp-environment.sh | cut -d ' ' -f2 | cut -d '=' -f 2 | tr -d '"')

undercloud_public_host="${prov_subnet}.2"
undercloud_admin_host="${prov_subnet}.3"

checkForVariable RHOSP_VERSION
checkForVariable RHEL_VERSION
checkForVariable SSH_USER
checkForVariable mgmt_ip
checkForVariable prov_subnet
if [[ "${ENABLE_RHEL_REGISTRATION,,}" != 'true' ]] ; then
  checkForVariable ssh_private_key
  checkForVariable NODE_ADMIN_USERNAME
fi

if [[ "${ENABLE_RHEL_REGISTRATION,,}" != 'true' ]] ; then
  checkForVariable RHEL_LOCAL_MIRROR
fi
checkForVariable undercloud_public_host
checkForVariable undercloud_admin_host

#Adding RHOSP16 parameters to ~/rhosp-environment.sh
cd
add_variable rhosp-environment.sh SSH_USER $SSH_USER
add_variable rhosp-environment.sh mgmt_ip $mgmt_ip
add_variable rhosp-environment.sh undercloud_admin_host $undercloud_admin_host
add_variable rhosp-environment.sh undercloud_public_host $undercloud_public_host
add_variable rhosp-environment.sh DEVSTACK_PATH $DEVSTACK_PATH

if [[ "${ENABLE_RHEL_REGISTRATION,,}" != 'true' ]] ; then
  add_variable rhosp-environment.sh ssh_private_key $ssh_private_key
  add_variable rhosp-environment.sh NODE_ADMIN_USERNAME $NODE_ADMIN_USERNAME
  add_variable rhosp-environment.sh RHEL_LOCAL_MIRROR $RHEL_LOCAL_MIRROR
fi

#Updating rhosp-environment.sh
ssh $SSH_USER@$mgmt_ip cp rhosp-environment.sh rhosp-environment-rhosp13-backup.sh
scp -r rhosp-environment.sh $SSH_USER@$mgmt_ip:
echo "Copying tf-deployment-test to undercloud node"
ssh $SSH_USER@$mgmt_ip "mkdir tf-deployment-test || true"
scp -r $my_dir/../../* $SSH_USER@$mgmt_ip:tf-deployment-test

echo $(date) START: Start upgrading undercloud | tee -a run.log
echo "Preparing for undercloud RHEL upgrade"
run_ssh_undercloud './tf-deployment-test/rhosp/ffu_ziu_13_16/redhat_ffu_steps/01_undercloud_prepare.sh'
reboot_and_wait_undercloud

run_ssh_undercloud './tf-deployment-test/rhosp/ffu_ziu_13_16/redhat_ffu_steps/02_undercloud_upgrade_rhel_step1.sh'
reboot_and_wait_undercloud

run_ssh_undercloud './tf-deployment-test/rhosp/ffu_ziu_13_16/redhat_ffu_steps/03_undercloud_upgrade_rhel_step2.sh'
reboot_and_wait_undercloud

run_ssh_undercloud './tf-deployment-test/rhosp/ffu_ziu_13_16/redhat_ffu_steps/04_undercloud_upgrade_tripleo.sh'

echo $(date) Preparing contrail images | tee -a run.log
run_ssh_undercloud './tf-deployment-test/rhosp/ffu_ziu_13_16/tf_specific/05_contrail_images_prepare.sh'

######################################################
#                  OVERCLOUD                         #
######################################################
echo $(date) Preparing overcloud nodes | tee -a run.log
run_ssh_undercloud './tf-deployment-test/rhosp/ffu_ziu_13_16/redhat_ffu_steps/06_overcloud_prepare.sh'
echo $(date) Preparing heat template | tee -a run.log
run_ssh_undercloud './tf-deployment-test/rhosp/ffu_ziu_13_16/redhat_ffu_steps/07_overcloud_prepare_templates.sh'
echo $(date) Start overcloud upgrade prepare | tee -a run.log
run_ssh_undercloud './tf-deployment-test/rhosp/ffu_ziu_13_16/redhat_ffu_steps/08_overcloud_upgrade_prepare.sh'
echo $(date) Start overcloud bootstrap batch  | tee -a run.log
run_ssh_undercloud './tf-deployment-test/rhosp/ffu_ziu_13_16/redhat_ffu_steps/09_overcloud_upgrade_control_plane_step01.sh'
echo $(date) Start overcloud controlplane  update| tee -a run.log
run_ssh_undercloud './tf-deployment-test/rhosp/ffu_ziu_13_16/redhat_ffu_steps/10_overcloud_upgrade_control_plane_step02.sh'
echo $(date) Start overcloud compute update | tee -a run.log
run_ssh_undercloud './tf-deployment-test/rhosp/ffu_ziu_13_16/redhat_ffu_steps/11_overcloud_upgrade_computes.sh'
echo $(date) Start overcloud upgrade converge | tee -a run.log
run_ssh_undercloud './tf-deployment-test/rhosp/ffu_ziu_13_16/redhat_ffu_steps/12_overcloud_upgrade_converge.sh'
echo $(date) FINISH: Collecting the information | tee -a run.log
run_ssh_undercloud './tf-deployment-test/rhosp/ffu_ziu_13_16/redhat_ffu_steps/13_collect_information.sh'

