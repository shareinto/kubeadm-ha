#/bin/bash

set -e

function render_kubeadm_config()
{
  echo """apiVersion: kubeadm.k8s.io/v1alpha2
kind: MasterConfiguration
kubernetesVersion: v${1}
apiServerCertSANs:
${2}
api:
  controlPlaneEndpoint: "${10}:6443"
kubeProxy:
  config:
    mode: ipvs
etcd:
  local:
    extraArgs:
      listen-client-urls: https://127.0.0.1:2379,https://${3}:2379
      advertise-client-urls: https://${3}:2379
      listen-peer-urls: https://${3}:2380
      initial-advertise-peer-urls: https://${3}:2380
      initial-cluster: ${4}
      initial-cluster-state: ${5}
    serverCertSANs:
      - ${3}
    peerCertSANs:
      - ${3}
networking:
  podSubnet: ${6}
  serviceSubnet: ${11}
#see https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-init/#custom-images
imageRepository: ${7}
""" > ${8}

}

function render_health_check()
{
  for ip in ${1}; do
    HEALTH_CHECK=${HEALTH_CHECK}"""
      real_server ${ip} 6443 {
          weight 1
          SSL_GET {
              url {
                path /healthz
                status_code 200
              }
              connect_timeout 3
              nb_get_retry 3
              delay_before_retry 3
          }
      }
  """
  done
}

PRIORITY=100

function render_keepalived_config()
{
     echo """
   global_defs {
      router_id LVS_DEVEL
   }
   
   vrrp_instance VI_1 {
       state MASTER
       interface ${1}
       virtual_router_id 80
       priority ${PRIORITY}
       advert_int 1
       authentication {
           auth_type PASS
           auth_pass just0kk
       }
       virtual_ipaddress {
           ${2}
       }
   }
   
   virtual_server ${2} 6443 {
       delay_loop 6
       lb_algo rr
       lb_kind NAT
       persistence_timeout 50
       protocol TCP
   
   ${3}
   }
   """ > ${4}
   PRIORITY=$((${PRIORITY}-1))
}

if [ -f ./cluster-info ]; then
	source ./cluster-info 
fi

mkdir -p ~/ikube/tls

HOSTS=${MAIN_PLANE_IP}" "${CONTROL_PLANE_IPS}
IPS=${MAIN_PLANE_IP}" "${CONTROL_PLANE_IPS}
VK8S=$(echo ${KUBE_VERSION} |awk -F "v" -F "-" '{print $1}')
HEALTH_CHECK=""
SANS="- "${MAIN_PLANE_IP}"
- ${VIP}"
for ip in ${CONTROL_PLANE_IPS}; do
  SANS=${SANS}"""
- ${ip}"""
done
ETCD_MEMBER="${MAIN_PLANE_IP}=https://${MAIN_PLANE_IP}:2380"

mkdir -p /etc/keepalived
render_kubeadm_config ${VK8S} "${SANS}" ${MAIN_PLANE_IP} ${ETCD_MEMBER} "new" ${POD_CIDR} ${IMAGE_REPOSITORY} "/etc/kubernetes/kubeadm-config.yaml" ${ETCD_IMAGE} ${VIP} ${SERVICE_CIDR}
render_health_check "${IPS}"
render_keepalived_config ${NET_IF} ${VIP} "${HEALTH_CHECK}" "/etc/keepalived/keepalived.conf"
sudo yum install keepalived -y
sudo systemctl enable keepalived
sudo systemctl restart keepalived
sudo kubeadm reset -f
sudo rm -rf /etc/kubernetes/pki/
sudo kubeadm init --config=/etc/kubernetes/kubeadm-config.yaml
sudo mkdir -p /root/.kube
sudo cp -f /etc/kubernetes/admin.conf /root/.kube/config

rm -rf /root/ikube
mkdir -p /root/ikube

for ip in ${CONTROL_PLANE_IPS}; do
    ssh ${ip} "
    mkdir -p /etc/keepalived
    yum install keepalived -y"
    render_keepalived_config ${NET_IF} ${VIP} "${HEALTH_CHECK}" "/root/ikube/keepalived-${ip}.conf"
    scp /root/ikube/keepalived-${ip}.conf ${ip}:/etc/keepalived/keepalived.conf
    ETCD_STATUS="existing"
    ETCD_MEMBER="${ETCD_MEMBER},${ip}=https://${ip}:2380"
    render_kubeadm_config ${VK8S} "${SANS}" ${ip} ${ETCD_MEMBER} ${ETCD_STATUS} ${POD_CIDR} ${IMAGE_REPOSITORY} "/root/ikube/kubeadm-config-m${ip}.yaml" ${ETCD_IMAGE} ${VIP} ${SERVICE_CIDR}
    scp /root/ikube/kubeadm-config-m${ip}.yaml ${ip}:/etc/kubernetes/kubeadm-config.yaml
    ssh ${ip} "
    systemctl enable keepalived
    systemctl restart keepalived
    kubeadm reset -f
    rm -rf /etc/kubernetes/pki/"
done


ETCD=`kubectl get pods -n kube-system 2>&1|grep etcd|awk '{print $3}'`
echo "Waiting for etcd bootup..."
while [ "${ETCD}" != "Running" ]; do
  sleep 1
  ETCD=`kubectl get pods -n kube-system 2>&1|grep etcd|awk '{print $3}'`
done

for ip in ${CONTROL_PLANE_IPS}; do
  ssh ${ip} "mkdir -p /etc/kubernetes/pki/etcd"
  scp /etc/sysconfig/kubelet ${ip}:/etc/sysconfig/kubelet
  scp /etc/kubernetes/pki/ca.crt ${ip}:/etc/kubernetes/pki/ca.crt
  scp /etc/kubernetes/pki/ca.key ${ip}:/etc/kubernetes/pki/ca.key
  scp /etc/kubernetes/pki/sa.key ${ip}:/etc/kubernetes/pki/sa.key
  scp /etc/kubernetes/pki/sa.pub ${ip}:/etc/kubernetes/pki/sa.pub
  scp /etc/kubernetes/pki/front-proxy-ca.crt ${ip}:/etc/kubernetes/pki/front-proxy-ca.crt
  scp /etc/kubernetes/pki/front-proxy-ca.key ${ip}:/etc/kubernetes/pki/front-proxy-ca.key
  scp /etc/kubernetes/pki/etcd/ca.crt ${ip}:/etc/kubernetes/pki/etcd/ca.crt
  scp /etc/kubernetes/pki/etcd/ca.key ${ip}:/etc/kubernetes/pki/etcd/ca.key
  scp /etc/kubernetes/admin.conf ${ip}:/etc/kubernetes/admin.conf
  kubectl exec \
    -n kube-system etcd-${MAIN_PLANE_IP} -- etcdctl \
    --ca-file /etc/kubernetes/pki/etcd/ca.crt \
    --cert-file /etc/kubernetes/pki/etcd/peer.crt \
    --key-file /etc/kubernetes/pki/etcd/peer.key \
    --endpoints=https://${MAIN_PLANE_IP}:2379 \
    member add ${ip} https://${ip}:2380

  ssh ${ip} "
    kubeadm alpha phase certs all --config /etc/kubernetes/kubeadm-config.yaml
    kubeadm alpha phase kubeconfig controller-manager --config /etc/kubernetes/kubeadm-config.yaml
    kubeadm alpha phase kubeconfig scheduler --config /etc/kubernetes/kubeadm-config.yaml
    kubeadm alpha phase kubelet config write-to-disk --config /etc/kubernetes/kubeadm-config.yaml
    kubeadm alpha phase kubelet write-env-file --config /etc/kubernetes/kubeadm-config.yaml
    kubeadm alpha phase kubeconfig kubelet --config /etc/kubernetes/kubeadm-config.yaml
    systemctl restart kubelet
    kubeadm alpha phase etcd local --config /etc/kubernetes/kubeadm-config.yaml
    kubeadm alpha phase kubeconfig all --config /etc/kubernetes/kubeadm-config.yaml
    kubeadm alpha phase controlplane all --config /etc/kubernetes/kubeadm-config.yaml
    kubeadm alpha phase mark-master --config /etc/kubernetes/kubeadm-config.yaml"
done

ETCD_SERVERS="etcd-servers=https:\/\/${MAIN_PLANE_IP}:2379"
for ip in ${CONTROL_PLANE_IPS}; do
  ETCD_SERVERS=${ETCD_SERVERS}",https:\/\/${ip}:2379"
done

sed -i "s/etcd-servers=https:\/\/127.0.0.1:2379/${ETCD_SERVERS}/g" /etc/kubernetes/manifests/kube-apiserver.yaml

for ip in ${CONTROL_PLANE_IPS}; do
  ssh ${ip} "sed -i 's/etcd-servers=https:\/\/127.0.0.1:2379/${ETCD_SERVERS}/g' /etc/kubernetes/manifests/kube-apiserver.yaml"
done

POD_UNREADY=`kubectl get pods -n kube-system 2>&1|awk '{print $3}'|grep -vE 'Running|STATUS'`
NODE_UNREADY=`kubectl get nodes 2>&1|awk '{print $2}'|grep 'NotReady'`
while [ "${POD_UNREADY}" != "" -o "${NODE_UNREADY}" != "" ]; do
  sleep 1
  POD_UNREADY=`kubectl get pods -n kube-system 2>&1|awk '{print $3}'|grep -vE 'Running|STATUS'`
  NODE_UNREADY=`kubectl get nodes 2>&1|awk '{print $2}'|grep 'NotReady'`
done

echo

kubectl get cs
kubectl get nodes
kubectl get pods -n kube-system

