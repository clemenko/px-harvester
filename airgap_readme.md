# Hauler All the Pure/Portworx Things

This guide will show how we can easily air gap all the Pure and Portworx bits for Harvester. It is heavily based on https://docs.portworx.com/portworx-csi/install/airgapped-install#configure-portworx-version-manifest. We are going to use a tool from Rancher Gov called Hauler. Currently we are not using all the features of Hauler. This guide is using the FlashArray as the target storage device. There a few things we will need to connect. An API token for the `pureuser`, the ip address, a linux host with internet access, and a linux host with access to the array.

## install hauler - INTERNET side

We are going to use the linux server with internet access. We will collect and tar the bits we need. Using Hauler as the swiss army knife for collecting and serving files across an air gap. https://docs.hauler.dev/docs/intro

`curl -sfL https://get.hauler.dev | bash`

### generate hauler yaml and sync

Ww are going to generate the hauler manifest yaml. A good idea is to save that to version control for use repeatability.

```bash
mkdir -p /opt/pure; cd /opt/pure
cat << EOF > /opt/pure/airgap.yaml
apiVersion: content.hauler.cattle.io/v1
kind: Files
metadata:
  name: pure-files
spec:
  files:
    #- path: https://releases.purestorage.com/flasharray/purity/6.9.0/purity_6.9.0_202507150448%2Bdd9281824b54.ppkg
    #- path: https://releases.purestorage.com/flasharray/purity/6.9.0/purity_6.9.0_202507150448%2Bdd9281824b54.ppkg.sha1
    #- path: https://raw.githubusercontent.com/PureStorage-OpenConnect/pure-fa-openmetrics-exporter/refs/heads/master/extra/grafana/grafana-purefa-flasharray-overview.json
    #- path: https://static.pure1.purestorage.com/vm-analytics-collector/pure-vmware-appliance-latest-signed.ova
    #- path: https://static.pure1.purestorage.com/vm-analytics-collector/purestorage-ova-latest.iso
    - path: https://install.portworx.com/25.8.0/version?kbver=1.32.8
      name: versions.yaml
    - path: https://install.portworx.com/?comp=pxoperator&oem=px-csi&kbver=1.32.3&ns=portworx
      name: operator.yaml
    - path: https://raw.githubusercontent.com/clemenko/px-harvester/refs/heads/main/readme.md
      name: px_harvester.md
    - path: https://raw.githubusercontent.com/clemenko/px-harvester/refs/heads/main/StorageCluster_example.yaml
    - path: https://raw.githubusercontent.com/clemenko/px-harvester/refs/heads/main/airgap_reademe.md
    - path: https://cloud-images.ubuntu.com/minimal/releases/plucky/release/ubuntu-25.04-minimal-cloudimg-amd64.img
---
apiVersion: content.hauler.cattle.io/v1
kind: Charts
metadata:
  name: portworx-charts
spec:
  charts:
    - name: portworx
      repoURL: http://charts.portworx.io/ 
---
apiVersion: content.hauler.cattle.io/v1
kind: Images
metadata:
  name: rancher-images
  annotations:
    hauler.dev/platform: linux/amd64
spec:       
  images:
EOF

for i in $(curl -s https://install.portworx.com/25.8.0/images); do echo "    - name: "$i >> /opt/pure/airgap.yaml ; done
```

Now we can sync and create the local hauler store. This can take a minute or two depending on the images.

`hauler store sync -f /opt/pure/airgap.yaml`

Add local pdfs if needed.

```bash
hauler store add file user_guides_for_vsphere_plugin.pdf
hauler store add file Dark_site_FA_Install_guide.pdf
```

Validate the local store

`hauler store info`

Add the Hauler binary to the `/opt/pure` directory.

`rsync -avP /usr/local/bin/hauler /opt/pure/hauler`

compress

`tar -cf /opt/pure_airgap_$(date '+%m_%d_%y').tar $(ls)`

---

## Move the Tar

This will highly depend on your network and security levels. Diode, DVD, BluRay, or even Thumbdrive are all options. Just get the tarball over to the air-gapped side.

---

## Unpack and Serve - Air Gap side

Once you have the tar on the air gapped side we need to uncompress it on the linux host.

```bash
mkdir -p /opt/pure/cert
tar -vxf pure_airgap_$(date '+%m_%d_%y').tar -C /opt/pure
cd /opt/pure
```

This is a step that may not be necessary. If you want to push the images to an internal registry you can use the command:

`hauler store sync --filename <file-name> --platform <platform> --key <cosign-public-key> --registry <registry-url>`  

Docs : https://docs.hauler.dev/docs/hauler-usage/store/sync

### serve all the things

Hauler makes it fairly easy serve out the files and even the images if needed. We can take advantage of systemd and create 2 "services". The registry service will create it's own self signed cert.

```bash

# we need the ip of this host
export HAULER_IP=192.168.1.216
openssl req -x509 -newkey rsa:4096 -keyout /opt/pure/cert/key.pem -out /opt/pure/cert/cert.pem -sha256 -days 3650 -nodes -subj "/C=US/ST=Maryland/L=Edgewater/O=PureStorage/OU=FluxDepartment/CN=$HAULER_IP"

# create systemd files
cat << EOF > /etc/systemd/system/hauler-fileserver.service
# /etc/systemd/system/hauler-fileserver.service
[Unit]
Description=Hauler Serve FileServer Service

[Service]
Environment="HOME=/opt/pure/"
ExecStart=/usr/local/bin/hauler store serve fileserver -s /opt/pure/store
WorkingDirectory=/opt/pure/
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

cat << EOF > /etc/systemd/system/hauler-registry.service
# /etc/systemd/system/hauler-registry.service
[Unit]
Description=Hauler Serve Registry Service

[Service]
Environment="HOME=/opt/pure/"
ExecStart=/usr/local/bin/hauler store serve registry -s /opt/pure/store --tls-cert /opt/pure/cert/cert.pem --tls-key /opt/pure/cert/key.pem 
WorkingDirectory=/opt/pure/
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

#reload daemon
systemctl daemon-reload

# start fileserver
systemctl enable --now hauler-fileserver.service

# start reg
systemctl enable --now hauler-registry.service
```

We can now navigate to the IP:8080 to see the files on the webserver. And check port 5000 for the registry. If it is not working we can run `ss -tln` to see if ports 8080, and 5000 are open. If not we can run `journalctl -xefu hauler-registry` or `journalctl -xefu hauler-fileserver` to see why.

## Install PX on Harvester

Now we need a machine with a kubeconfig talking directly to harvester. We can go to the support page in the harvester gui to download one. Harvester will need to add multipathd.

### multipathd

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

Reboot the nodes to make sure this takes effect.

### add registries field for rke2/harvester

We need to tell the container engine on the node to skip verifying the tls cert for the registry. I added the code for rke2 since it is similar. Skip this for harvester.

```bash
# this is for RKE2 ONLY
export HAULER_IP=192.168.1.216
echo -e "mirrors:\n  \"$HAULER_IP:5000\":\n    endpoint:\n      - $HAULER_IP:5000\nconfigs:\n  \"$HAULER_IP:5000\":\n    tls:\n      InsecureSkipVerify: true" > /etc/rancher/rke2/registries.yaml 
```

For Harvester here is the config from the GUI : https://docs.harvesterhci.io/v1.3/advanced/index/#containerd-registry OR:

```bash
cat << EOF | kubectl apply -f -
apiVersion: harvesterhci.io/v1beta1
kind: Setting
metadata:
  name: containerd-registry
value: '{"Mirrors":{"$HAULER_IP:5000":{"Endpoints":["$HAULER_IP"],"Rewrites":null}},"Configs":{"$HAULER_IP:5000":{"Auth":null,"TLS":{"CAFile":"","CertFile":"","KeyFile":"","InsecureSkipVerify":true}}},"Auths":null}'
EOF
```

### add operator - from jump box with kubectl access

We need to create the namespace and add the secret with the API token. Go to the GUI and create the user token. This is from the pureuser account. We also need to change the IP address from the

```bash
# set ip of hauler node
export PURE_MGNT_VIP=192.168.1.11

# create ns
kubectl create ns portworx

# create secret with API token 
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

# add config map for versions
kubectl -n portworx create configmap px-versions --from-literal=versions.yaml="$(curl -s http://$HAULER_IP:8080/versions.yaml)"

# add operator yaml
curl -s http://$HAULER_IP:8080/operator.yaml | sed "s#portworx/px-operator#$HAULER_IP:5000/portworx/px-operator#g" | kubectl apply -f -
```

### add StorageCluster object

This step gets a little tricky. We need to get the file [StorageCluster_example.yaml](StorageCluster_example.yaml) from the hauler server and modify it. We will need to modify `customImageRegistry` to point to the correct hauler ip. Here is an example.

```yaml
# this is an example storagecluster yaml for air gapped installs
kind: StorageCluster
apiVersion: core.libopenstorage.org/v1
metadata:
  name: px-cluster
  namespace: portworx
  annotations:
    portworx.io/misc-args: "--oem px-csi"
#    portworx.io/health-check: "skip"
spec:
  image: portworx/px-pure-csi-driver:25.8.0
  imagePullPolicy: IfNotPresent
  customImageRegistry: X.X.X.X
  # imagePullSecret: px-reg-secret
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
```

We can cheat a little and script this and apply it.

```bash
# get the yaml and change the ip
curl -s http://$HAULER_IP:8080/StorageCluster_example.yaml | sed "s/X.X.X.X/$HAULER_IP:5000/g" | kubectl apply -f -

# and watch for a little while. It may take some time for everything to be running.
watch -n 5 kubectl get pod -n portworx
```

### add image to Harvester

We need to add an OS image to harvester and the array.

```bash
cat << EOF | kubectl apply -f -
apiVersion: harvesterhci.io/v1beta1
kind: VirtualMachineImage
metadata:
  name: fa-plucky
  namespace: default
  annotations:
    harvesterhci.io/storageClassName: px-fa-direct-access
spec:
  backend: cdi
  displayName: fa-plucky
  retry: 3
  sourceType: download
  targetStorageClassName: px-fa-direct-access
  url: http://$HAULER_IP:8080/ubuntu-25.04-minimal-cloudimg-amd64.img
EOF
```

Now deploy a VM.
