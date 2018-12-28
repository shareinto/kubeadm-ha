#!/bin/bash

rpm -Uvh http://www.elrepo.org/elrepo-release-7.0-2.el7.elrepo.noarch.rpm ;yum --enablerepo=elrepo-kernel install kernel-lt-devel kernel-lt -y
grub2-set-default 0
reboot
