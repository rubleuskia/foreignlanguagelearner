#!/bin/bash
set -euo pipefail
[[ "${RELEASE_EVENT:-}" == push && "${RELEASE_BRANCH:-}" == main ]] || { echo 'Only verified main push runs may be tagged'; exit 1; }
[[ "${RELEASE_SHA:-}" =~ ^[a-f0-9]{40}$ && "${RELEASE_RUN_NUMBER:-}" =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid release identity'; exit 1; }
[[ "$(git rev-parse HEAD)" == "$RELEASE_SHA" ]] || { echo 'Checkout differs from the tested commit'; exit 1; }
[[ "${RELEASE_CI_URL:-}" =~ ^https://github\.com/rubleuskia/foreignlanguagelearner/actions/runs/[1-9][0-9]*$ ]] || { echo 'Invalid CI run URL'; exit 1; }
# Read the reviewed base version from the tested commit, not mutable working-copy state.
release_version="$(git show "$RELEASE_SHA:backend/VERSION")"
[[ "$release_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || { echo 'Invalid backend/VERSION'; exit 1; }
release_tag="v${release_version}-backend.${RELEASE_RUN_NUMBER}"
release_metadata="$(python3 -c 'import json,os,sys; print(json.dumps({"schema_version":1,"version":sys.argv[1],"commit":os.environ["RELEASE_SHA"],"ci_run_number":int(os.environ["RELEASE_RUN_NUMBER"]),"ci_url":os.environ["RELEASE_CI_URL"]},sort_keys=True,separators=(",",":")))' "$release_version")"
if [[ -n "$(git ls-remote --tags origin "refs/tags/$release_tag")" ]]; then
  git fetch --no-tags origin "refs/tags/$release_tag:refs/tags/$release_tag"
  [[ "$(git cat-file -t "refs/tags/$release_tag")" == tag && "$(git rev-parse "$release_tag^{commit}")" == "$RELEASE_SHA" ]] || { echo 'Existing tag differs; refusing to move it'; exit 1; }
  [[ "$(git for-each-ref --format='%(contents)' "refs/tags/$release_tag")" == "$release_metadata" ]] || { echo 'Existing tag metadata differs; refusing to replace it'; exit 1; }
  echo "Already tagged: $release_tag"
else
  git -c user.name='github-actions[bot]' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
    tag -a "$release_tag" "$RELEASE_SHA" -m "$release_metadata"
  git push origin "refs/tags/$release_tag"
  echo "Created: $release_tag"
fi
