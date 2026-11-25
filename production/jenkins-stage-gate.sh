#!/bin/bash
set -euo pipefail
umask 077

if [[ "$(id -u)" != 0 ]]; then
    exec sudo -n SSH_ORIGINAL_COMMAND="${SSH_ORIGINAL_COMMAND:-}" "$0"
fi

root=/opt/audioTranslation/container
cd "$root"
die() { printf 'Staging stopped: %s\n' "$*" >&2; exit 1; }
read -r action tag expected_hash extra <<< "${SSH_ORIGINAL_COMMAND:-}"
[[ "$action" == stage-verified && -z "$extra" ]] || die 'this key only accepts stage-verified'
[[ "$tag" =~ ^amd64-[0-9a-f]{12}-b[1-9][0-9]*$ ]] || die 'invalid image tag'
[[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] || die 'invalid SHA-256'
grep -Fxq -- "$tag $expected_hash" "$root/jenkins-stage-approved" ||
    die 'image and digest are outside the approved staging scope'

exec 9>/run/lock/audio-deploy-gate.lock
flock -n 9 || die 'another production deployment operation holds the lock'
live_tag=$(<.image-tag)
[[ "$live_tag" != "$tag" ]] || die 'candidate image is already live'
live_ref="audio-translation-prod:$live_tag"
image="audio-translation-prod:$tag"
live_state() {
    docker inspect --format '{{.Id}} {{.State.StartedAt}} {{.Config.Image}} {{.State.Health.Status}}' \
        audio-prod-backend-1 audio-prod-client-logs-1
    readlink /opt/audioTranslation/frontend/dist
    cat .image-tag
}
live_before=$(live_state)
[[ "$(docker inspect --format '{{.Config.Image}} {{.State.Health.Status}}' audio-prod-backend-1)" == "$live_ref healthy" ]] ||
    die 'current backend does not match the live tag or is unhealthy'
[[ "$(docker inspect --format '{{.Config.Image}} {{.State.Health.Status}}' audio-prod-client-logs-1)" == "$live_ref healthy" ]] ||
    die 'current client-logs does not match the live tag or is unhealthy'
docker container inspect audio-preflight >/dev/null 2>&1 && die 'preflight container already exists'
[[ -z "$(ss -H -ltn '( sport = :18000 )')" ]] || die 'isolated preflight port is occupied'
[[ "$(df --output=avail -k "$root" | tail -1)" -gt $((3 * 1024 * 1024)) ]] || die 'less than 3 GiB free'

archive="$root/images/$tag.tar.gz"
partial=$(mktemp "$root/images/.$tag.part.XXXXXXXX")
owned_preflight=0
cleanup() {
    rm -f -- "$partial"
    if [[ "$owned_preflight" == 1 ]] &&
        [[ "$(docker inspect --format '{{.Config.Image}}' audio-preflight 2>/dev/null || true)" == "$image" ]]; then
        docker rm -f audio-preflight >/dev/null || true
    fi
}
trap cleanup EXIT

cat > "$partial"
actual_hash=$(sha256sum "$partial" | awk '{print $1}')
[[ "$actual_hash" == "$expected_hash" ]] || die 'full server-side SHA-256 mismatch'
gzip -t "$partial" || die 'invalid gzip archive'
if [[ -e "$archive" ]]; then
    [[ "$(sha256sum "$archive" | awk '{print $1}')" == "$expected_hash" ]] ||
        die 'an archive exists under that tag with a different SHA-256'
else
    mv "$partial" "$archive"
fi
printf 'Tencent Cloud received and verified the complete SHA-256: %s\n' "$actual_hash" >&2

log=$(mktemp "$root/images/.$tag.preflight.XXXXXXXX")
owned_preflight=1
if ! {
    IMAGE_TAG="$tag" bash "$root/deploy-prod.sh" load "$archive" &&
    IMAGE_TAG="$tag" bash "$root/deploy-prod.sh" preflight
} > "$log" 2>&1; then
    die "isolated preflight failed; server-side diagnostics: $log"
fi
[[ "$(live_state)" == "$live_before" ]] || die 'live container identity, start time, health or frontend changed'
[[ -z "$(ss -H -ltn '( sport = :18000 )')" ]] || die 'isolated preflight port is still in use'
docker container inspect audio-preflight >/dev/null 2>&1 && die 'isolated preflight container was not removed'
test -s "/opt/audioTranslation/frontend/releases/$tag/index.html"
image_id=$(docker image inspect --format '{{.Id}}' "$image")
bytes=$(stat -c '%s' "$archive")
/usr/bin/python3 - "$tag" "$actual_hash" "$bytes" "$image_id" "$live_ref" <<'PY'
import json
import sys
tag, sha, size, image_id, live = sys.argv[1:]
print(json.dumps({
    "tag": tag, "sha256": sha, "bytes": int(size), "image_id": image_id,
    "preflight": "passed", "isolated_port": 18000,
    "preflight_removed": True, "live_unchanged": True, "live_image": live,
}))
PY
rm -f -- "$log"
