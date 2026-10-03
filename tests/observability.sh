#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
case "${1:-}" in
  --help)
    printf 'Usage: tests/observability.sh [--static]\nWithout arguments, verify live metrics and fresh logs using forwards owned by scripts/verify.sh.\nRequired environment: KUBE_CONTEXT GATEWAY_BASE_URL PROMETHEUS_BASE_URL LOKI_BASE_URL RUN_ID EVIDENCE_DIR.\n--static checks local YAML, pins, configs and overlay boundaries; requires Python PyYAML.\n'
    exit 0 ;;
  --static) [[ $# == 1 ]] || exit 64; mode=static ;;
  '') [[ $# == 0 ]] || exit 64; mode=runtime ;;
  *) printf 'Unknown argument: %s\n' "$1" >&2; exit 64 ;;
esac
export ROOT
set -a
source "$ROOT/config/versions.env"
set +a
python3 - "$mode" <<'PY'
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
from urllib.parse import urlparse

root = Path(os.environ['ROOT'])
obs = root / 'kubernetes/observability'
def require(condition, message):
    if not condition:
        raise AssertionError(message)

def static():
    import yaml
    def load(name):
        return list(yaml.safe_load_all((obs / name).read_text()))
    for path in sorted(obs.glob('*.y*ml')):
        require(b'\r' not in path.read_bytes(), f'{path.name}: expected LF')
        list(yaml.safe_load_all(path.read_text()))
    k = load('kustomization.yaml')[0]
    require('namespace' not in k, 'overlay must not transform namespaces')
    require(k['resources'] == ['../app', 'prometheus.yaml', 'loki.yaml'], 'overlay includes app exactly once')
    require(k['generatorOptions']['disableNameSuffixHash'] is True, 'stable ConfigMap names required')
    require({(g['name'], g['namespace']) for g in k['configMapGenerator']} == {
        ('prometheus-config', 'mts-observability'), ('loki-config', 'mts-observability'),
        ('fluentd-config', 'mts-app')}, 'ConfigMap namespace interfaces')
    for name, config, image, port in [('prometheus', 'prometheus.yml', 'PROMETHEUS_IMAGE', 9090),
                                      ('loki', 'loki.yml', 'LOKI_IMAGE', 3100)]:
        deployment, service = load(name + '.yaml')
        require(deployment['kind'] == 'Deployment' and service['kind'] == 'Service', f'{name} resource types')
        for resource in [deployment, service]:
            require(resource['metadata']['name'] == name and resource['metadata']['namespace'] == 'mts-observability', f'{name} identity')
            require(resource['metadata']['labels']['app.kubernetes.io/part-of'] == 'mts-engineer-hack', 'project label')
        template = deployment['spec']['template']
        require(deployment['spec']['replicas'] == 1, 'one replica')
        require(deployment['spec']['selector']['matchLabels'] == service['spec']['selector'], 'selector mismatch')
        require(template['metadata']['annotations']['mts-engineer/config-sha256'] == hashlib.sha256((obs/config).read_bytes()).hexdigest(), f'{name}: update committed config checksum for rollout')
        container = template['spec']['containers'][0]
        require(container['image'] == os.environ[image], f'{name} image pin')
        require(container['ports'] == [{'name': 'http', 'containerPort': port}], f'{name} container port')
        require(service['spec']['type'] == 'ClusterIP' and service['spec']['ports'] == [
            {'name': 'http', 'port': port, 'targetPort': 'http', 'protocol': 'TCP'}], f'{name} Service port')
        require(template['spec']['automountServiceAccountToken'] is False, 'no telemetry API access')
        if name == 'prometheus':
            security = template['spec']['securityContext']
            require(security.get('runAsNonRoot') is True and security.get('runAsUser') == 65534
                    and security.get('runAsGroup') == 65534, 'numeric Prometheus nobody identity required by kubelet')
        require(any(v.get('emptyDir') for v in template['spec']['volumes']), 'ephemeral data volume')
    prom = load('prometheus.yml')[0]
    require(prom['global'] == {'scrape_interval': '15s', 'scrape_timeout': '5s'}, 'scrape timing')
    jobs = prom['scrape_configs']
    require(len(jobs) == 2 and {j['job_name'] for j in jobs} == {'prometheus', 'loki'}, 'exactly two real jobs')
    for j in jobs:
        port = 9090 if j['job_name'] == 'prometheus' else 3100
        require(j['metrics_path'] == '/metrics' and j['static_configs'] == [
            {'targets': [f"{j['job_name']}.mts-observability.svc.cluster.local:{port}"]}], 'real DNS target')
    loki = load('loki.yml')[0]
    require(loki['auth_enabled'] is False and loki['common']['replication_factor'] == 1, 'local single Loki')
    require(loki['common']['ring']['kvstore']['store'] == 'inmemory', 'in-memory ring')
    require(loki['schema_config']['configs'][0]['schema'] == 'v13' and
            loki['schema_config']['configs'][0]['store'] == 'tsdb', 'TSDB v13 schema')
    require(loki['limits_config']['allow_structured_metadata'] is False, 'JSON body only')
    require('-target=all' in load('loki.yaml')[0]['spec']['template']['spec']['containers'][0]['args'], 'monolithic target')
    patch = load('nginx-fluentd-patch.yaml')[0]
    require(patch['metadata'] == {'name': 'nginx-demo', 'namespace': 'mts-app'}, 'patch target')
    template = patch['spec']['template']
    require(template['metadata']['annotations']['mts-engineer/fluentd-config-sha256'] == hashlib.sha256((obs/'fluent.conf').read_bytes()).hexdigest(), 'update Fluentd config checksum for rollout')
    c = template['spec']['containers'][0]
    require(len(template['spec']['containers']) == 1 and c['name'] == 'fluentd', 'only sidecar patch')
    require(c['image'] == os.environ['FLUENTD_IMAGE'] and c['imagePullPolicy'] == 'Never', 'local Fluentd pin/policy')
    require('/opt/mts-fluentd/loki-retry-all.rb' in c['args'], 'retry all non-2xx without discarding chunks')
    require({'name': 'SERVERENGINE_SOCKETMANAGER_SOCK_DIR', 'value': '/fluentd/state'} in c['env'],
            'ServerEngine socket must use writable collector state on read-only root')
    require(c['securityContext']['runAsGroup'] == 2000 and 'runAsUser' not in c['securityContext'], 'resolve UID from image')
    require({'name': 'app-logs', 'mountPath': '/var/log/nginx', 'readOnly': True} in c['volumeMounts'], 'read-only shared app log volume')
    conf = (obs/'fluent.conf').read_text()
    require(conf.count('@type tail') == 2 and '@type json' in conf and '@type none' in conf, 'access and native error parsers')
    require('time_key timestamp' not in conf, 'Loki ingestion time must not truncate fresh window to Nginx seconds')
    require('message_key message' in conf and 'Time.now.utc.iso8601' in conf, 'native error and UTC ingestion timestamp')
    require('workers 1' in conf and conf.count('flush_thread_count 1') == 2, 'single worker/flush thread')
    for typ, source in [('access', 'access.json'), ('error', 'error.log')]:
        require(f'path /var/log/nginx/{source}' in conf and f'source_file /var/log/nginx/{source}' in conf, 'exact source path')
        require(f'pos_file /fluentd/state/{typ}.pos' in conf, 'separate position state')
    labels = re.findall(r'^\s*extra_labels (.*)$', conf, re.M)
    require(len(labels) == 2, 'two stream label declarations')
    for raw, typ in zip(labels, ['access', 'error']):
        require(json.loads(raw) == dict(namespace='mts-app', app='nginx-demo', container='nginx', collector='fluentd', log_type=typ), 'fixed low cardinality labels')
    for value in ['@type file', 'total_limit_size 32m', 'overflow_action block', 'retry_forever true', 'flush_interval 2s', 'line_format json']:
        require(conf.count(value) == 2, 'bounded retrying buffers: ' + value)
    require(conf.count('url http://loki.mts-observability.svc.cluster.local:3100') == 2, 'plugin base URL')
    docker = (root/'images/fluentd/Dockerfile').read_text()
    for key in ['FLUENTD_BASE_IMAGE', 'FLUENTD_VERSION', 'FLUENTD_GEM_SHA256', 'FLUENTD_LOKI_PLUGIN_VERSION', 'FLUENTD_LOKI_PLUGIN_GEM_SHA256']:
        require(f'ARG {key}={os.environ[key]}' in docker, f'Dockerfile pin {key}')
    require('--ignore-dependencies' in docker and 'bundle check' in docker, 'no unlocked dependency resolution')
    lock = (root/'images/fluentd/Gemfile.lock').read_text()
    require(f"    fluentd ({os.environ['FLUENTD_VERSION']})" in lock and
            f"    fluent-plugin-grafana-loki ({os.environ['FLUENTD_LOKI_PLUGIN_VERSION']})" in lock, 'gem lock versions')
    require('USER 10002:2000' in docker and 'useradd --uid 10002 --gid 2000' in docker, 'dedicated numeric image user permissions')
    if shutil.which('kubectl') and (root/'kubernetes/app/kustomization.yaml').exists():
        rendered = subprocess.run(['kubectl', 'kustomize', str(obs)], check=True, capture_output=True, text=True, timeout=20).stdout
        resources = list(yaml.safe_load_all(rendered))
        identities = [(r['apiVersion'], r['kind'], r['metadata'].get('namespace'), r['metadata']['name']) for r in resources]
        require(len(identities) == len(set(identities)), 'duplicate rendered resources')
        require(not any(r['kind'] == 'Namespace' for r in resources), 'namespaces are declared by kubernetes/platform')
        apps = [r for r in resources if r['kind'] == 'Deployment' and r['metadata']['name'] == 'nginx-demo']
        require(len(apps) == 1 and apps[0]['metadata']['namespace'] == 'mts-app', 'one merged Nginx Deployment')
        spec = apps[0]['spec']['template']['spec']
        require(spec['securityContext']['fsGroup'] == 2000, 'merged shared volume group')
        require({c['name'] for c in spec['containers']} == {'nginx', 'fluentd'}, 'merged app plus collector')
        require(any(v['name'] == 'app-logs' and 'emptyDir' in v for v in spec['volumes']), 'base shared log volume')
        print('PASS observability overlay: local Kustomize render, unique resources, merged volumes/sidecar')
    else:
        print('SKIP overlay render: kubectl or Nginx app base unavailable')
    print('PASS observability static: YAML, interfaces, pins, config checksums, parsers, buffers, ownership')

def runtime():
    for key in ['KUBE_CONTEXT', 'GATEWAY_BASE_URL', 'PROMETHEUS_BASE_URL', 'LOKI_BASE_URL', 'RUN_ID', 'EVIDENCE_DIR']:
        require(os.environ.get(key), 'missing environment: ' + key)
    require(os.environ['KUBE_CONTEXT'] == 'kind-mts-engineer', 'explicit project context required')
    run_id = os.environ['RUN_ID']
    require(re.fullmatch(r'mts-[A-Za-z0-9-]+-[0-9a-f]+', run_id), 'unsafe or non-project RUN_ID')
    for key in ['GATEWAY_BASE_URL', 'PROMETHEUS_BASE_URL', 'LOKI_BASE_URL']:
        u = urlparse(os.environ[key])
        require(u.scheme == 'http' and u.hostname == '127.0.0.1' and u.port and
                not u.username and not u.password and u.path in ['', '/'] and not u.query and not u.fragment, key + ': loopback HTTP forward required')
    evidence = Path(os.environ['EVIDENCE_DIR']).resolve()
    require(evidence.is_relative_to((root/'.local').resolve()), 'evidence must be under ignored .local/')
    evidence.mkdir(parents=True, exist_ok=True)
    def command(args):
        return subprocess.run(args, check=True, capture_output=True, text=True, timeout=20).stdout
    def kube(resource, namespace, *args):
        return json.loads(command(['kubectl', '--context', 'kind-mts-engineer', '-n', namespace, 'get', resource, *args, '-o', 'json']))
    deployment = kube('deployment', 'mts-app', 'nginx-demo')
    pod_spec = deployment['spec']['template']['spec']
    sidecars = [c for c in pod_spec['containers'] if c['name'] == 'fluentd']
    require(len(sidecars) == 1, 'Fluentd sidecar missing')
    sidecar = sidecars[0]
    require(sidecar['image'] == os.environ['FLUENTD_IMAGE'] and sidecar['imagePullPolicy'] == 'Never', 'Fluentd sidecar image mismatch')
    require('/opt/mts-fluentd/loki-retry-all.rb' in sidecar.get('args', []), 'collector must retain chunks on HTTP rejection')
    require({'name': 'app-logs', 'mountPath': '/var/log/nginx', 'readOnly': True} in sidecar['volumeMounts'], 'sidecar shared log mount missing')
    require(any(v.get('configMap', {}).get('name') == 'fluentd-config' for v in pod_spec['volumes']), 'sidecar config volume missing')
    config = kube('configmap', 'mts-app', 'fluentd-config')
    expected_config = (obs/'fluent.conf').read_text()
    require(config['data']['fluent.conf'] == expected_config, 'deployed Fluentd config differs from committed config')
    checksum = hashlib.sha256(expected_config.encode()).hexdigest()
    require(deployment['spec']['template']['metadata']['annotations'].get('mts-engineer/fluentd-config-sha256') == checksum, 'deployment config rollout annotation mismatch')
    pods = kube('pods', 'mts-app', '-l', 'app.kubernetes.io/name=nginx-demo')['items']
    pods = [p for p in pods if not p['metadata'].get('deletionTimestamp')]
    require(len(pods) == 1, 'expected exactly one active Nginx pod')
    pod = pods[0]
    require(pod['metadata'].get('annotations', {}).get('mts-engineer/fluentd-config-sha256') == checksum, 'pod has stale collector config')
    statuses = [c for c in pod['status'].get('containerStatuses', []) if c['name'] == 'fluentd']
    require(len(statuses) == 1 and statuses[0].get('ready') and statuses[0].get('imageID'), 'running ready Fluentd image not observed')
    require(any(c['name'] == 'fluentd' and c['image'] == os.environ['FLUENTD_IMAGE'] for c in pod['spec']['containers']), 'pod collector image mismatch')
    producer_pod = pod['metadata']['name']
    (evidence/'collector.json').write_text(json.dumps({'pod': producer_pod, 'image': sidecar['image'], 'imageID': statuses[0]['imageID'], 'config_sha256': checksum}, indent=2))
    poll_deadline = None
    def api(base, path, filename, params=None):
        dest = evidence/filename
        remaining = min(10, poll_deadline-time.monotonic()) if poll_deadline else 10
        require(remaining > 0, 'query deadline exhausted')
        args = ['curl', '--silent', '--show-error', '--fail', '--connect-timeout', '3', '--max-time', str(remaining), '--output', str(dest), '--get', base.rstrip('/')+path]
        for key, value in (params or {}).items():
            args.extend(['--data-urlencode', f'{key}={value}'])
        command(args)
        return json.loads(dest.read_text())
    def poll(label, action):
        nonlocal poll_deadline
        deadline = time.monotonic() + 180
        poll_deadline = deadline
        last = 'no result'
        while True:
            try:
                result = action()
                poll_deadline = None
                return result
            except (AssertionError, KeyError, ValueError, subprocess.SubprocessError) as error:
                last = str(error)
            if time.monotonic() >= deadline:
                raise AssertionError(f'{label}: failed within 180s: {last[:300]}')
            time.sleep(min(2, max(0, deadline-time.monotonic())))
    prom_base = os.environ['PROMETHEUS_BASE_URL']
    def metrics():
        targets = api(prom_base, '/api/v1/targets', 'prometheus-targets.json')
        require(targets['status'] == 'success', 'targets API failure')
        active = targets['data']['activeTargets']
        require(len(active) == 2, 'exactly two active scrape targets required')
        for job, port in [('prometheus', 9090), ('loki', 3100)]:
            selected = [t for t in active if t['labels'].get('job') == job]
            require(len(selected) == 1 and selected[0]['health'] == 'up', job + ': healthy target required')
            require(selected[0]['scrapeUrl'] == f'http://{job}.mts-observability.svc.cluster.local:{port}/metrics' and selected[0].get('lastScrape'), job + ': real scrape URL/time required')
        for name, query in [('up-prometheus', 'up{job="prometheus"}'), ('up-loki', 'up{job="loki"}'),
                            ('build-info', 'prometheus_build_info{job="prometheus"}')]:
            result = api(prom_base, '/api/v1/query', f'prometheus-{name}.json', {'query': query})
            require(result['status'] == 'success' and result['data']['resultType'] == 'vector', query + ': vector required')
            samples = result['data']['result']
            require(len(samples) == 1 and float(samples[0]['value'][1]) == 1, query + ': exactly one sample with value 1 required')
            if name == 'build-info':
                require(samples[0]['metric']['version'] == os.environ['PROMETHEUS_VERSION'].removeprefix('v'), 'Prometheus version mismatch')
        return True
    poll('Prometheus scrapes/queries', metrics)
    print('PASS Prometheus: prometheus/loki targets healthy, up=1, pinned build_info=1')
    gateway = os.environ['GATEWAY_BASE_URL'].rstrip('/')
    # Nanoseconds immediately before requests; never backdate a window to accept
    # historical evidence. Fluentd assigns high-resolution ingestion event time.
    start = time.time_ns()
    def request(suffix, path, expected_status):
        name = run_id + '-' + suffix
        code = command(['curl', '--silent', '--show-error', '--connect-timeout', '3', '--max-time', '10',
                        '-H', 'Host: mts.local', '-H', 'X-MTS-Request-ID: '+name,
                        '--dump-header', str(evidence/(suffix+'-headers.txt')),
                        '--output', str(evidence/(suffix+'-body.txt')), '--write-out', '%{http_code}', gateway+path]).strip()
        require(code == str(expected_status), f'{path}: expected {expected_status}, got {code}')
        if expected_status == 200:
            require((evidence/(suffix+'-body.txt')).read_bytes() == b'MTS Engineer Hack: OK\n', 'exact response bytes')
            headers = (evidence/(suffix+'-headers.txt')).read_text()
            require(re.search(r'^content-type:\s*text/plain(?:\s*;[^\r\n]*)?\s*$', headers, re.I | re.M), 'text/plain response required')
        return name
    selector = '{namespace="mts-app",app="nginx-demo",container="nginx",collector="fluentd",log_type="%s"}'
    queries = {}
    def logs(name, log_type, query, path, request_id=None, status=None):
        end = time.time_ns()
        queries[name] = dict(query=query, start=start, end=end)
        (evidence/'observability-queries.json').write_text(json.dumps(queries, indent=2)+'\n')
        result = api(os.environ['LOKI_BASE_URL'], '/loki/api/v1/query_range', 'loki-'+name+'.json',
                     {'query': query, 'start': start, 'end': end, 'direction': 'forward', 'limit': 1000})
        require(result['status'] == 'success' and result['data']['resultType'] == 'streams', name + ': streams required')
        matches = []
        for stream in result['data']['result']:
            require(all(stream['stream'].get(k) == v for k, v in dict(namespace='mts-app', app='nginx-demo', container='nginx', collector='fluentd', log_type=log_type).items()), 'wrong producer labels')
            for timestamp, line in stream['values']:
                require(start <= int(timestamp) <= end, 'log outside fresh window')
                record = json.loads(line)
                require(record.get('pod') == producer_pod, 'log pod differs from observed collector pod')
                source = 'access.json' if log_type == 'access' else 'error.log'
                require(record.get('source_file') == '/var/log/nginx/'+source, 'wrong source_file')
                parsed = dt.datetime.fromisoformat(record['timestamp'].replace('Z', '+00:00'))
                require(parsed.tzinfo is not None, 'timestamp needs timezone')
                require(start//1_000_000_000 <= parsed.timestamp() <= end/1_000_000_000, 'body timestamp outside fresh window')
                if log_type == 'access':
                    require(record.get('request_id') == request_id and record.get('method') == 'GET' and record.get('path') == path and record.get('host') == 'mts.local', 'access correlation fields')
                    require(type(record.get('status')) is int and record['status'] == status, 'integer status required')
                else:
                    message = record.get('message', '')
                    require(path in message and 'open()' in message and 'failed' in message and 'No such file or directory' in message, 'genuine native missing-file error required')
                    require(parsed.utcoffset() == dt.timedelta(0), 'error ingestion timestamp must be UTC')
                matches.append(record)
        require(matches, name + ': empty successful query is not evidence')
        return len(matches)
    access_id = request('access', '/', 200)
    access_query = selector % 'access' + f' | json | request_id="{access_id}" | status=200'
    access_count = poll('fresh 200 access', lambda: logs('access', 'access', access_query, '/', access_id, 200))
    error_path = '/error/'+run_id+'-error'
    error_id = request('error', error_path, 404)
    negative_query = selector % 'access' + f' | json | request_id="{error_id}" | status=404'
    error_query = selector % 'error' + f' |= "{error_path}" | json'
    negative_count = poll('fresh 404 access', lambda: logs('negative-access', 'access', negative_query, error_path, error_id, 404))
    error_count = poll('native Nginx missing-file error', lambda: logs('error', 'error', error_query, error_path))
    # Compare the fresh Loki evidence with the actual producer files. Reading
    # files is diagnostic evidence; all requests above still traverse Gateway.
    def producer_file(path):
        return command(['kubectl', '--context', 'kind-mts-engineer', '--request-timeout=10s',
                        '-n', 'mts-app', 'exec', producer_pod, '-c', 'nginx', '--', 'cat', path])
    source_access = [json.loads(line) for line in producer_file('/var/log/nginx/access.json').splitlines()]
    correlated = [r for r in source_access if r.get('request_id') in (access_id, error_id)]
    require(len(correlated) == 2, 'producer file must contain both fresh correlated requests')
    for request_id, path, status in [(access_id, '/', 200), (error_id, error_path, 404)]:
        selected = [r for r in correlated if r.get('request_id') == request_id]
        require(len(selected) == 1 and selected[0].get('path') == path
                and selected[0].get('status') == status and selected[0].get('method') == 'GET'
                and selected[0].get('host') == 'mts.local', 'producer access record mismatch')
    source_errors = [line for line in producer_file('/var/log/nginx/error.log').splitlines() if error_path in line]
    require(len(source_errors) == 1 and all(value in source_errors[0] for value in
            ('open()', 'failed', 'No such file or directory')), 'producer native missing-file error required')
    (evidence/'nginx-source-access.json').write_text(json.dumps(correlated, indent=2)+'\n')
    (evidence/'nginx-source-error.txt').write_text('\n'.join(source_errors)+'\n')
    summary = dict(run_id=run_id, pod=producer_pod, access_count=access_count,
                   negative_access_count=negative_count, error_count=error_count, queries=queries,
                   producer_access_count=len(correlated), producer_error_count=len(source_errors))
    (evidence/'observability-summary.json').write_text(json.dumps(summary, indent=2)+'\n')
    print(f'PASS Loki: run={run_id} access={access_count} negative_access={negative_count} native_error={error_count}')
    print('PASS Nginx producer files: fresh 200/404 access records and genuine native missing-file error')
    print(f'Evidence: {evidence}')

try:
    static() if sys.argv[1] == 'static' else runtime()
except (AssertionError, KeyError, ValueError, OSError, subprocess.SubprocessError) as error:
    print('FAIL observability: '+str(error)[:500], file=sys.stderr)
    sys.exit(1)
PY
