#!/usr/bin/env bash
# Uploads the site to S3, where CloudFront serves it as eu4tech.jane.berlin.
#
#   ./deploy.sh              full deploy: the page, the game data (data.json,
#                            countries.json, missions.json, ideas.json) and
#                            the flags -- run extract.rb and
#                            extract_countries.rb first; needs a machine
#                            with Europa Universalis IV installed
#   ./deploy.sh --code-only  the page only, reusing the data already on S3 --
#                            what CI runs on every push to main
#
# Nothing here is versioned: the page and the data are sent with no-cache (the
# data is gzipped, since it is a few MB of JSON), so a deploy shows up at once.
set -euo pipefail
cd "$(dirname "$0")"

bucket="${EU4_BUCKET:-eu4tech.jane.berlin}"
# Locally, use the named profile; in CI, credentials come from the OIDC role.
[ -n "${CI:-}" ] || export AWS_PROFILE="${AWS_PROFILE:-personal}"

if [ "${1:-}" != "--code-only" ]; then
  for f in data countries missions ideas; do
    [ -f "${f}.json" ] || { echo "No ${f}.json -- run: ruby extract.rb && ruby extract_countries.rb" >&2; exit 1; }
  done
  aws s3 cp data.json "s3://${bucket}/data.json" --only-show-errors \
    --cache-control "no-cache" --content-type "application/json"
  for f in countries missions ideas; do
    gzip -9c "${f}.json" | aws s3 cp - "s3://${bucket}/${f}.json" --only-show-errors \
      --cache-control "no-cache" --content-type "application/json" --content-encoding gzip
  done
  aws s3 sync flags/ "s3://${bucket}/flags/" --delete --only-show-errors \
    --cache-control "public, max-age=86400" --content-type "image/png"
fi
# The page last, so a new page never points at data that isn't there yet.
aws s3 cp index.html "s3://${bucket}/index.html" --only-show-errors \
  --cache-control "no-cache" --content-type "text/html; charset=utf-8"

echo "Deployed to s3://${bucket}${1:+ ($1)}"
