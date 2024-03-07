# deployment test manual

## Run the tests

Use the same machine you've just run tf-devstack. The code uses $HOME/.tf/stack.env to obtain information about the cloud.

To run this locally from scratch:

```bash
git clone https://github.com/opensdn-io/tf-deployment-test.git
cd tf-deployment-test
./build-containers.sh
./testrunner.sh
```

If you have this image already build in some registry then please create this container and copy testrunner.sh from it.
Then you can run it.
Also user can clone this repo to the same place as testrunner.sh to be able to have sources locally that will be executed inside container (script will mount sources):

```bash
set -a ; source $HOME/.tf/stack.env ; set +a
TF_DEPLOYMENT_TEST_IMAGE="${CONTAINER_REGISTRY}/tf-deployment-test:${CONTRAIL_CONTAINER_TAG}"

# copy testrunner.sh locally
sudo docker pull $TF_DEPLOYMENT_TEST_IMAGE
tmp_name=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 10 | head -n 1)
sudo docker create --name $tmp_name $TF_DEPLOYMENT_TEST_IMAGE
sudo docker cp $tmp_name:/testrunner.sh ./testrunner.sh
sudo docker rm $tmp_name

# optinally clone the repo
git clone https://github.com/opensdn-io/tf-deployment-test.git

# run it
./testrunner.sh
```

## Debugging tests

Run testrunner.sh in bash debug mode

```bash
bash -ex ./testrunner.sh
```

Then copy string of docker run and use `-it` instead of `-i`(or `-t`) and add `--entrypoint bash`. Run it.
Now you are inside container with tests. You can edit code and run it.

```bash
set -a ; source /input/test.env ; set +a
eval export $(sed 's/=.*//' /input/test.env)
cd /tf-deployment-test
testr run
```

In case of first run please run `testr init` first.

To debug any test please edit code and insert next lines according to python style

```python
import pdb
pdb.set_trace()
```

Now you can list tests with `python3 -m testtools.run discover ./tests --list > testlist`
Edit file 'testlist' to reduce the list
And run them with `python3 -m testtools.run discover ./tests  --load-list testlist`
Execution should stop at breakpoint and you can inspect flow and variables.
