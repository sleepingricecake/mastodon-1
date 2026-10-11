#!/usr/bin/env bash
# Builds only new images/cache; never updates apt, services, live data or secrets.
set -Eeuo pipefail
umask 077
target=${1:-plan}
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source_root=$(cd -- "$here/../.." && pwd -P)
if [[ "$target" == plan ]]; then
  echo 'Targets: mastodon/test/streaming/all. Requires reviewed clean source, GID, BUILD_WORKSPACE.'
  echo 'Dedicated BuildKit: CPU2, memory8GiB/no extra swap, stage parallelism1, compile jobs2.'
  exit 0
fi
case "$target" in mastodon|test|streaming|all) ;; *) exit 1 ;; esac
: "${GID:?Actual existing media numeric GID}"
: "${BUILD_WORKSPACE:?Dedicated absolute source verification directory}"
[[ "$GID" =~ ^[0-9]+$ ]] || exit 1
[[ "$BUILD_WORKSPACE" == /* && ! -L "$BUILD_WORKSPACE" ]] || exit 1
for command in docker git curl gpg sha256sum df awk; do command -v "$command" >/dev/null; done
major=$(docker version --format '{{.Server.Version}}' | cut -d. -f1)
[[ "$major" =~ ^[0-9]+$ && "$major" -ge 28 ]] || exit 1
[[ -z $(git -C "$source_root" status --porcelain) ]] || { echo 'Commit the fully reviewed source before build' >&2; exit 1; }
source_commit=$(git -C "$source_root" rev-parse HEAD)
git -C "$source_root" merge-base --is-ancestor v4.7.3 HEAD
mkdir -p -- "$BUILD_WORKSPACE"
[[ $(stat -c %a "$BUILD_WORKSPACE") == 700 && $(stat -c %u "$BUILD_WORKSPACE") == "$EUID" ]] || exit 1
docker_root=$(docker info --format '{{.DockerRootDir}}')
resource_guard() {
  local available
  for path in "$BUILD_WORKSPACE" "$docker_root"; do
    available=$(df -PB1 -- "$path" | awk 'NR==2 {print $4}')
    [[ "$available" =~ ^[0-9]+$ && "$available" -ge 26843545600 ]] || { echo 'Require20GiB disk reserve+5GiB build margin' >&2; exit 1; }
  done
  available=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
  [[ "$available" -ge 10485760 ]] || { echo 'Require10GiB available RAM for bounded8GiB builder plus2GiB reserve' >&2; exit 1; }
}
resource_guard
# Verify the exact FFmpeg release archive/signature before Docker downloads it.
verify="$BUILD_WORKSPACE/ffmpeg-9.0.2-verification"
mkdir -p -- "$verify" "$verify/gnupg"
chmod 700 "$verify" "$verify/gnupg"
for item in ffmpeg-9.0.2.tar.xz ffmpeg-9.0.2.tar.xz.asc; do
  resource_guard
  curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 --output "$verify/$item" "https://ffmpeg.org/releases/$item"
done
curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 --output "$verify/ffmpeg-devel.asc" https://ffmpeg.org/ffmpeg-devel.asc
printf '%s  %s\n' 8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e "$verify/ffmpeg-9.0.2.tar.xz" | sha256sum -c -
fingerprint=$(gpg --homedir "$verify/gnupg" --with-colons --import-options show-only --import "$verify/ffmpeg-devel.asc" 2>/dev/null | awk -F: '$1=="fpr" {print $10; exit}')
[[ "$fingerprint" == FCF986EA15E6E293A5644F10B4322F04D67658D8 ]] || { echo 'Unexpected FFmpeg signing key' >&2; exit 1; }
gpg --homedir "$verify/gnupg" --import "$verify/ffmpeg-devel.asc"
gpg --homedir "$verify/gnupg" --verify "$verify/ffmpeg-9.0.2.tar.xz.asc" "$verify/ffmpeg-9.0.2.tar.xz"
builder="mochitodon-${source_commit:0:12}"
if docker buildx inspect "$builder" >/dev/null 2>&1; then
  builder_container="buildx_buildkit_${builder}0"
  [[ $(docker inspect --format '{{.Config.Image}}' "$builder_container") == 'moby/buildkit@sha256:cec9f139f45e93c5c69c60f8b07cfad9f43f4ef6b6a6cd917527fea5ff2e3dea' ]] || { echo 'Existing builder image mismatch' >&2; exit 1; }
  [[ $(docker exec "$builder_container" cat /etc/buildkit/buildkitd.toml) == $(cat "$here/buildkitd.toml") ]] || { echo 'Existing builder config mismatch' >&2; exit 1; }
else
  docker buildx create --name "$builder" --driver docker-container --driver-opt image=moby/buildkit@sha256:cec9f139f45e93c5c69c60f8b07cfad9f43f4ef6b6a6cd917527fea5ff2e3dea --driver-opt memory=8g --driver-opt memory-swap=8g --driver-opt cpu-period=100000 --driver-opt cpu-quota=200000 --buildkitd-config "$here/buildkitd.toml"
fi
docker buildx inspect --bootstrap "$builder" >/dev/null
builder_container="buildx_buildkit_${builder}0"
limits=$(docker inspect --format '{{.HostConfig.Memory}} {{.HostConfig.MemorySwap}} {{.HostConfig.CpuQuota}} {{.HostConfig.CpuPeriod}}' "$builder_container")
[[ "$limits" == '8589934592 8589934592 200000 100000' ]] || { echo 'Builder resource limits not applied' >&2; exit 1; }
build() {
  local kind="$1" file stage tag
  resource_guard
  case "$kind" in
    mastodon) file="$here/Dockerfile.pinned"; stage=mastodon; tag="mochitodon:stable-${source_commit:0:12}" ;;
    test) file="$here/Dockerfile.pinned"; stage=mochitodon-test; tag="mochitodon:test-${source_commit:0:12}" ;;
    streaming) file="$here/Dockerfile.streaming.pinned"; stage=streaming; tag="mochitodon-streaming:stable-${source_commit:0:12}" ;;
  esac
  docker buildx build --builder "$builder" --platform linux/amd64 --load --file "$file" --target "$stage" --build-arg UID=1001 --build-arg "GID=$GID" --build-arg "SOURCE_COMMIT=$source_commit" --tag "$tag" "$source_root"
  docker image inspect --format '{{.Id}}' "$tag"
}
if [[ "$target" == all ]]; then
  build mastodon; build test; build streaming
else
  build "$target"
fi
echo 'Images built, not deployed. Record exact image IDs/digests and actual runtime/gem versions.'
