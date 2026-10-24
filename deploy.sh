#!/usr/bin/env bash
# Uploads the site to S3, where CloudFront serves it as eu4tech.jane.berlin.
#
#   ./deploy.sh              full deploy: the page, the game data (data.json,
#                            countries.json, missions.json, ideas.json) and
#                            the flags and icons -- run extract.rb and
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

tmp="$(mktemp -d)"
src="."   # where seo.rb reads the data from: here after a full extraction, else what is on S3 (still gzipped; seo.rb copes)

if [ "${1:-}" = "--code-only" ]; then
  src="$tmp"
  for f in countries ideas missions; do
    aws s3 cp "s3://${bucket}/${f}.json" "$tmp/${f}.json" --only-show-errors || {
      echo "No ${f}.json on S3 yet. The first deploy must be a full one: ./deploy.sh on a machine with the game." >&2
      exit 1
    }
  done
else
  for f in data countries missions ideas links; do
    [ -f "${f}.json" ] || { echo "No ${f}.json -- run: ruby extract.rb && ruby extract_countries.rb" >&2; exit 1; }
  done
  aws s3 cp data.json "s3://${bucket}/data.json" --only-show-errors \
    --cache-control "no-cache" --content-type "application/json"
  # forces.json (extract_save.rb, from a save) is optional: without it the page just leaves out armies and the economy.
  for f in countries missions ideas $([ -f forces.json ] && echo forces); do
    gzip -9c "${f}.json" | aws s3 cp - "s3://${bucket}/${f}.json" --only-show-errors \
      --cache-control "no-cache" --content-type "application/json" --content-encoding gzip
  done
  # links.json (country name -> tag and start date) is read by other apps that link to this site.
  aws s3 cp links.json "s3://${bucket}/links.json" --only-show-errors \
    --cache-control "public, max-age=3600" --content-type "application/json"
  aws s3 sync flags/ "s3://${bucket}/flags/" --delete --only-show-errors \
    --cache-control "public, max-age=86400" --content-type "image/png"
  aws s3 sync icons/ "s3://${bucket}/icons/" --delete --only-show-errors \
    --cache-control "public, max-age=86400" --content-type "image/png"
fi
# The crawlable side: a page per country, the sitemap and the front page (seo.rb).
ruby seo.rb "$src/countries.json" "$src/ideas.json" "$src/missions.json" index.html "$tmp/seo"
# The country pages have no file extension, so they say they are HTML themselves; --delete drops countries that no longer have a page.
aws s3 sync "$tmp/seo/country" "s3://${bucket}/country" --delete --only-show-errors \
  --content-type "text/html; charset=utf-8" --cache-control "public, max-age=3600"
aws s3 cp "$tmp/seo/sitemap.xml" "s3://${bucket}/sitemap.xml" --only-show-errors \
  --cache-control "public, max-age=3600" --content-type "application/xml"
aws s3 cp robots.txt "s3://${bucket}/robots.txt" --only-show-errors \
  --cache-control "public, max-age=3600" --content-type "text/plain; charset=utf-8"
aws s3 cp og-image.jpg "s3://${bucket}/og-image.jpg" --only-show-errors \
  --cache-control "public, max-age=86400" --content-type "image/jpeg"

# The page last, so a new page never points at data that isn't there yet.
aws s3 cp "$tmp/seo/index.html" "s3://${bucket}/index.html" --only-show-errors \
  --cache-control "no-cache" --content-type "text/html; charset=utf-8"

echo "Deployed to s3://${bucket}${1:+ ($1)}"
