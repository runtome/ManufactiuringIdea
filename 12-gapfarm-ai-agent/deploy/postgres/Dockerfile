# GAPFarm database image: PostGIS + pgvector on PostgreSQL 16 (DDS-12 §1, ADR-G01).
# There is no official image with both extensions; this adds the Debian pgvector package to the PostGIS image.
FROM postgis/postgis:16-3.4
RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-16-pgvector \
 && rm -rf /var/lib/apt/lists/*
# schema.sql is mounted by docker-compose.yml into /docker-entrypoint-initdb.d/ and applied on first start.
