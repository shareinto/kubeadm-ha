#!/bin/bash

#check selinux

source ./cluster-info
./init.sh

declare -A dic

dic=()

SELINUX=$(getenforce)
if [ ${SELINUX} != "Enforcing" ];then
  dic+=([selinux]=true)
else
  dic+=([selinux]=false)
fi

SWAP=$(swapon -s | wc -l)
if [ ${SWAP} -eq "0" ];then
  dic+=([swap]=true)
else
  dic+=([swap]=false)
fi

IPV4_FORWARD=$(sysctl net.ipv4.ip_forward | awk '{print $3}')
if [ ${IPV4_FORWARD} -eq "1" ];then
  dic+=([ipv4_forward]=true)
else
  dic+=([ipv4_forward]=false)
fi


KERNEL_MAJOR=$(uname -r|awk -F "." '{print $1}')
KERNEL_MINOR=$(uname -r|awk -F "." '{print $2}')
kernel=$(echo ${KERNEL_MAJOR}.${KERNEL_MINOR} | awk '{if ($0 < 4.1) print "false"; else print "true"}')
dic+=([kernel]=${kernel})

ipvs_modules="ip_vs"
for kernel_module in ${ipvs_modules}; do
 cnt=$(lsmod | awk '{print $1}' | grep -w "${kernel_module}" | wc -l)
 if [ ${cnt} -ne 1 ]; then
   dic+=(["${kernel_module}"]=false)
 else
   dic+=(["${kernel_module}"]=true)
 fi
done

systemctl start docker
docker info > /dev/null 2>&1
if [ $? -eq 0 ];then
  dic+=([docker]=true)
else
  dic+=([docker]=false)
fi

kubeadm > /dev/null 2>&1
if [ $? -eq 0 ];then
  dic+=([kubeadm]=true)
else
  dic+=([kubeadm]=false)
fi

for key in $(echo ${!dic[*]})
do
  echo "$key is ${dic[$key]}"
done

if [ ${dic["kernel"]} = "false" ];then
  ./kernel.sh
fi

if [ ${dic["docker"]} = "false" ];then
 ./docker.sh
fi

if [ ${dic["kubeadm"]} = "false" ];then
  ./kubeadm.sh
fi



