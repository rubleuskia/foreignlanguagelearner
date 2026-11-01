#!/bin/bash
set -euo pipefail
umask 077
control_repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$control_repo"
control_python="${PYTHON:-python3}"
control_venv="$control_repo/.cloud-control/venv"
if [[ ! -x "$control_venv/bin/python" ]]; then
  "$control_python" -m venv "$control_venv"
fi
control_lock_hash="$("$control_python" -c 'import hashlib; print(hashlib.sha256(open("backend/billing/requirements.lock","rb").read()).hexdigest())')"
if [[ ! -f "$control_venv/lock.sha256" ]] || [[ "$(cat "$control_venv/lock.sha256")" != "$control_lock_hash" ]]; then
  "$control_venv/bin/python" -m pip install --require-hashes -r backend/billing/requirements.lock
  printf '%s' "$control_lock_hash" > "$control_venv/lock.sha256"
fi
exec "$control_venv/bin/python" -m tools.cloud_control.server "$@"
