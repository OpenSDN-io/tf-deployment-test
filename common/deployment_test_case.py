import logging
import os
import sys
import testtools
import time
import json

from common.fixtures.host_fixture import HostFixture
from common.utils.vnc_api import VncApiProxy


def initLogger():
    level = logging.DEBUG if os.environ.get('DEBUG', True) else logging.INFO
    root_logger = logging.getLogger()
    root_logger.setLevel(level)
    formatter = logging.Formatter(
        '%(asctime)s.%(msecs)03d %(levelname)s: %(message)s',
        datefmt='%Y-%m-%d %H:%M:%S')
    # use stderr as stdout is replaced by testr
    handler = logging.StreamHandler(sys.stderr)
    handler.setLevel(level)
    handler.setFormatter(formatter)
    root_logger.addHandler(handler)
    return root_logger


logger = initLogger()


class DeploymentTestCase(testtools.testcase.WithAttributes, testtools.TestCase):

    @classmethod
    def setUpClass(cls):
        global logger
        cls.logger = logger
        cls.ssh_host = os.getenv("SSH_HOST")
        cls.ssh_user = os.getenv("SSH_USER")
        # list can be space or comma separated
        cls.controller_nodes = os.getenv(
            "CONTROLLER_NODES", "").strip().replace(" ", ",").split(",")
        cls.agent_nodes = os.getenv(
            "AGENT_NODES", "").strip().replace(" ", ",").split(",")
        cls.use_ssl = os.getenv("SSL_ENABLE")
        cls.domain_name = os.getenv("AUTH_DOMAIN")
        cls.auth_token_url = None
        auth_url = os.getenv("AUTH_URL")
        if auth_url:
            cls.auth_token_url = auth_url + "/auth/tokens"
            if auth_url.endswith("v2.0"):
                cls.auth_token_url = auth_url + "/tokens"
        cls.auth_password = os.getenv("AUTH_PASSWORD")
        cls.vnc_api_client = VncApiProxy(cls.controller_nodes,
                                         cls.use_ssl,
                                         cls.domain_name,
                                         cls.auth_token_url,
                                         cls.auth_password,
                                         cls.logger)
        cls.host_fixture = HostFixture(cls.ssh_host, cls.ssh_user, cls.logger)
        cls.host_fixture.setUp()

    @classmethod
    def tearDownClass(cls):
        cls.host_fixture.cleanUp()

    def run_test_remotely(self, test_file):
        remote_path = self.host_fixture.get_remote_path(test_file)
        self.host_fixture.exec_command(remote_path, log_output=True)

    def restart_containers(self, name_filter=""):
        # TODO: reboot only tf containers
        # but now we reboot all another containers
        for node in self.controller_nodes:
            hf = self.useFixture(
                HostFixture(node, self.ssh_user, self.logger))
            # containers may be on docker or containerd, kill processes is universal way to restart
            processes = hf.exec_command_result(
                "ps ax -H | grep -v grep |grep -B 2 " + name_filter + " | grep Ss | awk '{print$1}'")
            hf.exec_command(
                'sudo kill -KILL ' + ' '.join(processes.split()))
        # TODO: use correct wait. think about usefulness of this wait
        time.sleep(30)

    def check_container_tags(self, tag):
        nodes = self.controller_nodes + self.agent_nodes
        for node in nodes:
            host_fixture = self.useFixture(HostFixture(node, self.ssh_user, self.logger))
            result = host_fixture.exec_command_result('sudo opensdn-status --format json')
            containers = json.loads(result.replace('\\"', '').replace('\\', '')).get('containers')
            for key in containers:
                if containers[key].get('Original Version') != tag:
                    raise Exception("WARNING: {}'s tag {} is not equal to {}".format(
                                    key, containers[key].get('Original Version'), tag))
