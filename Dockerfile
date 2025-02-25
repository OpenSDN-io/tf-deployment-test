ARG LINUX_DISTR=centos
ARG LINUX_DISTR_VER=7
FROM $LINUX_DISTR:$LINUX_DISTR_VER

COPY . /tf-deployment-test

RUN cp /tf-deployment-test/testrunner.sh / && \
    cp -r /etc/yum.repos.d /etc/yum.repos.d.orig && \
    if [ -f /tf-deployment-test/mirrors/pip.conf ] ; then \
        cp /tf-deployment-test/mirrors/pip.conf /etc/ ; \
    fi && \
    if [[ -d /tf-deployment-test/mirrors && -n "$(ls /tf-deployment-test/mirrors/*.repo)" ]] ; then \
        cp /tf-deployment-test/mirrors/*.repo /etc/yum.repos.d/ ; \
    fi && \
    yum update -y -x "redhat-release*" -x "coreutils*" && \
    yum -y update-minimal --security --sec-severity=Important --sec-severity=Critical && \
    yum install -y python3 python3-pip rsync openssh-clients && \
    pip3 install --upgrade --no-compile pip && \
    pip3 install --no-compile -r /tf-deployment-test/requirements.txt && \
    pip3 install --force urllib3==1.24.2 && \
    yum clean all -y && \
    rm -rf /var/cache/yum

ENTRYPOINT ["/tf-deployment-test/entrypoint.sh"]
