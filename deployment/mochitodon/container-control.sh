#!/usr/bin/env bash
# Parent operator only; never sources env as shell code or stops native services.
set -Eeuo pipefail
umask 077
mode=${1:-check-offline}
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
: "${DEPLOYMENT_VARIABLES_FILE:?Private Compose interpolation env outside Git}"
[[ -f "$DEPLOYMENT_VARIABLES_FILE" && ! -L "$DEPLOYMENT_VARIABLES_FILE" ]] || exit 1
[[ $(stat -c %a "$DEPLOYMENT_VARIABLES_FILE") == 600 ]] || { echo 'Require variables file mode600' >&2; exit 1; }
for command in docker python3; do command -v "$command" >/dev/null; done
major=$(docker version --format '{{.Server.Version}}' | cut -d. -f1)
[[ "$major" =~ ^[0-9]+$ && "$major" -ge 28 ]] || { echo 'Require maintained Docker Engine>=28' >&2; exit 1; }
docker compose version >/dev/null
case "$mode" in
  *offline*|migrate|post-migrate|boot-copy|jpeg|test)
    : "${REHEARSAL_COPY_ROOT:?Isolated copy root}"
    [[ -d "$REHEARSAL_COPY_ROOT" && ! -L "$REHEARSAL_COPY_ROOT" ]] || exit 1
    config="$here/compose.offline.yml"; kind=offline ;;
  check-prod|up-prod) config="$here/compose.production.yml"; kind=production ;;
  *) echo 'Modes: check-offline/pull-offline/up-offline/migrate/post-migrate/boot-copy/jpeg/test/check-prod/up-prod' >&2; exit 1 ;;
esac
dc=(docker compose --env-file "$DEPLOYMENT_VARIABLES_FILE" -f "$config")
"${dc[@]}" config --quiet
"${dc[@]}" config --format json | python3 "$here/validate-compose.py" "$kind" "${REHEARSAL_COPY_ROOT:-}"
verify_offline() {
  local sandbox container
  sandbox=$("${dc[@]}" ps -q sandbox)
  [[ -n "$sandbox" ]] || exit 1
  [[ $(docker inspect --format '{{.HostConfig.NetworkMode}}' "$sandbox") == none ]] || exit 1
  for service in db redis app; do
    container=$("${dc[@]}" ps -q "$service")
    [[ -n "$container" ]] || exit 1
    [[ $(docker inspect --format '{{.HostConfig.NetworkMode}}' "$container") == "container:$sandbox" ]] || exit 1
    [[ $(docker inspect --format '{{len .HostConfig.PortBindings}}' "$container") == 0 ]] || exit 1
  done
  # This request has a hard two-second bound; offline topology should have no route.
  if "${dc[@]}" exec -T app curl --silent --fail --noproxy '*' --connect-timeout 2 --max-time 2 http://1.1.1.1/ >/dev/null 2>&1; then
    echo 'Unexpected namespace egress' >&2; exit 1
  fi
  echo 'PASS: network:none sandbox shared by DB/Redis/app, no ports, bounded egress probe failed'
}
case "$mode" in
  check-offline|check-prod) ;;
  pull-offline) "${dc[@]}" pull ;;
  up-offline) "${dc[@]}" up -d --wait sandbox db redis app; verify_offline ;;
  migrate)
    verify_offline
    : "${MIGRATION_PHASE:?normal or pre}"
    case "$MIGRATION_PHASE" in
      pre) "${dc[@]}" exec -T -e SKIP_POST_DEPLOYMENT_MIGRATIONS=true app bundle exec rails db:migrate ;;
      normal) "${dc[@]}" exec -T app bundle exec rails db:migrate ;;
      *) exit 1 ;;
    esac ;;
  post-migrate) verify_offline; "${dc[@]}" exec -T app bundle exec rails db:migrate ;;
  boot-copy) verify_offline; "${dc[@]}" --profile boot up -d web streaming ;;
  jpeg) verify_offline; "${dc[@]}" exec -T app bundle exec ruby deployment/mochitodon/verify_jpeg_quality.rb ;;
  test)
    verify_offline
    : "${TEST_DATABASE_NAME:?Set base mochitodon; Rails appends _test}"
    [[ "$TEST_DATABASE_NAME" == mochitodon ]] || exit 1
    # The isolated bootstrap admin must pre-create this DB owned by the app.
    # Do not grant the production app CREATEDB for this test.
    "${dc[@]}" exec -T -e RAILS_ENV=test -e DB_NAME="$TEST_DATABASE_NAME" -e TEST_ENV_NUMBER= -e SKIP_SCHEMA_DUMP=true app env -u DATABASE_URL bundle exec rails db:prepare
    "${dc[@]}" exec -T -e RAILS_ENV=test -e DB_NAME="$TEST_DATABASE_NAME" -e TEST_ENV_NUMBER= app env -u DATABASE_URL bundle exec rspec spec/lib/paperclip/vips_lazy_thumbnail_spec.rb spec/models/media_attachment_spec.rb spec/requests/api/v1/instance_spec.rb spec/requests/api/v2/instance_spec.rb ;;
  up-prod)
    for gate in CUTOVER_APPROVED BACKUP_RESTORE_VERIFIED MIGRATION_REHEARSAL_VERIFIED FORWARD_FIREWALL_VERIFIED MEDIA_RESOURCE_TEST_VERIFIED ASSETS_BUILD_VERIFIED; do
      [[ "${!gate:-}" == yes ]] || { echo "Required gate: $gate" >&2; exit 1; }
    done
    # The parent explicitly stops the old app before this mode. PG14 is unrelated.
    if ss -H -ltn '( sport = :3000 or sport = :4000 )' | grep -q .; then
      echo 'Old loopback app listener still active' >&2; exit 1
    fi
    "${dc[@]}" up -d --wait --pull never ;;
esac
