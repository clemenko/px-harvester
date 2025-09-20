# Hauler All the Pure/Portworx Things

This guide will show how we can easily air gap all the Pure and Portworx bits. We are going to use a tool from Rancher Gov called Hauler. Currently we are not using all the features of Hauler. This guide is using the FlashArray as the target storage device. There a few things than need to be changed to connect to a FLashBlade.

## install hauler - internet side

Hauler is a swiss army knife for collecting and serving files across an air gap. https://docs.hauler.dev/docs/intro

`curl -sfL https://get.hauler.dev | bash`

### generate hauler yaml and sync

Ww are going to generate the hauler manifest yaml. A good idea is to save that to version control for use repeatability.

```bash
mkdir -p /opt/pure; cd /opt/pure
cat << EOF > /opt/pure/airgap.yaml
apiVersion: content.hauler.cattle.io/v1
kind: Files
metadata:
  name: purex-files
spec:
  files:
    #- path: https://releases.purestorage.com/flasharray/purity/6.9.0/purity_6.9.0_202507150448%2Bdd9281824b54.ppkg
    #- path: https://releases.purestorage.com/flasharray/purity/6.9.0/purity_6.9.0_202507150448%2Bdd9281824b54.ppkg.sha1
    #- path: https://raw.githubusercontent.com/PureStorage-OpenConnect/pure-fa-openmetrics-exporter/refs/heads/master/extra/grafana/grafana-purefa-flasharray-overview.json
    #- path: https://static.pure1.purestorage.com/vm-analytics-collector/pure-vmware-appliance-latest-signed.ova
    #- path: https://static.pure1.purestorage.com/vm-analytics-collector/purestorage-ova-latest.iso
    - path: https://install.portworx.com/25.6.0/version?kbver=1.32.8
      name: versions.yaml
    - path: https://install.portworx.com/?comp=pxoperator&oem=px-csi&kbver=1.32.3&ns=portworx
      name: operator.yaml
    - path: https://raw.githubusercontent.com/clemenko/px-harvester/refs/heads/main/readme.md
      name: px_harvester.md
    - path: https://raw.githubusercontent.com/clemenko/px-harvester/refs/heads/main/StorageCluster_example.yaml
    - path: https://raw.githubusercontent.com/clemenko/px-harvester/refs/heads/main/airgap_reademe.md

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

for i in $(curl -s https://install.portworx.com/25.6.0/images); do echo "    - name: "$i >> /opt/pure/airgap.yaml ; done

# temp fix for operator
echo "    - name: docker.io/portworx/px-operator:25.3.1" >> /opt/pure/airgap.yaml
```

Now we can sync and create the local hauler store.

`hauler store sync -f /opt/pure/airgap.yaml`

Add local pdfs if needed.

```bash
hauler store add file user_guides_for_vsphere_plugin.pdf
hauler store add file Dark_site_FA_Install_guide.pdf
```

Validate the local store

`hauler store info`

Add the Hauler binary

`rsync -avP /usr/local/bin/hauler /opt/pure/hauler`

compress

`tar -cf /opt/pure_airgap_$(date '+%m_%d_%y').tar $(ls)`

---

## Move the Tar

This will highly depend on your network and security levels. Diode, DVD, BluRay, or even Thumbdrive are all options. Just get the tarball over to the air-gapped side.

---

## Unpack and Serve - Air Gap side

Once you have the tar on the air gapped side we need to uncompress it.

```bash
mkdir /opt/pure
tar -vxf pure_airgap_$(date '+%m_%d_%y').tar -C /opt/pure
cd /opt/pure
```

This is a step that may not be necessary. If you want to push the images to an internal registry you can use the command: 

`hauler store sync --filename <file-name> --platform <platform> --key <cosign-public-key> --registry <registry-url>`  

Docs : https://docs.hauler.dev/docs/hauler-usage/store/sync

### serve all the things

Hauler makes it fairly easy serve out the files and even the images if needed. We can take advantage of systemd.

```bash
cat << EOF > /etc/systemd/system/hauler@.service
# /etc/systemd/system/hauler.service
[Unit]
Description=Hauler Serve %I Service

[Service]
Environment="HOME=/opt/pure/"
ExecStart=/usr/local/bin/hauler store serve %i -s /opt/pure/store
WorkingDirectory=/opt/pure/
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

#reload daemon
systemctl daemon-reload

# start fileserver
systemctl enable --now hauler@fileserver 

# start reg
systemctl enable --now hauler@registry
```

We can now navigate to the IP:8080 to see the files on the webserver. And check port 5000 for the registry.

### Install PX

If you are using Harvester we need to add multipathd.

#### multipathd

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

#### add registries field for rke2/harvester

We need to tell the container engine to connect with http and not https. This MAY need to be run ON the node itself.

```bash
export HAULER_IP=192.168.1.185
echo -e "mirrors:\n  \"$HAULER_IP:5000\":\n    endpoint:\n      - http://$HAULER_IP:5000\nconfigs:\n  "*":\n    tls:\n      insecure_skip_verify: true" > /etc/rancher/rke2/registries.yaml 
```

For Harvester here is the config from the GUI : https://docs.harvesterhci.io/v1.3/advanced/index/#containerd-registry OR:

```bash
export HAULER_IP=192.168.1.185
cat << EOF | kubectl apply -f -
apiVersion: harvesterhci.io/v1beta1
kind: Setting
metadata:
  name: containerd-registry
value: '{"Mirrors":{"$HAULER_IP:5000":{"Endpoints":["http://$HAULER_IP:5000"],"Rewrites":null}},"Configs":null,"Auths":null}'
EOF
```

#### add operator - from jump box with kubectl access

We need to create the namespace and add the secret with the API token. Go to the GUI and create the user token. This is from the pureuser account. We also need to change the IP address from the

```bash
# set ip of hauler node
export HAULER_IP=192.168.1.185
export PURE_MGNT_VIP=192.168.1.11

# create ns
kubectl create ns portworx

# create secret with API token 
kubectl create secret generic px-pure-secret -n portworx --from-literal=pure.json="{FlashArrays: [{MgmtEndPoint: $PURE_MGNT_VIP, APIToken: 934f95b6-6d1d-ee91-d210-6ed9bce13ad1}]}"

# add config map for versions
kubectl -n portworx create configmap px-versions --from-literal=versions.yaml="$(curl -s http://$HAULER_IP:8080/versions.yaml)"

# add operator yaml
curl -s http://$HAULER_IP:8080/operator.yaml | sed "s#portworx/px-operator#$HAULER_IP:5000/portworx/px-operator#g" | kubectl apply -f -
```

#### add StorageCluster object

This step gets a little tricky. We need to get the file [StorageCluster_example.yaml](http://192.168.1.185:8080/StorageCluster_example.yaml) from the hauler server and modify it. We will need to modify `customImageRegistry` to point to the correct hauler ip.

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
  image: portworx/oci-monitor:25.6.0
  imagePullPolicy: IfNotPresent
  customImageRegistry: X.X.X.X
  # imagePullSecret: px-reg-secret
  kvdb:
    internal: true
  cloudStorage:
    kvdbDeviceSpec: size=20
  stork:
    enabled: false
  security:
    enabled: false
  csi:
    enabled: true
    installSnapshotController: true
  monitoring:
    telemetry:
      enabled: false
    prometheus:
      enabled: true
      exportMetrics: true
  env:
  - name: PURE_FLASHARRAY_SAN_TYPE
    value: "ISCSI"
```

We can cheat a little and script this and apply it.

```bash
# get the yaml and change the ip
curl -s http://$HAULER_IP:8080/StorageCluster_example.yaml | sed "s/X.X.X.X/$HAULER_IP:5000/g" | kubectl apply -f -

# and watch for 15 mintues
watch -n 5 kubectl get pod -n portworx
```




