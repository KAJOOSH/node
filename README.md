# Marzban Node

## New installations

Run the installer on an Ubuntu host. It supports x86-64 and ARM64 and installs the latest published HaGeZi TIF Medium release alongside the Xray assets.

```bash
wget -O install-node.sh https://raw.githubusercontent.com/KAJOOSH/node/main/install-node.sh && bash install-node.sh
```

## Existing installations

Run this on each host running a node. The script downloads and verifies the latest list, then restarts the node and checks that the container can read the file. Connections through that node may briefly drop during the restart.

```bash
wget -O update-tif-medium.sh https://raw.githubusercontent.com/KAJOOSH/node/main/update-tif-medium.sh && sudo bash update-tif-medium.sh
```

If Docker finds multiple nodes, run `sudo bash update-tif-medium.sh --container NAME` for each one. The assets directory must be mounted persistently. Use `--assets-dir /path/to/xray/assets` for a file-only update.

## Enable blocking

Make `hagezi-tif.dat` available to the panel's Xray core and every node that receives the same routing configuration. The [HaGeZi Xray release](https://github.com/KAJOOSH/hagezi-xray-geosite/releases/latest) also provides the file for the panel's assets folder.

In the panel's Xray configuration, add this object to `routing.rules` above any general allow rules. Use the tag of your `blackhole` outbound in place of `BLOCK` if it differs.

```json
{
  "type": "field",
  "domain": ["ext:hagezi-tif.dat:tif-medium"],
  "outboundTag": "BLOCK"
}
```

Save and apply the configuration. When you update the panel’s copy later, reload its Xray core.

## Other scripts

- [Legacy ARM64 installer](install-node-arm64.sh). Use the existing-installation command above to add TIF Medium.

#### block-all-except-iran
```bash
wget https://raw.githubusercontent.com/KAJOOSH/node/refs/heads/main/block-all-except-iran.sh && chmod +x block-all-except-iran.sh && bash block-all-except-iran.sh
```
#### xray-update
```bash
wget https://raw.githubusercontent.com/KAJOOSH/node/main/xray-update.sh && chmod +x xray-update.sh && bash xray-update.sh
```
#### install-warp
```bash
wget https://raw.githubusercontent.com/KAJOOSH/node/refs/heads/main/warp/install-warp.sh && chmod +x install-warp.sh && bash install-warp.sh
```
#### enable_root_ssh_key
```bash
wget https://raw.githubusercontent.com/KAJOOSH/node/refs/heads/main/enable_root_ssh_key_SAFE.sh && sudo chmod +x enable_root_ssh_key_SAFE.sh && sudo bash enable_root_ssh_key_SAFE.sh
```
#### IPv6 disable
```bash
wget https://raw.githubusercontent.com/KAJOOSH/node/refs/heads/main/IPv6-disable.sh && sudo chmod +x IPv6-disable.sh && sudo bash IPv6-disable.sh
```
