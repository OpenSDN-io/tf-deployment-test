#!/bin/bash -ex

exec 3>&1 1> >(tee ${0}.log) 2>&1
echo $(date) "------------------ STARTED: $0 -------------------"

cd ~
source stackrc
source rhosp-environment.sh

registry=${CONTAINER_REGISTRY:-'docker.io/opensdn'}
tag=${CONTRAIL_CONTAINER_TAG:-'latest'}

export undercloud_registry_contrail=${prov_ip}:8787
ns=$(echo ${registry} | cut -s -d '/' -f2-)
[ -n "$ns" ] && undercloud_registry_contrail+="/$ns"

./tripleo-heat-templates/tools/contrail/import_contrail_container.sh \
    -f ./contrail_containers.yaml -r $registry -t $tag

sed -i ./contrail_containers.yaml -e "s/192.168.24.1/${prov_ip}/"

cat ./contrail_containers.yaml

echo 'sudo openstack overcloud container image upload --config-file ./contrail_containers.yaml'
sudo openstack overcloud container image upload --config-file ./contrail_containers.yaml

echo Checking catalog in docker registry
openstack tripleo container image list

echo $(date) "------------------ FINISHED: $0 ------------------"
