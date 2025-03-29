#!/bin/bash -e
set -o pipefail

export DEBUG=${DEBUG:-false}
[[ "$DEBUG" != true ]] || set -x

scriptdir=$(realpath $(dirname "$0"))

TF_CONFIG_DIR=${TF_CONFIG_DIR:-"${HOME}/.tf"}
CONTAINER_REGISTRY=${CONTAINER_REGISTRY:-"localhost:5000"}
CONTRAIL_CONTAINER_TAG=${CONTRAIL_CONTAINER_TAG:-"dev"}
# ?_ORIGINAL params must be set for ZIU tests

TEST_ENV_FILE=$TF_CONFIG_DIR/test.env

if which docker >/dev/null 2>&1 ; then
  RUNTIME=docker
elif which ctr >/dev/null 2>&1 ; then
  RUNTIME=containerd
fi

function docker_run_test_image() {
  local image=$1

  # define vol_opts
  vol_opts=" -v $TEST_ENV_FILE:/input/test.env"
  vol_opts+=" -v $HOME/.ssh/id_rsa:/root/.ssh/id_rsa"
  if [[ "${SSL_ENABLE,,}" == 'true' ]]; then
    vol_opts+=" -v /etc/contrail/ssl:/etc/contrail/ssl"
  fi
  mkdir -p $scriptdir/output/logs
  vol_opts+=" -v $scriptdir/output:/output"
  # NOTE: to be able to have sources locally that will be executed
  # user can clone this repo from script dir and it will be used as a source code
  if [ -d $scriptdir/opensdn-deployment-test ]; then
    vol_opts+=" -v $scriptdir/opensdn-deployment-test:/opensdn-deployment-test"
  fi

  sudo docker pull $image

  echo "INFO: command to run: sudo docker run --privileged=true --rm=true -t $vol_opts --network host $image"
  sudo docker run --privileged=true --rm=true -t $vol_opts --network host $image
}

function ctr_run_test_image() {
  local image=$1

  # define vol_opts
  vol_opts="--mount type=bind,src=$TEST_ENV_FILE,dst=/input/test.env,options=rbind:ro"
  vol_opts+=" --mount type=bind,src=$HOME/.ssh/id_rsa,dst=/root/.ssh/id_rsa,options=rbind:ro"
  if [[ "${SSL_ENABLE,,}" == 'true' ]]; then
    vol_opts+=" --mount type=bind,src=/etc/contrail/ssl,dst=/etc/contrail/ssl,options=rbind:ro"
  fi
  mkdir -p $scriptdir/output/logs
  vol_opts+="  --mount type=bind,src=$scriptdir/output,dst=/output,options=rbind:rw"
  # NOTE: to be able to have sources locally that will be executed
  # user can clone this repo from script dir and it will be used as a source code
  if [ -d $scriptdir/opensdn-deployment-test ]; then
    vol_opts+=" --mount type=bind,src=$scriptdir/opensdn-deployment-test,dst=/opensdn-deployment-test,options=rbind:rw"
  fi
  vol_opts+=" --mount type=bind,src=/run/containerd,dst=/run/containerd,options=rbind:rw"
  vol_opts+=" --mount type=bind,src=/sys/fs/cgroup,dst=/sys/fs/cgroup,options=rbind:rw"

  if ! sudo ctr -n k8s.io image pull $image >/dev/null ; then
        echo "ERROR: image $image cannot be pulled"
        return 1
  fi

  echo "INFO: command to run: sudo ctr -n k8s.io run --privileged --rm -t $vol_opts --net-host $image $RANDOM"
  sudo ctr -n k8s.io run --privileged --rm -t $vol_opts --net-host $image $RANDOM
}

echo "INFO: create test.env"
rm -f $TEST_ENV_FILE
touch $TEST_ENV_FILE
echo "DEBUG=$DEBUG" >> $TEST_ENV_FILE
if [ -f $TF_CONFIG_DIR/stack.env ]; then
  set -a ; source $TF_CONFIG_DIR/stack.env ; set +a
  cat $TF_CONFIG_DIR/stack.env >> $TEST_ENV_FILE
fi
echo "CONTAINER_REGISTRY_ORIGINAL=$CONTAINER_REGISTRY_ORIGINAL" >> $TEST_ENV_FILE
echo "CONTRAIL_CONTAINER_TAG_ORIGINAL=$CONTRAIL_CONTAINER_TAG_ORIGINAL" >> $TEST_ENV_FILE
echo "DEPLOYER_CONTAINER_REGISTRY_ORIGINAL=$DEPLOYER_CONTAINER_REGISTRY_ORIGINAL" >> $TEST_ENV_FILE
echo "CONTRAIL_DEPLOYER_CONTAINER_TAG_ORIGINAL=$CONTRAIL_DEPLOYER_CONTAINER_TAG_ORIGINAL" >> $TEST_ENV_FILE
echo "SSH_USER=$(whoami)" >> $TEST_ENV_FILE
phys_int=`ip route get 1 | grep -o 'dev.*' | awk '{print($2)}'`
echo "SSH_HOST=$(ip addr show dev $phys_int | grep 'inet ' | awk '{print $2}' | head -n 1 | cut -d '/' -f 1)" >> $TEST_ENV_FILE
echo "DEPLOYMENT_TEST_TAGS=$DEPLOYMENT_TEST_TAGS" >> $TEST_ENV_FILE

cat $TEST_ENV_FILE

TF_DEPLOYMENT_TEST_IMAGE="${TF_DEPLOYMENT_TEST_IMAGE:-${CONTAINER_REGISTRY}/opensdn-deployment-test:${CONTRAIL_CONTAINER_TAG}}"
if [[ $RUNTIME == docker ]] ; then
  docker_run_test_image $TF_DEPLOYMENT_TEST_IMAGE || res=1
elif [[ $RUNTIME == containerd ]] ; then
  ctr_run_test_image $TF_DEPLOYMENT_TEST_IMAGE || res=1
fi

pushd $scriptdir/output
tar -cvf $WORKSPACE/logs.tar logs
popd
gzip $WORKSPACE/logs.tar
mv $WORKSPACE/logs.tar.gz $WORKSPACE/logs.tgz

if [[ "$res" == 1 ]]; then
  echo "ERROR: Tests failed"
else
  echo "INFO: tests passed"
fi

exit $res
