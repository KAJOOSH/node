#!/usr/bin/env bash
set -euo pipefail

readonly RELEASES_URL="https://github.com/KAJOOSH/hagezi-xray-geosite/releases"
readonly ASSET="hagezi-tif.dat"

usage() {
    cat <<'HELP'
Usage: sudo bash update-tif-medium.sh [--container NAME | --assets-dir PATH]

Run on the host that runs Marzban Node. With no options, the script finds
the marzban-node Compose container and its persistent Xray assets directory.
Use --container if the host runs multiple nodes or uses a custom service name.
Use --assets-dir to write directly to a known Xray assets directory.
HELP
}

die() {
    printf 'TIF Medium: %s\n' "$*" >&2
    exit 1
}

fetch() {
    curl -fsSL --retry 3 --connect-timeout 12 --max-time 300 \
        --proto '=https' --proto-redir '=https' "$@"
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
        [[ "$destination" != "$container_assets/$ASSET" ]] \
            || die "Bind the Xray assets directory instead of the individual $ASSET file."
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

release_url="$(fetch -o /dev/null -w '%{url_effective}' "$RELEASES_URL/latest")" \
    || die "Unable to find the latest release."
tag="${release_url#"$RELEASES_URL/tag/"}"
[[ "$tag" =~ ^v[0-9]+(\.[0-9]+)+$ ]] || die "Unexpected release URL: $release_url"

work_dir="$(mktemp -d "$assets_dir/.hagezi-tif.XXXXXXXX")" || die "Unable to write to $assets_dir."
cleanup() {
    rm -f -- "$work_dir/$ASSET" "$work_dir/$ASSET.sha256"
    rmdir -- "$work_dir"
}
trap cleanup EXIT

fetch -o "$work_dir/$ASSET" "$RELEASES_URL/download/$tag/$ASSET" || die "Unable to download $ASSET from $tag."
fetch -o "$work_dir/$ASSET.sha256" "$RELEASES_URL/download/$tag/$ASSET.sha256" || die "Unable to download the checksum."
expected="$(<"$work_dir/$ASSET.sha256")"
[[ "$expected" =~ ^([[:xdigit:]]{64})[[:blank:]]+hagezi-tif\.dat$ ]] || die "Invalid checksum file."
expected="${BASH_REMATCH[1],,}"
actual="$(sha256sum < "$work_dir/$ASSET")"
[[ -s "$work_dir/$ASSET" && "${actual%% *}" == "$expected" ]] || die "SHA-256 verification failed."

chmod 0644 -- "$work_dir/$ASSET"
mv -fT -- "$work_dir/$ASSET" "$assets_dir/$ASSET"

if [[ -n "$container" ]]; then
    running="$(docker container inspect --format '{{.State.Running}}' -- "$container")" \
        || die "The verified file is installed, but container status could not be checked."
    if [[ "$running" == true ]]; then
        docker exec "$container" test -r "$container_assets/$ASSET" \
            || die "The verified file is installed, but the container cannot read $container_assets/$ASSET."
    fi
fi

printf 'TIF Medium %s is ready in %s\n' "$tag" "$assets_dir/$ASSET"
printf 'If the routing rule is already active, reload Xray to pick up the new list.\n'
