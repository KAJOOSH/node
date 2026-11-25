#!/usr/bin/env bash
set -euo pipefail

readonly RELEASES_URL="https://github.com/KAJOOSH/hagezi-xray-geosite/releases"
readonly ARCHIVE="xray-assets.tar.gz"
readonly ASSET_INDEX=".hagezi-assets.sha256"
asset_names=()

usage() {
    cat <<'HELP'
Usage: sudo bash update-tif-medium.sh [--container NAME | --assets-dir PATH]

Run on the host that runs Marzban Node. With no options, the script finds
the marzban-node Compose container, updates all published HaGeZi Xray assets, and restarts it.
Use --container if the host runs multiple nodes or uses a custom service name.
Use --assets-dir to update a known directory without restarting a container.
HELP
}

die() {
    printf 'HaGeZi assets: %s\n' "$*" >&2
    exit 1
}

fetch() {
    local -a network_args=()
    if [[ "${HAGEZI_FORCE_IPV4:-false}" == true ]]; then network_args+=(-4); fi
    curl "${network_args[@]}" -fsSL --retry 3 --connect-timeout 12 --max-time 1800 --speed-time 60 --speed-limit 512 \
        --proto '=https' --proto-redir '=https' "$@"
}

restart_node() {
    local container="$1" asset_dir="$2" status attempt asset
    local -a asset_paths=()
    for asset in "${asset_names[@]}"; do asset_paths+=("$asset_dir/$asset"); done
    printf 'Restarting Marzban Node (%s)...\n' "$container"
    docker container restart -- "$container" >/dev/null \
        || die "Files updated, but Docker could not restart container $container."

    for ((attempt = 1; attempt <= 30; attempt++)); do
        status="$(docker container inspect --format \
            '{{.State.Status}}{{if .State.Health}} {{.State.Health.Status}}{{end}}' -- "$container")" \
            || die "Files updated, but the status of container $container could not be checked."
        if [[ "$status" == running || "$status" == "running healthy" ]] &&
            docker container exec -- "$container" sh -c 'for path; do test -r "$path" || exit 1; done' \
                sh "${asset_paths[@]}" 2>/dev/null; then
            printf 'Marzban Node (%s) is running and can read all installed HaGeZi assets.\n' "$container"
            return 0
        fi
        if (( attempt < 30 )); then sleep 2; fi
    done

    die "Container $container is not ready after restart (state: $status). Check its logs with docker logs."
}

container=""
assets_dir=""
container_assets=""
declare -A mount_targets=()

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    --container)
        [[ $# == 2 && -n "$2" ]] || die "Specify one container name or ID."
        container="$2"
        ;;
    --assets-dir)
        [[ $# == 2 && "$2" == /* ]] || die "Specify an absolute assets directory."
        assets_dir="$2"
        ;;
    "") [[ $# == 0 ]] || die "Use --help for available options." ;;
    *) die "Use --help for available options." ;;
esac
(( EUID == 0 )) || die "Run this script with sudo."
command -v curl >/dev/null || die "Install curl before running this script."
command -v flock >/dev/null || die "Install flock (util-linux) before running this script."
command -v tar >/dev/null || die "Install GNU tar before running this script."

if [[ -z "$assets_dir" ]]; then
    command -v docker >/dev/null || die "Docker is required for discovery. Use --assets-dir to specify the location directly."
    if [[ -z "$container" ]]; then
        container_ids="$(docker ps -a --filter 'label=com.docker.compose.service=marzban-node' --format '{{.ID}}')" \
            || die "Unable to list Docker containers."
        [[ -n "$container_ids" ]] || die "No Marzban Node Compose container found. Specify --container NAME."
        mapfile -t candidates <<< "$container_ids"
        (( ${#candidates[@]} == 1 )) || die "Multiple Marzban Node containers found. Specify --container NAME."
        container="${candidates[0]}"
    fi

    asset_env="$(docker container inspect --format \
        '{{range .Config.Env}}{{if eq (index (split . "=") 0) "XRAY_ASSETS_PATH"}}{{println .}}{{end}}{{end}}' -- "$container")" \
        || die "Unable to inspect Docker container $container."
    container_assets="${asset_env#XRAY_ASSETS_PATH=}"
    container_assets="${container_assets:-/usr/local/share/xray}"
    container_assets="${container_assets%/}"
    [[ "$container_assets" == /* ]] || die "XRAY_ASSETS_PATH must be an absolute container path."

    mounts="$(docker container inspect --format \
        '{{range .Mounts}}{{printf "%s\t%s\t%s\n" .Destination .Type .Source}}{{end}}' -- "$container")" \
        || die "Unable to read mounts for container $container."
    mount_type=""
    mount_source=""
    mount_prefix=""
    while IFS=$'\t' read -r destination type source; do
        [[ -n "$destination" ]] || continue
        mount_targets["$destination"]=1
        prefix="${destination%/}"
        if [[ "$container_assets" == "$prefix" || "$container_assets" == "$prefix/"* ]]; then
            if [[ -z "$mount_type" ]] || (( ${#prefix} > ${#mount_prefix} )); then
                mount_type="$type"
                mount_source="$source"
                mount_prefix="$prefix"
            fi
        fi
    done <<< "$mounts"

    [[ "$mount_type" == bind || "$mount_type" == volume ]] && [[ "$mount_source" == /* ]] \
        || die "Mount a persistent directory at $container_assets and rerun this script."
    assets_dir="$mount_source${container_assets#"$mount_prefix"}"
fi

[[ -d "$assets_dir" ]] || die "Assets directory $assets_dir is missing on this host."
exec {update_lock}>>"$assets_dir/.hagezi-tif.lock" || die "Unable to open the update lock in $assets_dir."
flock -x "$update_lock" || die "Unable to lock the update in $assets_dir."

release_url="$(fetch -o /dev/null -w '%{url_effective}' "$RELEASES_URL/latest")" \
    || die "Unable to find the latest release."
tag="${release_url#"$RELEASES_URL/tag/"}"
[[ "$tag" =~ ^v[0-9]+(\.[0-9]+)+$ ]] || die "Unexpected release URL: $release_url"

work_dir="$(mktemp -d "$assets_dir/.hagezi-assets.XXXXXXXX")" || die "Unable to write to $assets_dir."
trap 'rm -rf -- "$work_dir"' EXIT
payload="$work_dir/payload"
mkdir -- "$payload"

release_base="$RELEASES_URL/download/$tag"
printf 'Downloading all HaGeZi Xray assets from %s...\n' "$tag"
fetch -o "$work_dir/$ARCHIVE.sha256" "$release_base/$ARCHIVE.sha256" \
    || die "Unable to download the archive checksum for $tag."
checksum_text="$(<"$work_dir/$ARCHIVE.sha256")"
[[ "$checksum_text" =~ ^([[:xdigit:]]{64})[[:blank:]]+xray-assets\.tar\.gz$ ]] \
    || die "Invalid archive checksum file."
expected="${BASH_REMATCH[1],,}"
fetch -o "$work_dir/$ARCHIVE" "$release_base/$ARCHIVE" || die "Unable to download the asset archive."
actual="$(sha256sum < "$work_dir/$ARCHIVE")"
[[ "${actual%% *}" == "$expected" ]] || die "The archive failed SHA-256 verification."

LC_ALL=C tar --list --verbose --gzip --numeric-owner --quoting-style=escape --file "$work_dir/$ARCHIVE" \
    > "$work_dir/members" || die "Unable to list the asset archive."
declare -A members=()
while IFS=' ' read -r mode owner size date time name extra; do
    [[ "$mode" == -* && "$size" =~ ^[0-9]+$ && -z "$extra" ]] || die "Invalid entry in the asset archive."
    [[ "$name" == checksums.sha256 || "$name" == LICENSE || "$name" =~ ^hagezi-[a-z0-9-]+\.dat$ ]] \
        || die "Unexpected file name in the asset archive."
    [[ -z "${members[$name]:-}" ]] || die "Duplicate asset archive entry: $name."
    members["$name"]=archive
done < "$work_dir/members"

[[ "${members[checksums.sha256]:-}" == archive && "${members[LICENSE]:-}" == archive ]] \
    || die "The asset archive is missing its checksum list or license."
tar --extract --gzip --no-same-owner --no-same-permissions --file "$work_dir/$ARCHIVE" --directory "$payload" \
    || die "Unable to extract the asset archive."

while IFS=' ' read -r digest asset extra; do
    [[ "$digest" =~ ^[a-f0-9]{64}$ && "$asset" =~ ^hagezi-[a-z0-9-]+\.dat$ && -z "$extra" ]] \
        || die "Invalid asset checksum entry."
    [[ "${members[$asset]:-}" == archive && -s "$payload/$asset" ]] || die "Missing or duplicate asset: $asset."
    members["$asset"]=verified
    if [[ -n "$container" && "${mount_targets[$container_assets/$asset]:-}" == 1 ]]; then
        die "Bind the Xray assets directory instead of mounting $asset individually."
    fi
    target="$assets_dir/$asset"
    [[ ! -d "$target" || -L "$target" ]] || die "Cannot replace directory $target with an Xray asset."
    asset_names+=("$asset")
done < "$payload/checksums.sha256"
(( ${#asset_names[@]} + 2 == ${#members[@]} )) || die "Some archive files have no checksum."
[[ "${members[hagezi-tif.dat]:-}" == verified && "${members[hagezi-tif-ipv4.dat]:-}" == verified ]] \
    || die "The archive does not contain both core TIF assets."
(cd "$payload" && sha256sum --strict --check --status checksums.sha256) \
    || die "An Xray asset failed SHA-256 verification."

index="$assets_dir/$ASSET_INDEX"
[[ ! -d "$index" || -L "$index" ]] || die "Cannot write the installed asset index to $index."
chmod 0644 -- "$payload/checksums.sha256"
for asset in "${asset_names[@]}"; do chmod 0644 -- "$payload/$asset"; done
for asset in "${asset_names[@]}"; do
    mv -fT -- "$payload/$asset" "$assets_dir/$asset"
done
mv -fT -- "$payload/checksums.sha256" "$index"

printf 'Installed %s HaGeZi Xray assets from %s at %s\n' "${#asset_names[@]}" "$tag" "$assets_dir"
if [[ -n "$container" ]]; then
    restart_node "$container" "$container_assets"
else
    printf 'Reload Xray to apply updated files used by active routing rules.\n'
fi
