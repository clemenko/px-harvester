# PX + Harvester

This is a quick guide for adding Portworx CSI ( PX-CSI 25.8.1 ) to Harvester.

Based on https://docs.harvesterhci.io/v1.6/advanced/csidriver/.

Currently only [v1.6.1](https://github.com/harvester/harvester/releases/tag/v1.6.1) and above supports remote booting.

Please also check out https://dzver.rfed.io for the last versions of all these components.

tl:dr - Add multipathd. Add PX CSI, that points to an FA, to the Harvester cluster. Patch `storageprofile` for known issue.

## Install Harvester

Install Harvester on your favorite hardware.

## run harvester_setup.sh

run the attached script for easy setup of images and networking.

```bash
# my notes
./harvester_setup.sh && mv 192.168.1.12.yaml ~/Dropbox/work/rfed.me/slim.yaml
```

## add multipathd

to all the harvester nodes

```bash
cat << EOF | kubectl apply -f -
apiVersion: node.harvesterhci.io/v1beta1
kind: CloudInit
metadata:
  name: multipathd-start
spec:
  matchSelector: {}
  filename: 99_multipathd.yaml
  contents: |
    stages:
      network:
      - name: "Configure multipathd"
        files:
        - path: /etc/multipath.conf
          content: |
            devices {
                device {
                    vendor                      "NVME"
                    product                     "Pure Storage FlashArray"
                    path_selector               "queue-length 0"
                    path_grouping_policy        group_by_prio
                    prio                        ana
                    failback                    immediate
                    fast_io_fail_tmo            10
                    user_friendly_names         no
                    no_path_retry               0
                    features                    0
                    dev_loss_tmo                60
                }
                device {
                    vendor                   "PURE"
                    product                  "FlashArray"
                    path_selector            "service-time 0"
                    hardware_handler         "1 alua"
                    path_grouping_policy     group_by_prio
                    prio                     alua
                    failback                 immediate
                    path_checker             tur
                    fast_io_fail_tmo         10
                    user_friendly_names      no
                    no_path_retry            0
                    features                 0
                    dev_loss_tmo             600
                }
            }
            blacklist_exceptions {
                property "(SCSI_IDENT_|ID_WWN)"
            }
            blacklist {
                devnode "^pxd[0-9]*"
                devnode "^pxd*"
                device {
                    vendor "VMware"
                    product "Virtual disk"
                }
                device {
                    vendor "IET"
                    product "VIRTUAL-DISK"
                }
            }
          permissions: 0744
      - name: "Start multipathd service"
        systemctl:
          enable:
          - multipathd
          start:
          - multipathd
EOF
```

reboot the nodes to make sure this takes effect.

## add portworx stuff

Here we are going to install the CSI. Note the API token for a "storage admin" user. Here are the docs : https://docs.portworx.com/portworx-enterprise/platform/kubernetes/flasharray/install/install-flasharray/install-flasharray-cd-da

```bash

# get latest version of PX-CSI
PX_CSI_VER=$(curl -sL https://dzver.rfed.io/json | jq -r .portworx)

# create namespace
kubectl create ns portworx

# create and add secret
cat << EOF > pure.json 
{
    "FlashArrays": [
        {
            "MgmtEndPoint": "192.168.1.11",
            "APIToken": "934f95b6-6d1d-ee91-d210-6ed9bce13ad1"
        }
    ]
}
EOF
kubectl create secret generic px-pure-secret -n portworx --from-file=pure.json=pure.json

# apply operator yaml
kubectl apply -f 'https://install.portworx.com/'$PX_CSI_VER'comp=pxoperator&oem=px-csi&kbver=1.33.5&ns=portworx'

# add annotation of "portworx.io/health-check: "skip" " for running on a single node

#  If you want nvme-tcp change the value: "NVMEOF-TCP"

cat << EOF | kubectl apply -n portworx  -f -
kind: StorageCluster
apiVersion: core.libopenstorage.org/v1
metadata:
  name: px-cluster
  namespace: portworx
  annotations:
    portworx.io/misc-args: "--oem px-csi"
    #portworx.io/health-check: "skip"
spec:
  image: portworx/px-pure-csi-driver:$PX_CSI_VER
  imagePullPolicy: IfNotPresent
  csi:
    enabled: true
  monitoring:
    telemetry:
      enabled: false
    prometheus:
      enabled: false
      exportMetrics: false
  env:
  - name: PURE_FLASHARRAY_SAN_TYPE
    value: "ISCSI"
EOF
```

## update csi settings

Update the Harvester CSI settings - https://docs.harvesterhci.io/v1.6/advanced/csidriver/#configure-harvester-cluster.

## add image

```bash
cat << EOF | kubectl apply -f -
apiVersion: harvesterhci.io/v1beta1
kind: VirtualMachineImage
metadata:
  name: fa-questing
  namespace: default
  annotations:
    harvesterhci.io/storageClassName: px-fa-direct-access
spec:
  backend: cdi
  displayName: fa-questing
  retry: 3
  sourceType: download
  targetStorageClassName: px-fa-direct-access
  url: https://cloud-images.ubuntu.com/questing/current/questing-server-cloudimg-amd64.img
EOF
```

Success.
