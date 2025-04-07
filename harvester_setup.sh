#!/usr/bin/env bash
# harvester automation

export RED='\x1b[0;31m'
export GREEN='\x1b[32m'
export BLUE='\x1b[34m'
export YELLOW='\x1b[33m'
export NO_COLOR='\x1b[0m'

# variables
vip=192.168.1.12
longPassword=Pa22word1234#
shortPassword=Pa22word

# key pair
keypair="ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEA26evmemRbhTtjV9szD9SwcFW9VOD38jDuJmyYYdqoqIltDkpUqDa/V1jxLSyrizhOHrlJtUOj790cxrvInaBNP7nHIO+GwC9VH8wFi4KG/TFj3K8SfNZ24QoUY12rLiHR6hRxcT4aUGnqFHGv2WTqsW2sxz03z+W1qeMqWYJOUfkqKKs2jiz42U+0Kp9BxsFBlai/WAXrQsYC8CcpQSRKdggOMQf04CqqhXzt5Q4Cmago+Fr7HcvEnPDAaNcVtfS5DYLERcX2OVgWT3RBWhDIjD8vYCMBBCy2QUrc4ZhKZfkF9aemjnKLfLcbdpMfb+r7NwJsVQSPKcjYAJOckE8RQ== clemenko@clemenko.local"

# set functions for debugging/logging
function info { echo -e "$GREEN[info]$NO_COLOR $1" ;  }
function warn { echo -e "$YELLOW[warn]$NO_COLOR $1" ; }
function fatal { echo -e "$RED[error]$NO_COLOR $1" ; exit 1 ; }
function info_ok { echo -e "$GREEN" "ok" "$NO_COLOR" ; }

#better error checking
command -v curl >/dev/null 2>&1 || { fatal "Curl was not found. Please install" ; }
command -v jq >/dev/null 2>&1 || { fatal "Jq was not found. Please install" ; }
command -v kubectl >/dev/null 2>&1 || { fatal "Kubectl was not found. Please install" ; }

info " - waiting for harvester "
until curl -skf -m 1 --output /dev/null https://$vip/v3-public ; do echo -n  "." ; sleep 10 ; done
sleep 60
info_ok

info " - setting long password"
token=$(curl -sk -X POST https://$vip/v3-public/localProviders/local?action=login -H 'content-type: application/json' -d '{"username":"admin","password":"admin"}' | jq -r .token)

curl -sk https://$vip/v3/users?action=changepassword -H 'content-type: application/json' -H "Authorization: Bearer $token" -d '{"currentPassword":"admin","newPassword":"'$longPassword'"}'
info_ok

# reauthenticate
api_token=$(curl -sk https://$vip/v3/token -H 'content-type: application/json' -H "Authorization: Bearer $token" -d '{"type":"token","description":"automation"}' | jq -r .token)
 
info " - getting kubeconfig"
curl -sk https://$vip/v1/management.cattle.io.clusters/local?action=generateKubeconfig -H "Authorization: Bearer $api_token" -X POST -H 'content-type: application/json' | jq -r .config | sed -e '/certificate-authority-data/,18d' -e '/server/ a\'$'\n''    insecure-skip-tls-verify: true' > $vip.yaml
export KUBECONFIG=$vip.yaml
info_ok

# load password length, image, network, keypair and template
info " - configuring password length, images, network, and keypair"
cat <<EOF | kubectl apply -f -  > /dev/null 2>&1
apiVersion: management.cattle.io/v3
kind: Setting
metadata:
  name: password-min-length
  namespace: cattle-system
value: "8"
---
apiVersion: harvesterhci.io/v1beta1
kind: VirtualMachineImage
metadata:
  name: rocky94
  annotations:
    harvesterhci.io/storageClassName: harvester-longhorn
  labels:
    harvesterhci.io/image-type: raw_qcow2
    harvesterhci.io/os-type: rocky
  namespace: default
spec:
  displayName: rocky94
  retry: 3
  sourceType: download
  storageClassParameters:
    migratable: 'true'
    numberOfReplicas: '3'
    staleReplicaTimeout: '30'
  url: https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2
---
apiVersion: harvesterhci.io/v1beta1
kind: VirtualMachineImage
metadata:
  name: noble
  annotations:
    harvesterhci.io/storageClassName: harvester-longhorn
  labels:
    harvesterhci.io/image-type: raw_qcow2
    harvesterhci.io/os-type: ubuntu
  namespace: default
spec:
  displayName: noble
  retry: 3
  sourceType: download
  storageClassParameters:
    migratable: 'true'
    numberOfReplicas: '3'
    staleReplicaTimeout: '30'
  url: https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-amd64.img
---

apiVersion: harvesterhci.io/v1beta1
kind: KeyPair
metadata:
  name: keypair
  namespace: default
spec:
  publicKey: $keypair

---

apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  annotations:
    network.harvesterhci.io/route: '{"mode":"auto","serverIPAddr":"","cidr":"","gateway":""}'
  name: vlan1
  namespace: default
spec:
  config: '{"cniVersion":"0.3.1","name":"vlan1","type":"bridge","bridge":"mgmt-br","promiscMode":true,"ipam":{}}'
EOF

# delete if you want the long password
# password shortener - one last time
token=$(curl -sk -X POST https://$vip/v3-public/localProviders/local?action=login -H 'content-type: application/json' -d '{"username":"admin","password":"'$longPassword'"}' | jq -r .token)

api_token=$(curl -sk https://$vip/v3/token -H 'content-type: application/json' -H "Authorization: Bearer $token" -d '{"type":"token","description":"automation"}' | jq -r .token)

curl -sk https://$vip/v3/users?action=changepassword -H 'content-type: application/json' -H "Authorization: Bearer $token" -d '{"currentPassword":"'$longPassword'","newPassword":"'$shortPassword'"}'

info Complete