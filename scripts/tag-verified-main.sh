#!/bin/bash
set -euo pipefail
[[ "${RELEASE_EVENT:-}" == push && "${RELEASE_BRANCH:-}" == main ]] || { echo 'Only verified main push runs may be tagged'; exit 1; }
[[ "${RELEASE_SHA:-}" =~ ^[a-f0-9]{40}$ && "${RELEASE_RUN_NUMBER:-}" =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid release identity'; exit 1; }
[[ "$(git rev-parse HEAD)" == "$RELEASE_SHA" ]] || { echo 'Checkout differs from the tested commit'; exit 1; }
release_tag="backend-${RELEASE_RUN_NUMBER}-${RELEASE_SHA:0:12}"
if [[ -n "$(git ls-remote --tags origin "refs/tags/$release_tag")" ]]; then
  git fetch --no-tags origin "refs/tags/$release_tag:refs/tags/$release_tag"
  [[ "$(git cat-file -t "refs/tags/$release_tag")" == tag && "$(git rev-parse "$release_tag^{commit}")" == "$RELEASE_SHA" ]] || { echo 'Existing tag differs; refusing to move it'; exit 1; }
  echo "Already tagged: $release_tag"
else
  git -c user.name='github-actions[bot]' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
    tag -a "$release_tag" "$RELEASE_SHA" -m "Verified main CI: ${RELEASE_CI_URL:-unknown}"
  git push origin "refs/tags/$release_tag"
  echo "Created: $release_tag"
fi
