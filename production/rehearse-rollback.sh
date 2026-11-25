#!/bin/bash
set -euo pipefail
umask 077

ROOT=/opt/audioTranslation/container
source "$ROOT/release-runtime.sh"
baseline=amd64-20261124-r6
candidate=amd64-f3d8b66c21b2-b8
PROJECT=audio-release-rehearsal
[[ -z "$(ss -H -ltn '( sport = :18007 or sport = :18008 )')" ]]
[[ -z "$(docker ps -aq --filter label=com.docker.compose.project=audio-release-rehearsal)" ]]
DEPLOY_ROOT=$(mktemp -d /tmp/audio-release-rehearsal.XXXXXXXX)
FRONTEND_ROOT="$DEPLOY_ROOT/frontend"
COMPOSE_FILE="$DEPLOY_ROOT/compose.yaml"
cleanup() {
    local result=$?
    trap - EXIT
    if compose_for "$baseline" down --remove-orphans >&2; then
        rm -rf -- "$DEPLOY_ROOT"
    else
        echo "Rehearsal cleanup needs attention: $DEPLOY_ROOT" >&2
        exit 1
    fi
    exit "$result"
}
trap cleanup EXIT
live_before=$(docker inspect --format '{{.Id}} {{.State.StartedAt}}' audio-prod-backend-1 audio-prod-client-logs-1)
mkdir -p "$FRONTEND_ROOT/releases/$baseline" "$FRONTEND_ROOT/releases/$candidate"
for tag in "$baseline" "$candidate"; do
    cp "/opt/audioTranslation/frontend/releases/$tag/index.html" "$FRONTEND_ROOT/releases/$tag/"
done
ln -s "releases/$baseline" "$FRONTEND_ROOT/dist"
record_tag "$DEPLOY_ROOT/.image-tag" "$baseline"
cat >"$COMPOSE_FILE" <<'YAML'
x-app: &app
  image: audio-translation-prod:${IMAGE_TAG}
  platform: linux/amd64
  network_mode: host
  working_dir: /workspace/server/backend
  init: true
  cpus: 1
  mem_limit: 1200m
  environment:
    APP_ENV_FILE: /dev/null
    DATA_DIR: /tmp/rehearsal
    TRANSCRIPTION_PROVIDER: mock
    POST_CALL_GOLD_ENABLED: "false"
    BRIDGE_STREAMING_ASR: "false"
    HEADSET_STREAMING_ASR: "false"
    CLIENT_LOG_SNAPSHOT_DIR: /tmp/rehearsal/logs
services:
  backend:
    <<: *app
    command: ["python", "-m", "uvicorn", "app.main:app", "--host", "127.0.0.1", "--port", "18007"]
    healthcheck:
      test: ["CMD", "python", "-c", "import json,urllib.request; assert json.load(urllib.request.urlopen('http://127.0.0.1:18007/api/health',timeout=3))['status']=='ok'"]
      interval: 2s
      retries: 12
  client-logs:
    <<: *app
    command: ["python", "-m", "uvicorn", "app.client_log_app:app", "--host", "127.0.0.1", "--port", "18008"]
    healthcheck:
      test: ["CMD", "python", "-c", "import json,urllib.request; assert json.load(urllib.request.urlopen('http://127.0.0.1:18008/health',timeout=3))['status']=='ok'"]
      interval: 2s
      retries: 12
YAML

verify_release() {
    local tag=$1
    [[ "$(readlink "$FRONTEND_ROOT/dist")" == "releases/$tag" ]] || return 1
    cmp "$FRONTEND_ROOT/dist/index.html" "/opt/audioTranslation/frontend/releases/$tag/index.html" || return 1
    curl --noproxy '*' -fsS --max-time 6 http://127.0.0.1:18007/api/health >/dev/null || return 1
    curl --noproxy '*' -fsS --max-time 6 http://127.0.0.1:18008/health >/dev/null || return 1
    if [[ "$tag" == "$candidate" ]]; then
        echo candidate-failure-reached > "$DEPLOY_ROOT/forced-failure"
        echo 'Injected an acceptance failure after candidate containers and frontend were ready.' >&2
        return 1
    fi
}

runtime_up "$baseline"
verify_release "$baseline"
if activate_transaction "$candidate" "$baseline"; then
    echo 'Expected the simulated release to fail.' >&2
    exit 1
fi
test -f "$DEPLOY_ROOT/forced-failure"
[[ "$(<"$DEPLOY_ROOT/.image-tag")" == "$baseline" ]]
for service in backend client-logs; do
    container=$(compose_for "$baseline" ps -q "$service")
    [[ "$(docker inspect --format '{{.Config.Image}} {{.State.Health.Status}}' "$container")" \
        == "audio-translation-prod:$baseline healthy" ]]
done
verify_release "$baseline"
[[ "$(docker inspect --format '{{.Id}} {{.State.StartedAt}}' audio-prod-backend-1 audio-prod-client-logs-1)" == "$live_before" ]]
echo "Rollback rehearsal passed: original $baseline image, both services and the corresponding frontend restored."
