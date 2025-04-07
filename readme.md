# PX + Harvester

This is a quick guide for adding Portworx CSI (px-csi) to Harvester.

Currently only [v1.5.0-rc3](https://github.com/harvester/harvester/releases/tag/v1.5.0-rc3) supports remote booting.

tl:dr - Add multipathd. Add PX CSI, that points to an FA, to the Harvester cluster. Patch `storageprofile` for known issue.

## Install Harvester

Install Harvester on your favorite hardware.

## run harvester_setup.sh

run the attached script for easy setup of images and networking.

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
                    find_multipaths             yes
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
                    find_multipaths          yes
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

Here we are going to install the CSI. Note the API token for a "storage admin" user.

```bash
kubectl create ns portworx

cat << EOF > pure.json 
{
    "FlashArrays": [
        {
            "MgmtEndPoint": "192.168.1.11",
            "APIToken": "3d84e613-c905-649a-2b7a-0bc8def997e9"
        }
    ]
}
EOF

kubectl create secret generic px-pure-secret -n portworx --from-file=pure.json=pure.json

kubectl apply -f 'https://install.portworx.com/3.2?comp=pxoperator&kbver=1.32.3&ns=portworx'

cat << EOF | kubectl apply -n portworx  -f -
kind: StorageCluster
apiVersion: core.libopenstorage.org/v1
metadata:
  name: px-cluster
  namespace: portworx
  annotations:
    portworx.io/misc-args: "--oem px-csi"
    portworx.io/health-check: "skip" 
spec:
  image: portworx/oci-monitor:25.2.0
  imagePullPolicy: IfNotPresent
  kvdb:
    internal: true
  cloudStorage:
    kvdbDeviceSpec: size=10
  stork:
    enabled: false
  csi:
    enabled: true
    installSnapshotController: true
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

cat << EOF | kubectl apply -n portworx  -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: px-csi-snapclass
  annotations:
    snapshot.storage.kubernetes.io/is-default-class: "true"
driver: pxd.portworx.com
deletionPolicy: Delete
parameters:
  csi.openstorage.org/snapshot-type: local
EOF
```

Patch the StorageClass

```bash
kubectl patch storageprofile px-fa-direct-access --type=merge --patch '{"spec": {"claimPropertySets": [{"accessModes": ["ReadWriteMany"], "volumeMode": "Block"}, {"accessModes": ["ReadWriteOnce"], "volumeMode": "Block"}, {"accessModes": ["ReadWriteOnce"], "volumeMode": "Filesystem"}], "cloneStrategy": "csi-clone"}}'
```

## add image

```bash
cat << EOF | kubectl apply -f -
apiVersion: harvesterhci.io/v1beta1
kind: VirtualMachineImage
metadata:
  name: fa-rocky94
  namespace: default
  annotations:
    harvesterhci.io/storageClassName: px-fa-direct-access
spec:
  backend: cdi
  displayName: fa-rocky94
  retry: 3
  sourceType: download
  targetStorageClassName: px-fa-direct-access
  url: https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2
EOF
```

Success.
