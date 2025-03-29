#!/bin/bash -e
set -o pipefail

CONTRAIL_REGISTRY=${CONTRAIL_REGISTRY:-"localhost:5000"}
CONTRAIL_CONTAINER_TAG=${CONTRAIL_CONTAINER_TAG:-"dev"}

LINUX_ID=$(awk -F"=" '/^ID=/{print $2}' /etc/os-release | tr -d '"')
LINUX_VER_ID=$(awk -F"=" '/^VERSION_ID=/{print $2}' /etc/os-release | tr -d '"')

scriptdir=$(realpath $(dirname "$0"))

build_opts="--build-arg LC_ALL=en_US.UTF-8 --build-arg LANG=en_US.UTF-8 --build-arg LANGUAGE=en_US.UTF-8"
build_opts+=" --network host --no-cache --tag ${CONTRAIL_REGISTRY}/opensdn-deployment-test:${CONTRAIL_CONTAINER_TAG} $scriptdir"

if [[ "$LINUX_ID" == 'rhel' && "${LINUX_VER_ID//.[0-9]*/}" == '8' ]] ; then
  # podman case
  build_opts+=' --format docker'
  build_opts+=' --cap-add=all --security-opt label=disable --security-opt seccomp=unconfined'
  build_opts+=' -v /etc/resolv.conf:/etc/resolv.conf:ro'
  # to make posible use subscription inside container run from container in podman
  if [ -e /run/secrets/etc-pki-entitlement ] ; then
    build_opts+=' -v /run/secrets/etc-pki-entitlement:/run/secrets/etc-pki-entitlement:ro'
  fi
fi
if [ -n "$LINUX_DISTR_VER" ] ; then
  build_opts+=" --build-arg LINUX_DISTR_VER=${LINUX_DISTR_VER}"
fi
if [ -n "$LINUX_DISTR" ] ; then
  build_opts+=" --build-arg LINUX_DISTR=${LINUX_DISTR}"
fi

sudo docker build $build_opts
if [[ -n "$CONTRAIL_REGISTRY" ]]; then
  sudo docker push ${CONTRAIL_REGISTRY}/opensdn-deployment-test:${CONTRAIL_CONTAINER_TAG}
fi
