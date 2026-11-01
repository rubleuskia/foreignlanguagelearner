#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cloud_test_python="${PYTHON:-python3}"
if [[ -n "${DYNAMODB_LOCAL_URL:-}" ]]; then
  cd "$repo_root"
  "$cloud_test_python" -m unittest discover -s backend -p 'test_*.py' -v
  exit
fi
cloud_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/fll-dynamo.XXXXXX")"
cloud_test_pid=""
cleanup() {
  if [[ -n "$cloud_test_pid" ]]; then kill "$cloud_test_pid" 2>/dev/null || true; wait "$cloud_test_pid" 2>/dev/null || true; fi
  rm -rf "$cloud_test_dir"
}
trap cleanup EXIT
curl --fail --silent --show-error --retry 3 --location \
  https://s3.eu-central-1.amazonaws.com/dynamodb-local-frankfurt/dynamodb_local_latest.tar.gz \
  --output "$cloud_test_dir/dynamodb.tar.gz"
tar -xzf "$cloud_test_dir/dynamodb.tar.gz" -C "$cloud_test_dir"
cloud_test_port="$("$cloud_test_python" -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
(cd "$cloud_test_dir" && exec java -Djava.library.path="$cloud_test_dir/DynamoDBLocal_lib" \
  -jar "$cloud_test_dir/DynamoDBLocal.jar" -inMemory -sharedDb -port "$cloud_test_port") > "$cloud_test_dir/server.log" 2>&1 &
cloud_test_pid=$!
export DYNAMODB_LOCAL_URL="http://127.0.0.1:$cloud_test_port"
"$cloud_test_python" - <<'PY'
import os,time,boto3
from botocore.config import Config
client=boto3.client('dynamodb',region_name='eu-central-1',endpoint_url=os.environ['DYNAMODB_LOCAL_URL'],
    aws_access_key_id='local',aws_secret_access_key='local',config=Config(connect_timeout=1,read_timeout=1,retries={'max_attempts':0}))
for attempt in range(30):
    try: client.list_tables(); break
    except Exception:
        if attempt == 29: raise RuntimeError('Local DynamoDB did not start') from None
        time.sleep(1)
PY
cd "$repo_root"
"$cloud_test_python" -m unittest discover -s backend -p 'test_*.py' -v
