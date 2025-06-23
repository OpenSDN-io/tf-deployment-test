ARG LINUX_DISTR=centos
ARG LINUX_DISTR_VER=7
FROM $LINUX_DISTR:$LINUX_DISTR_VER
ARG LINUX_DISTR=centos

COPY . /opensdn-deployment-test

RUN cp /opensdn-deployment-test/testrunner.sh / && \
    cp -r /etc/yum.repos.d /etc/yum.repos.d.orig && \
    if [ -f /opensdn-deployment-test/mirrors/pip.conf ] ; then \
        cp /opensdn-deployment-test/mirrors/pip.conf /etc/ ; \
    fi && \
    if [[ -d /opensdn-deployment-test/mirrors && -n "$(ls /opensdn-deployment-test/mirrors/*.repo)" ]] ; then \
        cp /opensdn-deployment-test/mirrors/*.repo /etc/yum.repos.d/ ; \
    fi && \
    if [[ "$LINUX_DISTR" == "centos" ]]; then \
        for file in /etc/yum.repos.d/rdo-* ; do grep -v mirrorlist= "$file" > "$file".new && mv "$file".new "$file" ; done ; \
        sed -i 's|#\s*baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/rdo-* ; \
        find /etc/yum.repos.d/ | grep -i rocky | xargs -r rm ; ls -l /etc/yum.repos.d/ ; \
    else \
        find /etc/yum.repos.d/ | grep -i centos | xargs -r rm ; ls -l /etc/yum.repos.d/ ; \
    fi ; \
    yum update -y -x "redhat-release*" -x "coreutils*" && \
    yum -y update-minimal --security --sec-severity=Important --sec-severity=Critical && \
    yum install -y python3 python3-pip rsync openssh-clients && \
    pip3 install --upgrade --no-compile pip && \
    pip3 install --no-compile -r /opensdn-deployment-test/requirements.txt && \
    pip3 install --force urllib3==1.24.2 && \
    yum clean all -y && \
    rm -rf /var/cache/yum

ENTRYPOINT ["/opensdn-deployment-test/entrypoint.sh"]
