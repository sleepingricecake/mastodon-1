# Mochitodon deployment review files

Parent confirmed host media UID/GID1001/1001. Build pinned app/streaming with
UID1001 and GID1001. Explicitly select target mastodon or mochitodon-test:
the final stage of Dockerfile.pinned is test-only. The build-images.sh helper
selects targets and pins BuildKit/frontend/base/source, verifies FFmpeg SHA
and signature, checks25GiB disk/10GiB available RAM, and uses CPU2/memory8GiB
without additional swap, stage parallelism1 and compile jobs2. It only builds
new images/cache; no native service restart, apt upgrade, or live data change.

All3 Rails encryption keys were absent in old env. Generate them ONCE in the
private copy before4.3, use the same keys throughout intermediate migrations,
and persist them into final production env. Never print them. The historical
20170129000348 migration is legitimate removed E2EE code, not unexplained drift.
Only the unpopulated instances view may need a reviewed nonconcurrent initial
refresh after final shape/owner validation; never replay all migrations/views.

Run container-control.sh with DEPLOYMENT_VARIABLES_FILE (private600). Modes
check-offline/pull-offline/up-offline/migrate/post-migrate/boot-copy/jpeg/test
operate on the copy namespace; check-prod/up-prod use production config.
MIGRATION_PHASE selects normal or pre for the explicit migrate action.
TEST_DATABASE_NAME=mochitodon selects actual mochitodon_test, because Rails
appends _test. The isolated bootstrap admin pre-creates this separate test DB
owned by the app. Do not grant app CREATEDB. Use the separate test image for
RSpec; the production image intentionally omits test gems.

Based on stable v4.7.3. The local source changes restore input104,857,600 pixels
and original26,214,400 pixels while retaining image16MiB/video99MiB/video120fps.
JPEG processing explicitly preserves quality90. Vips block-untrusted stays on.
Old browser canvas processing is not reintroduced.

Compose files require deployment-local variables outside Git and fail if unset.
They are not verified on the target yet. Read the parent migration runbook and
architecture memo before execution. Use immutable image digests. Custom final
image and streaming image must contain the reviewed source and matching assets.
Keep private env/config files mode600 in mode700 directories with correct owners.
Never send resolved Compose configuration or inspect env output to a report.

The production file retains native NGINX and publishes only127.0.0.1:3000/4000.
PG16 and Redis have no published ports and use the internal database bridge.
POSTGRES_ENV_FILE supplies POSTGRES_USER/POSTGRES_DB/POSTGRES_PASSWORD; never
POSTGRES_HOST_AUTH_METHOD=trust. Existing initialized PG data retains its own
HBA/password state; environment does not change it.
POSTGRES_USER is a dedicated bootstrap admin distinct from DB_USER. Create the
app role NOSUPERUSER/NOCREATEDB/NOCREATEROLE and restore with no-owner,
no-privileges and role app. Official initialization grants its POSTGRES_USER
superuser, so never initialize the cluster with the app identity.
REDIS_CONFIG_FILE supplies persistence and password/ACL. REDIS_ENV_FILE supplies
REDISCLI_AUTH for health probes. App credentials must match. Authentication
failure probes and snapshot/restart persistence checks are required.
Redis drops root at startup; its config must remain readable to the runtime
numeric Redis user. Prefer user-owned600 inside a private700 parent (the bind
mount permits container access to the file); root-owned600 alone is unreadable.
PG16_DATA_DIR is a NEW restored PG16 directory, never the PG12 directory.
MEDIA_DIR is the existing media path at final cutover; match image UID/GID
to its numeric owner via build args, rather than recursively chown live media.
Memory limits and Sidekiq concurrency require actual104MP measurement first.
Docker Engine must be maintained and>=28.0.0; inspect Docker forward filtering
and IPv4/IPv6 reachability because UFW alone does not protect published ports.

The offline file is distinct. It uses a network:none sandbox and all services
share that namespace, with no published ports or external interface. ALL data
and env/config paths must be isolated copies. DB/Redis host are127.0.0.1; SMTP
is127.0.0.1:1; verify no original DATABASE_URL/REDIS_URL/streaming database URL
in copied env can override these settings. Prepare writable tmp/media copies
owned by REHEARSAL_UID/GID. Preserve original secrets/encryption keys in the
copy, never regenerate them between migration series. Do not run native services
on these copy directories. Start sandbox/db/redis/app, inspect namespace
interfaces and mounts, restore DB/Redis and then run each reviewed migration
explicitly using app. Boot profile is optional and remains offline.
Do not enable sidekiq until queued actions and copy isolation have been reviewed.

The JPEG integration check runs:

    bundle exec ruby deployment/mochitodon/verify_jpeg_quality.rb

It processes actual images, validates JPEG Q90 quantization for extension/format
variants and PNG format preservation, and reads no production env/DB/network.
Run the corresponding RSpec tests in an isolated test environment as well.
Production images omit test gems; a separately built test stage is needed.

Native NGINX assets must come from the SAME final image build. Extract
public/packs and public/assets into a new read-only host release directory and
switch the reviewed NGINX paths together with runtime cutover. Media alias
remains the existing bind. Never bake private env, keys, backups or media into
an image or source build context.

Rollback after DB schema migration requires the coherent pre-cutover DB/Redis/
media/env+keys/source/assets/runtime set. Changing image alone is insufficient.
Keep oldPG12/native runtimes stopped but intact; do not touch unrelatedPG14.
Never delete data with compose down -v.
