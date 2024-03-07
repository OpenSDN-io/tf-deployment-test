#!/bin/bash -ex

my_file="$(readlink -e "$0")"
my_dir="$(dirname "$my_file")"

cd
mkdir -p .minor_update/log || true
exec 3>&1 1> >(tee .minor_update/log/${0}.log) 2>&1

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

##backup previous version of rhosp-environment.sh
#if [ ! -f rhosp-environment.sh.backup ]; then
#  cp rhosp-environment.sh rhosp-environment.sh.backup
#fi

#Check tf-devstack repo
DEVSTACK_PATH=${DEVSTACK_PATH:-"$HOME/tf-devstack"}

if [[ -d $DEVSTACK_PATH ]]; then
  #Updating ENVIRONMENT_OS, rhosp and rhel versions in rhosp-environment.sh
  update_rhosp_environment_sh rhosp-environment.sh
else 
  echo "ERROR: tf-devstack not found at $DEVSTACK_PATH. Make cd; git clone https://github.com/opensdn-io/tf-devstack.git or define variable DEVSTACK_PATH"
  exit 1
fi

#if [[ -n "$RHOSP_EXTRA_HEAT_ENVIRONMENTS" ]] ; then
#  add_variable rhosp-environment.sh RHOSP_EXTRA_HEAT_ENVIRONMENTS "$RHOSP_EXTRA_HEAT_ENVIRONMENTS"
#fi

#Reading updated rhosp-environment.sh
source rhosp-environment.sh

#Red Hat Registration case (TODO. it's not supported yet)
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
checkForVariable SLAVE_REGION
checkForVariable CI_DOMAIN
checkForVariable REPOS_CHANNEL
checkForVariable MIRROR_TEMPLATE_URL

if [[ "${ENABLE_RHEL_REGISTRATION,,}" != 'true' ]] ; then
  checkForVariable ssh_private_key
  checkForVariable NODE_ADMIN_USERNAME
fi

checkForVariable undercloud_public_host
checkForVariable undercloud_admin_host

cd

if [[ ! -f .minor_update/01_add_variables.success ]]; then
  add_variable rhosp-environment.sh CONTAINER_REGISTRY $CONTAINER_REGISTRY
  add_variable rhosp-environment.sh CONTRAIL_CONTAINER_TAG $CONTRAIL_CONTAINER_TAG
  add_variable rhosp-environment.sh OPENSTACK_CONTAINER_REGISTRY $OPENSTACK_CONTAINER_REGISTRY
  add_variable rhosp-environment.sh OPENSTACK_CONTAINER_TAG $OPENSTACK_CONTAINER_TAG
  
  if [[ -n "$EXTERNAL_CONTROLLER_NODES" ]] ; then
    add_variable rhosp-environment.sh EXTERNAL_CONTROLLER_NODES $EXTERNAL_CONTROLLER_NODES
    add_variable rhosp-environment.sh CONTROL_PLANE_ORCHESTRATOR 'operator'
    add_variable rhosp-environment.sh overcloud_ctrlcont_instance ''
  fi
  #Adding RHOSP16 parameters to ~/rhosp-environment.sh
  add_variable rhosp-environment.sh SSH_USER $SSH_USER
  add_variable rhosp-environment.sh mgmt_ip $mgmt_ip
  add_variable rhosp-environment.sh undercloud_admin_host $undercloud_admin_host
  add_variable rhosp-environment.sh undercloud_public_host $undercloud_public_host
  add_variable rhosp-environment.sh DEVSTACK_PATH $DEVSTACK_PATH

  if [[ "${ENABLE_RHEL_REGISTRATION,,}" != 'true' ]] ; then
    add_variable rhosp-environment.sh ssh_private_key $ssh_private_key
    add_variable rhosp-environment.sh NODE_ADMIN_USERNAME $NODE_ADMIN_USERNAME
  fi
  touch .minor_update/01_add_variables.success
else
  echo "SKIPPED: Adding variables"
fi	


ssh_options="-i $ssh_private_key -T -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o PasswordAuthentication=no"

if [[ ! -f .minor_update/02_copy_files_to_undercloud.success ]]; then
  ssh $ssh_options $SSH_USER@$mgmt_ip cp rhosp-environment.sh rhosp-environment.before_update
  scp $ssh_options -r rhosp-environment.sh $SSH_USER@$mgmt_ip:
  echo "Copying tf-deployment-test to undercloud node"
  ssh $ssh_options $SSH_USER@$mgmt_ip "mkdir tf-deployment-test || true"
  scp $ssh_options -r $my_dir/../../* $SSH_USER@$mgmt_ip:tf-deployment-test
  touch .minor_update/02_copy_files_to_undercloud.success
else
  echo "SKIPPED: Copying files to undercloud"
fi

#Preparing repo file
if [[ ! -f .minor_update/03_preparing_repo_file.success ]]; then
  curl -o local_repo.template --retry 3 --retry-delay 10 $MIRROR_TEMPLATE_URL
  cat local_repo.template | envsubst > local.repo
  scp $ssh_options -r local.repo $SSH_USER@$mgmt_ip:
  ssh $ssh_options $SSH_USER@$mgmt_ip sudo cp local.repo /etc/yum.repos.d/
  touch .minor_update/03_preparing_repo_file.success
else
  echo "SKIPPED: Preparing repo file"
fi

#Creating static inventory
if [[ ! -f .minor_update/04_creating_inventory.success ]]; then
  run_ssh_undercloud "source stackrc; tripleo-ansible-inventory --ansible_ssh_user cloud-user --static-yaml-inventory ~/inventory.yaml"
  touch .minor_update/04_creating_inventory.success
else
  echo "SKIPPED: Creating static ansible inventory"
fi

#Distribute repo file to overcloud nodes
if [[ ! -f .minor_update/05_distributing_repo.success ]]; then
  run_ssh_undercloud "ansible -i inventory.yaml overcloud -b -m copy -a 'src=local.repo dest=/etc/yum.repos.d/local.repo'"
  touch .minor_update/05_distributing_repo.success
else
  echo "SKIPPED: Distributing repo to the nodes"
fi

#Setup dnf modules
if [[ ! -f .minor_update/06_setup_dnf_modules.success ]]; then
  run_ssh_undercloud "ansible-playbook -i inventory.yaml -b ./tf-deployment-test/rhosp/rhosp16.1_16.2_minor/container-tools.yaml"
  run_ssh_undercloud "ansible -i inventory.yaml all -m shell -a 'dnf module list'"
  touch .minor_update/06_setup_dnf_modules.success
else
  echo "SKIPPED: Setup dnf modules on the nodes"
fi


#Disabling fencing in the overcloud
if [[ ! -f .minor_update/07_disabling_fencing.success ]]; then
  run_ssh_undercloud "ansible -i inventory.yaml overcloud_Controller -b -m shell -a 'pcs property set stonith-enabled=false'"
  touch .minor_update/07_disabling_fencing.success
else
  echo "SKIPPED: Disabling fencing on overcloud"
fi

#Upgrade undercloud
if [[ ! -f .minor_update/08_upgrade_undercloud.success ]]; then
  run_ssh_undercloud "sudo dnf update -y python3-tripleoclient* tripleo-ansible ansible"
  run_ssh_undercloud "ansible-playbook -i inventory.yaml ./tf-deployment-test/rhosp/rhosp16.1_16.2_minor/change-templates.yaml"
  echo "Preparing for undercloud RHEL upgrade"
  run_ssh_undercloud "source stackrc; openstack undercloud upgrade -y"
  reboot_and_wait_undercloud
  touch .minor_update/08_upgrade_undercloud.success
else
  echo "SKIPPED: Upgrading undercloud"
fi

#Preparing templates
if [[ ! -f .minor_update/09_preparing_templates.success ]]; then
  run_ssh_undercloud "mv tripleo-heat-templates tripleo-heat-templates.before_upgrade"
  run_ssh_undercloud "export SSH_USER_OVERCLOUD=$SSH_USER;  ~/tf-devstack/rhosp/overcloud/04_prepare_heat_templates.sh; ./tripleo-heat-templates/tools/process-templates.py -r /home/cloud-user/roles_data.yaml -p tripleo-heat-templates/"
  run_ssh_undercloud "ansible-playbook -i inventory.yaml ./tf-deployment-test/rhosp/rhosp16.1_16.2_minor/change-templates.yaml"
  touch .minor_update/09_preparing_templates.success
else
  echo "SKIPPED: Preparing new heat templates"
fi


##Updating overcloud images (no needed in case of VEXX with predeployed nodes)
##echo $(date) START: Start upgrading overcloud images | tee -a run.log
##run_ssh_undercloud "mkdir images || true"
##run_ssh_undercloud "rm -rf ~/images/* || true"
##run_ssh_undercloud "cd ~/images; tar -xvf /usr/share/rhosp-director-images/overcloud-full-latest-16.2.tar; tar -xvf /usr/share/rhosp-director-images/ironic-python-agent-latest-16.2.tar"
##
##run_ssh_undercloud "source stackrc; openstack overcloud image upload --update-existing --image-path ~/images/"
##run_ssh_undercloud "source stackrc; openstack overcloud node configure $(openstack baremetal node list -c UUID -f value)"
##Verification
##run_ssh_undercloud "source stackrc; openstack image list; ls -l /var/lib/ironic/httpboot"

#######################################################
##                  OVERCLOUD                         #
#######################################################

echo "$(date) START: Start upgrading overcloud"

#Preparing contrail images
if [[ ! -f .minor_update/10_overcloud_prepare_contrail_images.success ]]; then
  run_ssh_undercloud "./tf-deployment-test/rhosp/ffu_ziu_13_16/tf_specific/05_contrail_images_prepare.sh"
  touch .minor_update/10_overcloud_prepare_contrail_images.success
else
  echo "SKIPPED: Overcloud preparing contrail images"
fi

if [[ ! -f .minor_update/11_overcloud_update_prepare.success ]]; then
  run_ssh_undercloud "source stackrc; openstack overcloud update prepare --yes --templates tripleo-heat-templates/ --stack overcloud --libvirt-type kvm   --roles-file /home/cloud-user/roles_data.yaml --disable-validations --deployed-server --overcloud-ssh-user cloud-user --overcloud-ssh-key .ssh/id_rsa -e tripleo-heat-templates/environments/deployed-server-environment.yaml -e ctlplane-assignments.yaml -e hostname-map.yaml   -e tripleo-heat-templates/environments/contrail/contrail-services.yaml -e tripleo-heat-templates/environments/contrail/contrail-net-single.yaml -e tripleo-heat-templates/environments/contrail/contrail-plugins.yaml -e tripleo-heat-templates/environments/contrail/contrail-tls.yaml -e tripleo-heat-templates/environments/ssl/tls-everywhere-endpoints-dns.yaml -e tripleo-heat-templates/environments/services/haproxy-public-tls-certmonger.yaml -e tripleo-heat-templates/environments/ssl/enable-internal-tls.yaml -e misc_opts.yaml -e contrail-parameters.yaml -e containers-prepare-parameter.yaml"
  touch .minor_update/11_overcloud_update_prepare.success
else
  echo "SKIPPED: Overcloud update prepare"
fi

if [[ ! -f .minor_update/12_overcloud_container_image_prepare.success ]]; then
   run_ssh_undercloud "source stackrc; openstack overcloud external-update run --yes --stack overcloud --tags container_image_prepare"
  touch .minor_update/12_overcloud_container_image_prepare.success
else
  echo "SKIPPED: Overcloud external update container_image_prepare"
fi

if [[ ! -f .minor_update/13_overcloud_container_ovn.success ]]; then
  run_ssh_undercloud "source stackrc; openstack overcloud external-update run --yes --stack overcloud --tags ovn"
  touch .minor_update/13_overcloud_container_ovn.success
else
  echo "SKIPPED: Overcloud external update container_image_prepare"
fi

if [[ ! -f .minor_update/14_overcloud_update_controller.success ]]; then
  run_ssh_undercloud "source stackrc; openstack overcloud update run --yes --stack overcloud --limit Controller --playbook all"
  touch .minor_update/14_overcloud_update_controller.success
else
  echo "SKIPPED: Overcloud update Controller"
fi

if [[ ! -f .minor_update/15_overcloud_update_contrailcontroller.success ]]; then
  run_ssh_undercloud "source stackrc; openstack overcloud update run --yes --stack overcloud --limit ContrailController --playbook all"
  touch .minor_update/15_overcloud_update_contrailcontroller.success
else
  echo "SKIPPED: Overcloud update ContrailController"
fi

if [[ ! -f .minor_update/16_overcloud_update_compute.success ]]; then
  run_ssh_undercloud "source stackrc; openstack overcloud update run --yes --stack overcloud --limit Compute --playbook all"
  touch .minor_update/16_overcloud_update_compute.success
else
  echo "SKIPPED: Overcloud update Compute"
fi

if [[ ! -f .minor_update/17_overcloud_online_upgrade.success ]]; then
  run_ssh_undercloud "source stackrc; openstack overcloud external-update run --yes --tags online_upgrade"
  touch .minor_update/17_overcloud_online_upgrade.success
else
  echo "SKIPPED: Overcloud online_upgrade"
fi

if [[ ! -f .minor_update/18_overcloud_update_converge.success ]]; then
  run_ssh_undercloud "source stackrc; openstack overcloud update converge --yes --templates tripleo-heat-templates/ --stack overcloud --libvirt-type kvm   --roles-file /home/cloud-user/roles_data.yaml --disable-validations --deployed-server --overcloud-ssh-user cloud-user --overcloud-ssh-key .ssh/id_rsa -e tripleo-heat-templates/environments/deployed-server-environment.yaml -e ctlplane-assignments.yaml -e hostname-map.yaml   -e tripleo-heat-templates/environments/contrail/contrail-services.yaml -e tripleo-heat-templates/environments/contrail/contrail-net-single.yaml -e tripleo-heat-templates/environments/contrail/contrail-plugins.yaml -e tripleo-heat-templates/environments/contrail/contrail-tls.yaml -e tripleo-heat-templates/environments/ssl/tls-everywhere-endpoints-dns.yaml -e tripleo-heat-templates/environments/services/haproxy-public-tls-certmonger.yaml -e tripleo-heat-templates/environments/ssl/enable-internal-tls.yaml -e misc_opts.yaml -e contrail-parameters.yaml -e containers-prepare-parameter.yaml"
  touch .minor_update/18_overcloud_update_converge.success
else
  echo "SKIPPED: Overcloud update converge"
fi

#echo $(date) FINISH: Collecting the information | tee -a run.log
#run_ssh_undercloud './tf-deployment-test/rhosp/ffu_ziu_13_16/redhat_ffu_steps/13_collect_information.sh'

