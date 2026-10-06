# golden/lib/store.sh -- the golden-image object store, for any S3-compatible service (sourced).
#
# Configuration (environment; the workflows fill it from repo variables and secrets):
#   STORE_BUCKET                       bucket name
#   S3_ENDPOINT_URL                    endpoint, e.g. https://fly.storage.tigris.dev (Tigris),
#                                      https://<account>.r2.cloudflarestorage.com (R2),
#                                      https://s3.<region>.backblazeb2.com (B2); empty = AWS S3
#   AWS_REGION                         region ("auto" for Tigris and R2; the AWS region for S3)
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY   the store's keys (STORE_* secrets, else the AWS ones)
#
#   store <aws-cli s3/s3api args...>   aws-cli against the store (adds --endpoint-url when set)
#   store_uri KEY                      s3://$STORE_BUCKET/KEY
#   store_tune                         multipart settings for streaming large images
: "${STORE_BUCKET:?STORE_BUCKET is not set}"
if [ -n "${S3_ENDPOINT_URL:-}" ]; then
  # Non-AWS stores: compute/validate request checksums only where the S3 API requires them
  # (aws-cli >= 2.23 otherwise sends CRC checksums some S3-compatible services reject).
  export AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
fi
store() {
  if [ -n "${S3_ENDPOINT_URL:-}" ]; then aws --endpoint-url "$S3_ENDPOINT_URL" "$@"; else aws "$@"; fi
}
store_uri() { printf 's3://%s/%s' "$STORE_BUCKET" "$1"; }
store_tune() {
  # 128 MiB parts, 64 in flight. aws-cli raises the part size by itself when --expected-size / 10,000
  # parts would exceed it, so even a 2 TB stream stays under the 10,000-part limit (870 GB -> ~6,500 parts).
  aws configure set default.s3.max_concurrent_requests 64
  aws configure set default.s3.multipart_chunksize 128MB
  aws configure set default.s3.max_queue_size 256
}
