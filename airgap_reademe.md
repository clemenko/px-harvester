# Hauler All the Pure/Portworx Things

This guide will show how we can easily air gap all the Pure and Portworx bits. We are going to use a tool from Rancher Gov called Hauler. Currently we are not using all the features of Hauler. This is one of the goals.

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
      name: px_versions.txt
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
