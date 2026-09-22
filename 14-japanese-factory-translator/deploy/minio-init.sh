#!/bin/sh
# GenbaGo — MinIO bootstrap (runs once from the minio-init service). Reads every credential from /run/secrets; never echoes them.
set -eu
mc alias set local http://minio:9000 "$(cat /run/secrets/minio_root_user)" "$(cat /run/secrets/minio_root_password)" >/dev/null
for b in "$S3_BUCKET_DOCS" "$S3_BUCKET_RESULTS" "$S3_BUCKET_INDEX"; do mc mb --ignore-existing "local/$b"; done
mc mb --ignore-existing --with-lock "local/$S3_BUCKET_EXPORTS"                    # SEC-J26: exports are locked
mc version enable "local/$S3_BUCKET_DOCS"                                          # uploads are versioned
mc retention set --default COMPLIANCE 730d "local/$S3_BUCKET_EXPORTS"
mc ilm rule add --expire-days 365 "local/$S3_BUCKET_DOCS" || true                  # NFR-05 (the scheduler also enforces retention)
mc ilm rule add --expire-days 365 "local/$S3_BUCKET_RESULTS" || true
mc admin user add local "$(cat /run/secrets/s3_access_key)" "$(cat /run/secrets/s3_secret_key)" >/dev/null 2>&1 || true
cat > /tmp/genbago-policy.json <<POLICY
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:GetObject","s3:PutObject","s3:ListBucket","s3:GetObjectVersion"],
 "Resource":["arn:aws:s3:::$S3_BUCKET_DOCS","arn:aws:s3:::$S3_BUCKET_DOCS/*","arn:aws:s3:::$S3_BUCKET_RESULTS","arn:aws:s3:::$S3_BUCKET_RESULTS/*",
             "arn:aws:s3:::$S3_BUCKET_EXPORTS","arn:aws:s3:::$S3_BUCKET_EXPORTS/*","arn:aws:s3:::$S3_BUCKET_INDEX","arn:aws:s3:::$S3_BUCKET_INDEX/*"]}]}
POLICY
mc admin policy create local genbago-app /tmp/genbago-policy.json >/dev/null 2>&1 || true
mc admin policy attach local genbago-app --user "$(cat /run/secrets/s3_access_key)" >/dev/null 2>&1 || true
echo "minio-init: buckets ready"
