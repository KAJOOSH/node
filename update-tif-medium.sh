#!/usr/bin/env bash
set -euo pipefail

readonly RELEASES_URL="https://github.com/KAJOOSH/hagezi-xray-geosite/releases"
readonly -a TIF_ASSETS=(hagezi-tif.dat hagezi-tif-ipv4.dat)

usage() {
    cat <<'HELP'
Usage: sudo bash update-tif-medium.sh [--container NAME | --assets-dir PATH]

Run on the host that runs Marzban Node. With no options, the script finds
the marzban-node Compose container, updates TIF Medium and TIF IPv4, and restarts it.
Use --container if the host runs multiple nodes or uses a custom service name.
Use --assets-dir to update a known directory without restarting a container.
HELP
}

die() {
    printf 'HaGeZi TIF: %s\n' "$*" >&2
    exit 1
}

fetch() {
    curl -fsSL --retry 3 --connect-timeout 12 --max-time 300 \
        --proto '=https' --proto-redir '=https' "$@"
}

restart_node() {
    local container="$1" asset_dir="$2" status attempt asset
    local -a asset_paths=()
    for asset in "${TIF_ASSETS[@]}"; do asset_paths+=("$asset_dir/$asset"); done
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
            printf 'Marzban Node (%s) is running and can read both TIF files.\n' "$container"
            return 0
        fi
        if (( attempt < 30 )); then sleep 2; fi
    done

    die "Container $container is not ready after restart (state: $status). Check its logs with docker logs."
}

container=""
assets_dir=""
container_assets=""

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
        for asset in "${TIF_ASSETS[@]}"; do
            [[ "$destination" != "$container_assets/$asset" ]] \
                || die "Bind the Xray assets directory instead of the individual $asset file."
        done
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

work_dir="$(mktemp -d "$assets_dir/.hagezi-tif.XXXXXXXX")" || die "Unable to write to $assets_dir."
cleanup() {
    local asset
    for asset in "${TIF_ASSETS[@]}"; do rm -f -- "$work_dir/$asset"; done
    rm -f -- "$work_dir/checksums.sha256"
    rmdir -- "$work_dir"
}
trap cleanup EXIT

release_base="$RELEASES_URL/download/$tag"
checksums="$work_dir/checksums.sha256"
fetch -o "$checksums" "$release_base/checksums.sha256" || die "Unable to download HaGeZi TIF checksums."
for asset in "${TIF_ASSETS[@]}"; do
    target="$assets_dir/$asset"
    [[ ! -d "$target" || -L "$target" ]] || die "Cannot replace directory $target with an Xray asset."
    expected="$(awk -v file="$asset" '$2 == file { print $1 }' "$checksums")"
    [[ "$expected" =~ ^[[:xdigit:]]{64}$ ]] || die "Missing or invalid checksum for $asset in $tag."
    fetch -o "$work_dir/$asset" "$release_base/$asset" || die "Unable to download $asset from $tag."
    actual="$(sha256sum < "$work_dir/$asset")"
    [[ -s "$work_dir/$asset" && "${actual%% *}" == "${expected,,}" ]] || die "$asset failed SHA-256 verification."
    chmod 0644 -- "$work_dir/$asset"
done

for asset in "${TIF_ASSETS[@]}"; do
    mv -fT -- "$work_dir/$asset" "$assets_dir/$asset"
    printf 'Installed %s from %s at %s/%s\n' "$asset" "$tag" "$assets_dir" "$asset"
done

if [[ -n "$container" ]]; then
    restart_node "$container" "$container_assets"
else
    printf 'Reload Xray if you already use either TIF rule.\n'
fi
