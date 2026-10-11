"""Validate resolved Compose JSON from stdin; never print env or credentials."""
import json, os, re, sys
from urllib.parse import urlsplit

mode=sys.argv[1]
copyroot=os.path.realpath(sys.argv[2]) if len(sys.argv)>2 else None
try:
    config=json.load(sys.stdin)
    services=config['services']
    immutable=re.compile(r'(?:@sha256:|^sha256:)[0-9a-f]{64}$')
    for name,service in services.items():
        assert immutable.search(service['image']), 'image not immutable'
        if mode=='offline':
            assert not service.get('ports') and not service.get('networks'), 'offline network/port present'
            assert service.get('network_mode') in ('none','service:sandbox'), 'unexpected offline namespace'
            for volume in service.get('volumes',[]):
                assert volume['type']=='bind', 'unreviewed volume'
                path=os.path.realpath(volume['source'])
                assert copyroot and path.startswith(copyroot+os.sep), 'mount outside copy root'
            env=service.get('environment',{})
            for key,value in env.items():
                if key.endswith('_URL') and value and (key.startswith(('DATABASE','REDIS','STREAMING_DATABASE'))):
                    assert urlsplit(value).hostname in ('127.0.0.1','localhost'), 'URL could override loopback'
            if name in ('app','web','sidekiq','streaming'):
                assert env.get('DB_HOST')=='127.0.0.1' and env.get('REDIS_HOST')=='127.0.0.1', 'non-loopback DB/cache'
                if name!='streaming':
                    for key in ('ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY','ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY','ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT'):
                        assert env.get(key), 'encryption key absent'
        else:
            if name in ('db','redis'):
                assert not service.get('ports'), 'DB/cache publication'
                assert set(service['networks'])=={'database'}, 'DB/cache outbound network'
            if name in ('web','streaming'):
                assert all(p.get('host_ip')=='127.0.0.1' for p in service.get('ports',[])), 'non-loopback app publication'
            if name in ('web','sidekiq'):
                for key in ('ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY','ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY','ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT'):
                    assert service.get('environment',{}).get(key), 'encryption key absent'
    db_env=services['db'].get('environment',{})
    assert db_env.get('POSTGRES_HOST_AUTH_METHOD')!='trust', 'trust authentication'
    assert db_env.get('POSTGRES_PASSWORD'), 'PG bootstrap password absent'
    app_env=services['app' if mode=='offline' else 'web'].get('environment',{})
    assert db_env.get('POSTGRES_USER') and db_env['POSTGRES_USER']!=app_env.get('DB_USER'), 'bootstrap admin must differ from app'
    assert services['redis'].get('environment',{}).get('REDISCLI_AUTH'), 'Redis auth absent'
    if mode!='offline':
        assert config['networks']['database']['internal'] is True, 'DB network not internal'
    print('PASS: Compose isolation/image/auth/encryption configuration invariants (no secret output)')
except Exception:
    raise SystemExit('FAIL: Compose validation. Review private configuration locally; no env values emitted.')
