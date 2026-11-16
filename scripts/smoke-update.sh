#!/bin/sh
# Run on the VPS after docker login. Creates only a disposable test container.
set -eu
cd "$(dirname "$0")/.."
registry_host=$(python3 -c 'from pathlib import Path; e=dict(line.split("=",1) for line in Path(".env").read_text().splitlines() if "=" in line and not line.startswith("#")); print(e["PUBLIC_HOST"]+":"+e.get("HTTPS_PORT","18443"))')
image="$registry_host/vph04-smoke:watchtower-test"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
make_image() {
  printf 'FROM busybox:1.37\nLABEL homework.version="%s"\nCMD ["sleep", "86400"]\n' "$1" > "$tmp/Dockerfile"
  docker build --quiet -t "$image" "$tmp" >/dev/null
  docker tag "$image" "$registry_host/vph04-smoke:v$1"
  docker --config secrets push "$image" >/dev/null
}
make_image 1
docker run -d --name vph04-update-demo \
  --label com.centurylinklabs.watchtower.enable=true \
  --label com.centurylinklabs.watchtower.scope=vph04 "$image" >/dev/null
before=$(docker inspect --format '{{.Id}}' vph04-update-demo)
make_image 2
count=0
while [ "$count" -lt 36 ]; do
  version=$(docker inspect --format '{{index .Config.Labels "homework.version"}}' vph04-update-demo 2>/dev/null || true)
  if [ "$version" = 2 ]; then
    after=$(docker inspect --format '{{.Id}}' vph04-update-demo)
    test "$before" != "$after"
    echo "WATCHTOWER_UPDATE_VERIFIED version=1->2 container_recreated=true"
    docker rm -f vph04-update-demo >/dev/null
    exit 0
  fi
  count=$((count+1))
  sleep 5
done
echo 'Watchtower update did not finish in 180 seconds' >&2
exit 1
