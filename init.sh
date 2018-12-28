#!/bin/bash

# shutdown firewalld
systemctl stop firewalld
systemctl disable firewalld

# disable selinux
setenforce 0 > /dev/null 2>&1
sed -i "s/SELINUX=enforcing/SELINUX=disabled/g" /etc/selinux/config

# swapoff
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

echo """
vm.swappiness = 0
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
""" > /etc/sysctl.conf
sysctl -p > /dev/null 2>&1

# install ip_vs module
/sbin/modinfo -F filename ip_vs > /dev/null 2>&1
if [ $? -eq 0 ]; then
  /sbin/modprobe ip_vs
fi


