# SUSE's openQA tests
#
# Copyright © 2018 SUSE LLC
#
# Copying and distribution of this file, with or without modification,
# are permitted in any medium without royalty provided the copyright
# notice and this notice are preserved.  This file is offered as-is,
# without any warranty.

# Summary: openvswitch installation and CLI test
#
#   This test does the following
#    - Installs needed packages (ovs, dpdk, git, ...)
#    - Clones vsperf and dpdk repositories
#    - Starts the systemd service unit
#    - Executes a few basic openvswitch commands
#    - Removes the lines to skip OVS, DPDK and QEMU compilation
#    - Installs vsperf tool
#
# Maintainer: Jose Lausuch <jalausuch@suse.de>

use base "opensusebasetest";
use testapi;
use strict;
use utils;
use lockapi;
use mmapi;
use serial_terminal 'select_virtio_console';

sub get_trafficgen_ip {
    my $host1 = get_required_var('NFVTEST_IP1');
    my $host2 = get_required_var('NFVTEST_IP2');
    my $my_ip = script_output(q(ip -4 addr show eth0 | egrep inet|awk '{print $2}'|cut -d/ -f1));
    return $host2 if ($my_ip eq $host1);
    return $host1;
}

sub run {
    select_console 'root-ssh' if (check_var('BACKEND', 'ipmi'));
    select_virtio_console()   if (check_var('BACKEND', 'qemu'));

    my ($self)        = @_;
    my $vsperf_repo   = "https://gerrit.opnfv.org/gerrit/vswitchperf";
    my $dpdk_repo     = "http://dpdk.org/git/dpdk";
    my $trafficgen_ip = get_trafficgen_ip();
    my $children      = get_children();
    my $child_id      = (keys %$children)[0];

    record_info("Install OVS, DPKD");
    zypper_call('--quiet in git-core openvswitch-switch dpdk qemu tcpdump', timeout => 200);

    assert_script_run("cd /root/");
    record_info("Clone VSPerf");
    assert_script_run("git clone --quiet --depth 1 $vsperf_repo", timeout => 200);
    record_info("Clone DPKD");
    assert_script_run("git clone --quiet --depth 1 $dpdk_repo", timeout => 500);

    record_info("Start openvswitch");
    systemctl 'enable openvswitch', timeout => 200;
    systemctl 'start openvswitch',  timeout => 200;

    record_info("VSPerf Installation");
    assert_script_run("cd vswitchperf/systems");
    if (check_var('VERSION', '15')) {
        # Hack to skip the OVS, DPDK and QEMU compilation as we will use the vanilla packages
        assert_script_run("sed -n -e :a -e '1,8!{P;N;D;};N;ba' -i build_base_machine.sh");
        zypper_call('ar -f http://download.suse.de/ibs/SUSE:/SLE-12:/GA/standard/SUSE:SLE-12:GA.repo SLE-12-GA-REPO');
        assert_script_run("bash -x build_base_machine.sh", 300);
    }
    elsif (check_var('VERSION', '12-SP4')) {
        assert_script_run("curl " . data_url('nfv/sles/12.4/build_base_machine.sh') . " -o /root/build_base_machine.sh");
        assert_script_run("chmod 755 /root/build_base_machine.sh");
        assert_script_run("bash -x /root/build_base_machine.sh", timeout => 500);
    }
    else {
        die "OS VERSION not supported. Available only on 15 and 12-SP4";
    }

    # Clone Trex repo inside VSPerf directories
    record_info("Clone TREX");
    assert_script_run("cd /root/vswitchperf/src/trex; make", timeout => 200);

    # Copy VSPERF custom configuration files
    record_info("Copy config");
    assert_script_run("curl " . data_url('nfv/conf/00_common.conf') . " -o /root/vswitchperf/conf/00_common.conf");
    assert_script_run("curl " . data_url('nfv/conf/01_testcases.conf') . " -o /root/vswitchperf/conf/01_testcases.conf");
    assert_script_run("curl " . data_url('nfv/conf/02_vswitch.conf') . " -o /root/vswitchperf/conf/02_vswitch.conf");
    assert_script_run("curl " . data_url('nfv/conf/03_traffic.conf') . " -o /root/vswitchperf/conf/03_traffic.conf");
    assert_script_run("curl " . data_url('nfv/conf/04_vnf.conf') . " -o /root/vswitchperf/conf/04_vnf.conf");
    assert_script_run("curl " . data_url('nfv/conf/05_collector.conf') . " -o /root/vswitchperf/conf/05_collector.conf");
    assert_script_run("curl " . data_url('nfv/conf/06_pktfwd.conf') . " -o /root/vswitchperf/conf/06_pktfwd.conf");
    assert_script_run("curl " . data_url('nfv/conf/07_loadgen.conf') . " -o /root/vswitchperf/conf/07_loadgen.conf");
    assert_script_run("curl " . data_url('nfv/conf/08_llcmanagement.conf') . " -o /root/vswitchperf/conf/08_llcmanagement.conf");
    assert_script_run("curl " . data_url('nfv/conf/10_custom.conf') . " -o /root/vswitchperf/conf/10_custom.conf");
    assert_script_run("sed -i 's/trafficgen_ip/$trafficgen_ip/' -i /root/vswitchperf/conf/10_custom.conf");

    record_info("Wait NFV_TRAFFICGEN_READY");
    mutex_wait('NFV_TRAFFICGEN_READY', $child_id);

    if (check_var('BACKEND', 'ipmi')) {
        # Generate ssh keypair and ssh-copy-id to the Traffic generator machine
        record_info("SSH KEY");
        assert_script_run('ssh-keygen -b 2048 -t rsa -q -N "" -f ~/.ssh/id_rsa');
        exec_and_insert_password("ssh-copy-id -o StrictHostKeyChecking=no root\@$trafficgen_ip");

        # Bring mellanox interfaces up
        record_info("Interfaces up");
        assert_script_run("ip link set dev eth2 up");
        assert_script_run("ip link set dev eth3 up");
    }

    record_info("Stop Firewall");
    systemctl 'stop ' . $self->firewall;

    record_info("Installation ready");
    mutex_create("NFV_VSPERF_READY");
}

sub test_flags {
    return {fatal => 1};
}

1;
