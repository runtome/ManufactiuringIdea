#!/bin/sh
# Genba Memory — MinIO bootstrap (runs once from the minio-init service).
# Reads every credential from /run/secrets and never echoes one.
# The originals bucket is created WITH OBJECT LOCK: C-01 and FR-05 are a storage
# property here, not only a database trigger (SEC-H20, THR-H15).
set -eu
mc alias set local http://minio:9000 "$(cat /run/secrets/minio_root_user)" "$(cat /run/secrets/minio_root_password)" >/dev/null

mc mb --ignore-existing --with-lock "local/$S3_BUCKET_ORIGINALS"
for b in "$S3_BUCKET_OCR" "$S3_BUCKET_EXPORTS" "$S3_BUCKET_TMP"; do
  mc mb --ignore-existing "local/$b"
done

mc version enable "local/$S3_BUCKET_ORIGINALS"
mc version enable "local/$S3_BUCKET_EXPORTS"
mc retention set --default COMPLIANCE "${RETENTION_DAYS_ORIGINALS}d" "local/$S3_BUCKET_ORIGINALS"

# The OCR artefacts and scratch space are derived data: they can be rebuilt from the
# originals, so they expire. The originals themselves never do on a schedule — an admin
# runs the retention job explicitly (OPS-15 §11).
mc ilm rule add --expire-days 365 "local/$S3_BUCKET_OCR" || true
mc ilm rule add --expire-days 7   "local/$S3_BUCKET_TMP" || true

mc admin user add local "$(cat /run/secrets/s3_access_key)" "$(cat /run/secrets/s3_secret_key)" >/dev/null 2>&1 || true
cat > /tmp/genbamemory-policy.json <<POLICY
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:GetObject","s3:PutObject","s3:ListBucket","s3:GetObjectVersion"],
 "Resource":["arn:aws:s3:::$S3_BUCKET_ORIGINALS","arn:aws:s3:::$S3_BUCKET_ORIGINALS/*","arn:aws:s3:::$S3_BUCKET_OCR","arn:aws:s3:::$S3_BUCKET_OCR/*",
             "arn:aws:s3:::$S3_BUCKET_EXPORTS","arn:aws:s3:::$S3_BUCKET_EXPORTS/*","arn:aws:s3:::$S3_BUCKET_TMP","arn:aws:s3:::$S3_BUCKET_TMP/*"]}]}
POLICY
mc admin policy create local genbamemory-app /tmp/genbamemory-policy.json >/dev/null 2>&1 || true
mc admin policy attach local genbamemory-app --user "$(cat /run/secrets/s3_access_key)" >/dev/null 2>&1 || true
echo "minio-init: buckets ready (originals under object lock)"
