# Marzban Node

## New installations

Run the installer on an Ubuntu host. It supports x86-64 and ARM64 and downloads every HaGeZi Xray package from the latest release in one archive.

```bash
wget -O install-node.sh https://raw.githubusercontent.com/KAJOOSH/node/main/install-node.sh && bash install-node.sh
```

## Existing installations

Run this on each host running a node. The script downloads and verifies the whole archive, then restarts the node once and checks that the container can read every package. Connections through that node may briefly drop during the restart.

```bash
wget -O update-tif-medium.sh https://raw.githubusercontent.com/KAJOOSH/node/main/update-tif-medium.sh && sudo bash update-tif-medium.sh
```

If Docker finds multiple nodes, run `sudo bash update-tif-medium.sh --container NAME` for each one. The assets directory must be mounted persistently. Use `--assets-dir /path/to/xray/assets` for a file-only update.

## Enable blocking

Download the files on the panel and every node that receives its Xray configuration. Allow room for the archive and extracted files. The current bundle needs roughly 650 MiB of working space.

On the panel, use the same updater with the host's Xray assets directory. For example, with the `/var/lib/marzban` directory mounted at the same path in the container:

```bash
curl -fsSL https://raw.githubusercontent.com/KAJOOSH/node/main/update-tif-medium.sh \
  -o update-tif-medium.sh && sudo bash update-tif-medium.sh --assets-dir /var/lib/marzban/assets
```

Choose the packages to activate. In the panel's Xray configuration, add only their rules as separate entries in `routing.rules` above any general allow rules. Use the tag of your `blackhole` outbound in place of `BLOCK` if it differs.

**TIF Medium** blocks listed domains.

```json
{
  "type": "field",
  "domain": ["ext:hagezi-tif.dat:tif-medium"],
  "outboundTag": "BLOCK"
}
```

**TIF IPv4** blocks listed IPv4 addresses.

```json
{
  "type": "field",
  "ip": ["ext:hagezi-tif-ipv4.dat:tif-ipv4"],
  "outboundTag": "BLOCK"
}
```

Save and apply the configuration. When you refresh the files on the panel later, reload its Xray core.

The [HaGeZi package guide](https://github.com/KAJOOSH/hagezi-xray-geosite#packages) has rules for the other packages.

## Other scripts

- [Legacy ARM64 installer](install-node-arm64.sh). Use the existing-installation command above to add the complete package set.

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
