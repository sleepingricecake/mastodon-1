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
for command in docker git curl gpg gpgv python3 sha256sum df awk; do command -v "$command" >/dev/null; done
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
  curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 20 --max-time 180 --retry 2 --retry-delay 2 --output "$verify/$item" "https://ffmpeg.org/releases/$item"
done
curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 20 --max-time 180 --retry 2 --retry-delay 2 --output "$verify/ffmpeg-devel.asc" https://ffmpeg.org/ffmpeg-devel.asc
printf '%s  %s\n' 8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e "$verify/ffmpeg-9.0.2.tar.xz" | sha256sum -c -
# Only public-key parsing and detached verification are needed. Importing with
# gpg can start an agent and fail when its socket path exceeds the Unix limit.
gpg --no-options --batch --no-tty --no-autostart --homedir "$verify/gnupg" --with-colons --show-keys "$verify/ffmpeg-devel.asc" >"$verify/key-listing.txt"
python3 - "$verify/key-listing.txt" <<'PY'
import pathlib, sys, time
rows = [line.split(':') for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
primary = [i for i, row in enumerate(rows) if row[0] == 'pub']
if len(primary) != 1:
    raise SystemExit('Require exactly one FFmpeg primary signing key')
i = primary[0]
key = rows[i]
if key[1] in ('r', 'e', 'd') or (key[6] and int(key[6]) <= time.time()):
    raise SystemExit('FFmpeg primary key is revoked, expired or disabled')
if i + 1 >= len(rows) or rows[i + 1][0] != 'fpr' or rows[i + 1][9] != 'FCF986EA15E6E293A5644F10B4322F04D67658D8':
    raise SystemExit('Unexpected FFmpeg signing key')
PY
gpg --no-options --batch --yes --no-tty --no-autostart --homedir "$verify/gnupg" --output "$verify/ffmpeg-release.gpg" --dearmor "$verify/ffmpeg-devel.asc"
gpgv --homedir "$verify/gnupg" --keyring "$verify/ffmpeg-release.gpg" --status-fd 1 "$verify/ffmpeg-9.0.2.tar.xz.asc" "$verify/ffmpeg-9.0.2.tar.xz" >"$verify/signature-status.txt"
awk '$1=="[GNUPG:]" && $2=="VALIDSIG" && ($3=="FCF986EA15E6E293A5644F10B4322F04D67658D8" || $NF=="FCF986EA15E6E293A5644F10B4322F04D67658D8") { valid=1 } END {exit !valid}' "$verify/signature-status.txt"
echo 'Pinned FFmpeg archive and signing primary verified without an agent'
# Reuse a reviewed builder cache across source revisions when explicitly selected.
# Its exact image, configuration and resource limits are still verified below.
builder=${BUILD_BUILDER_NAME:-"mochitodon-${source_commit:0:12}"}
[[ "$builder" =~ ^mochitodon-[a-f0-9]{12}$ ]] || { echo 'Invalid reviewed builder name' >&2; exit 1; }
if docker buildx inspect "$builder" >/dev/null 2>&1; then
  builder_container="buildx_buildkit_${builder}0"
  [[ $(docker inspect --format '{{.Config.Image}}' "$builder_container") == 'moby/buildkit@sha256:cec9f139f45e93c5c69c60f8b07cfad9f43f4ef6b6a6cd917527fea5ff2e3dea' ]] || { echo 'Existing builder image mismatch' >&2; exit 1; }
  docker exec "$builder_container" cat /etc/buildkit/buildkitd.toml >"$BUILD_WORKSPACE/builder-config.actual.toml"
  python3 "$here/verify-buildkit-config.py" "$here/buildkitd.toml" "$BUILD_WORKSPACE/builder-config.actual.toml"
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
