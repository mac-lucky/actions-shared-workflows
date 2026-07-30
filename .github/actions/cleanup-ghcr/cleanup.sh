#!/usr/bin/env bash
# Delete GHCR versions that carry no tag and that no tagged manifest list points at.
set -euo pipefail

: "${GITHUB_STEP_SUMMARY:=/dev/null}"

if ! [[ $REGISTRY_IMAGE =~ ^ghcr\.io/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  echo "::error::registry_image must look like ghcr.io/<owner>/<image> (got '$REGISTRY_IMAGE')"
  exit 1
fi

# $(( )) evaluates whatever it is handed: a leading zero is read as octal and a
# 19-digit value overflows to a cutoff in the future, which would make every
# untagged version deletable - the opposite of what this input is for.
if ! [[ $GRACE_HOURS =~ ^(0|[1-9][0-9]{0,4})$ ]]; then
  echo "::error::grace_hours must be a whole number of hours from 0 to 99999 (got '$GRACE_HOURS')"
  exit 1
fi

# Anything other than an exact "true" would delete for real, so refuse instead.
case $DRY_RUN in
  true | false) ;;
  *)
    echo "::error::dry_run must be true or false (got '$DRY_RUN')"
    exit 1
    ;;
esac

OWNER=${REGISTRY_IMAGE#ghcr.io/}
OWNER=${OWNER%%/*}
IMAGE_NAME=${REGISTRY_IMAGE##*/}
PACKAGE_API="https://api.github.com/users/$OWNER/packages/container/$IMAGE_NAME"
REGISTRY_API="https://ghcr.io/v2/$OWNER/$IMAGE_NAME"

# GHCR matches Accept strictly and answers 404 for any type not listed here.
# A single-arch tag is an OCI image manifest rather than an index, and omitting
# that type made those tags unreadable.
MANIFEST_TYPES="application/vnd.oci.image.index.v1+json,\
application/vnd.docker.distribution.manifest.list.v2+json,\
application/vnd.docker.distribution.manifest.v2+json,\
application/vnd.oci.image.manifest.v1+json"

CUTOFF=$(( $(date -u +%s) - GRACE_HOURS * 3600 ))

# Leaves the status in HTTP_CODE and everything before it in BODY. A transport
# failure yields an empty code, which every caller below treats as a failure.
request() {
  local response
  response=$(curl -sS -w $'\n%{http_code}' "$@" || true)
  HTTP_CODE=${response##*$'\n'}
  BODY=${response%$'\n'*}
}

api() {
  request -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" "$@"
}

summarize() {
  echo "$1"
  {
    echo "### GHCR Cleanup: $IMAGE_NAME"
    echo "$1"
  } >> "$GITHUB_STEP_SUMMARY"
}

load_versions() {
  api "$PACKAGE_API/versions?per_page=100"
  if [ "$HTTP_CODE" != "200" ]; then
    echo "::warning::Failed to list versions (HTTP ${HTTP_CODE:-none}), skipping cleanup"
    return 1
  fi
  if ! jq -e 'type == "array"' <<< "$BODY" > /dev/null 2>&1; then
    echo "::warning::Unexpected API response, skipping cleanup"
    return 1
  fi
  # `null | length` is 0 in jq, so a version whose shape changed would read as
  # untagged and become a candidate. Refuse rather than guess.
  if jq -e 'any(.[]; (.metadata.container.tags | type) != "array")' <<< "$BODY" > /dev/null; then
    echo "::error::A version is missing metadata.container.tags - aborting rather than reading it as untagged"
    exit 1
  fi
}

tagged_digests() {
  jq -r '.[] | select(.metadata.container.tags | length > 0) | .name' <<< "$1"
}

# Records each tagged digest and every child it references. A tagged manifest
# that cannot be read would leave the set incomplete, and an incomplete set
# deletes live children, so that aborts the run.
protect() {
  local digest child
  for digest in "$@"; do
    if [ -n "${PROTECTED[$digest]:-}" ]; then
      continue
    fi
    PROTECTED[$digest]=1
    request -H "Authorization: Bearer $GHCR_TOKEN" -H "Accept: $MANIFEST_TYPES" \
      "$REGISTRY_API/manifests/$digest"
    if [ "$HTTP_CODE" != "200" ]; then
      echo "::error::Manifest fetch for $digest failed (HTTP ${HTTP_CODE:-none}) - aborting, the protected set would be incomplete"
      exit 1
    fi
    # A single-arch manifest has no children, which is not an error. Attestation
    # manifests are children of the index and are covered here too.
    while read -r child; do
      PROTECTED[$child]=1
    done < <(jq -r '.manifests[]?.digest // empty' <<< "$BODY")
  done
}

delete_version() {
  local id=$1 attempt=1
  while :; do
    api -X DELETE "$PACKAGE_API/versions/$id"
    case $HTTP_CODE in
      # 404 means someone else already removed it, which is the end state we want.
      204 | 404) return 0 ;;
      # The secondary rate limit answers 403 or 429; a plain 403 is a permissions
      # problem and retrying it would stall the run for every candidate.
      403 | 429)
        if [ "$attempt" -lt 3 ] && grep -qi 'rate limit' <<< "$BODY"; then
          sleep $(( attempt * 30 ))
          attempt=$(( attempt + 1 ))
          continue
        fi
        return 1
        ;;
      *) return 1 ;;
    esac
  done
}

if [ "$DRY_RUN" = "true" ]; then
  echo "DRY RUN - nothing will be deleted"
fi
echo "Cleaning up untagged versions for $OWNER/$IMAGE_NAME (grace: ${GRACE_HOURS}h)..."

if ! load_versions; then
  exit 0
fi

# updated_at wins over created_at so a re-pushed digest counts as fresh, and a
# version with no timestamp at all is treated as too new to touch.
UNTAGGED=$(jq -c --argjson cutoff "$CUTOFF" '
  [ .[]
    | select(.metadata.container.tags | length == 0)
    | { id, name, stale: ((.updated_at // .created_at) as $t
        | if $t == null then false else ($t | fromdateiso8601) < $cutoff end) } ]' <<< "$BODY")
CANDIDATES=$(jq -r '.[] | select(.stale) | [.id, .name] | @tsv' <<< "$UNTAGGED")
HELD=$(jq '[.[] | select(.stale | not)] | length' <<< "$UNTAGGED")

if [ -z "$CANDIDATES" ]; then
  summarize "Nothing to delete (held by grace window: $HELD)"
  exit 0
fi

# Candidates came from the listing above; the tagged set comes from a fresh one,
# so a tag created in between still protects its children.
if ! load_versions; then
  exit 0
fi
mapfile -t TAGGED < <(tagged_digests "$BODY")

if [ ${#TAGGED[@]} -eq 0 ]; then
  echo "No tagged versions found, skipping cleanup"
  exit 0
fi

GHCR_TOKEN=$(curl -sS -u "$OWNER:$GH_TOKEN" \
  "https://ghcr.io/token?scope=repository:$OWNER/$IMAGE_NAME:pull" | jq -r '.token')
if [ -z "$GHCR_TOKEN" ] || [ "$GHCR_TOKEN" = "null" ]; then
  echo "::error::Failed to obtain GHCR registry token - aborting to prevent accidental deletion"
  exit 1
fi

declare -A PROTECTED=()
protect "${TAGGED[@]}"

# Reading those manifests takes long enough for another build to publish, so
# refresh the tag list once more and protect anything new before deleting.
if ! load_versions; then
  exit 0
fi
mapfile -t TAGGED < <(tagged_digests "$BODY")
protect "${TAGGED[@]}"

DELETED=0
FAILED=0
FIRST_ERROR=""
while IFS=$'\t' read -r id digest; do
  if [ -n "${PROTECTED[$digest]:-}" ]; then
    continue
  fi
  if [ "$DRY_RUN" = "true" ]; then
    echo "would delete $digest ($id)"
    DELETED=$(( DELETED + 1 ))
    continue
  fi
  if delete_version "$id"; then
    DELETED=$(( DELETED + 1 ))
  else
    FAILED=$(( FAILED + 1 ))
    # Keep the first API message: without it a token problem looks like a count.
    if [ -z "$FIRST_ERROR" ]; then
      FIRST_ERROR="HTTP ${HTTP_CODE:-none}: $(jq -r '.message // "no message"' <<< "$BODY" 2> /dev/null || echo 'unparseable response')"
    fi
  fi
done <<< "$CANDIDATES"

if [ "$DRY_RUN" = "true" ]; then
  VERB="Would delete"
else
  VERB="Deleted"
fi
summarize "$VERB $DELETED untagged versions (protected: ${#PROTECTED[@]}, held by grace window: $HELD, failed: $FAILED)"

if [ "$FAILED" -gt 0 ]; then
  if [ "$DELETED" -eq 0 ]; then
    echo "::error::All $FAILED deletions failed ($FIRST_ERROR) - deleting package versions needs a classic PAT with the delete:packages scope"
    exit 1
  fi
  echo "::warning::$FAILED deletions failed ($FIRST_ERROR)"
fi
