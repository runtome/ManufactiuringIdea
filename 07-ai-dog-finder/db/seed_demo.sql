-- =====================================================================
--  PawTrace — demo / test seed  (DDS-07 §9)
--  Deterministic (setseed) except UUIDv7 ids, which are time-based. Reproduces:
--    AC-02  20 planted lost/found pairs among 10,000 distractor sightings; matching runs THROUGH
--           pawtrace.search_candidates() + fusion_score() + calibrated_precision() — the real functions
--    App. A pair #1 = "Nok's dog": lost 2026-09-08 20:30+07 in Bangkok, sighted 2026-09-10 07:15+07 ≈ 2.1 km away,
--           cosine 0.83 → sim_visual 0.80; attr 1.0; spatial exp(−2.1008/3) = 0.4965; temporal 0.8432 (34.75 h into a 72 h window)
--           → score ≈ 0.7736 → calibrated precision 0.68 (bin 0.7–0.8) → rank 1 → notified
--    AC-06  one deletion request executed through the cascade trigger
--    AC-08  embedding v2 registered, re-embed job at 62 %, v1 still the only search_active version
--    AI-08  benchmark slices with a 16.9 % gap for black dogs → rebalance_required
--    FR-25  seven notifications for one user in one day → 5 sent, 2 turned into digest entries by the budget trigger
--
--  Run after schema.sql:   psql -v ON_ERROR_STOP=1 -f seed_demo.sql      (~ 20 s: 10,040 × 768-d vectors)
--  Re-run guard: aborts if pawtrace.report already has rows.
--
--  EXPECTED VALUES (TEST-07 TC-005 — re-derived in Python / NumPy; PostgreSQL execution pending, README-07)
--    regions 4 · users 12 (1 admin, 2 moderators, 2 shelters, 7 users) · devices 30 · model_version 6 (1 detector, 2 embedding, 1 attributes, 1 nsfw, 1 text)
--    reports before deletion: 10,000 distractors + 20 lost + 20 found + 1 (u7) = 10,041 · after: 10,040
--    photos 10,040 · dog_instance 10,040 · embedding v1 10,040 · embedding v2 6,225 (62.0 % of 10,041; the deleted instance was last) · text_embedding 40
--    planted pairs: every pair's found report appears in the lost report's top 10 (expected 20/20; AC-02 needs ≥ 16)
--        NumPy simulation of the construction (cosine c_i ∈ [0.78, 0.90] vs random 768-d distractors, max cosine ≈ 0.14): pair is rank 1 by cosine with probability ≈ 1
--    Appendix A match (pair #1): cosine 0.830 ± 0.001 · sim_visual 0.80 · attr_compat 1.0 · distance 2,100.8 ± 2 m (WGS84 geodesic) · spatial 0.4965 ± 0.0003
--        · temporal 0.8432 · score 0.7736 ± 0.0005 · calibrated_precision 0.680 · rank 1 · notified
--    decisions ≤ 26 (14 confirm on pairs #2–#15; up to 12 rejects of the rank-2 candidate of pairs #2–#13 — exist only where a distractor qualified)
--    reunions 3 (pairs #2–#4) → lost reports reunited 3, matched 11 (pairs #5–#15), found reports closed 3
--    threads 14 (one per confirm) · messages 4 (pair #5) · thread of pair #2: both consents true
--    notifications for user u1 (Nok): 7 inserted → 5 push + 2 digest (cap 5) · v_notify_budget.can_notify(u1) = false
--    calibration_bin v1 10 rows · benchmark_run 2 · benchmark_slice 8 (black: recall10 0.69, gap 16.87 → rebalance_required)
--    moderation_event 4 (2 hide by moderator, 1 nsfw_auto_hide, 1 ban_device) · abuse_report 3 (1 resolved) · duplicate_cluster 1
--    deletion_request 1: state db_done, summary {reports 1, photos 1, embeddings 1}; audit tombstone actor = deletion_request; u7 anonymised
--    subscriptions 3 · push_subscription 4 · config_version 1 · rate_limit_bucket 3
--    audit.log ≥ 5 (4 moderation + 1 tombstone)
--    8 constraint probes at the end all fail inside their savepoint
-- =====================================================================
\set ON_ERROR_STOP on

DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pawtrace.report) THEN RAISE EXCEPTION 'seed_demo: pawtrace.report is not empty — refusing to seed'; END IF;
END $$;

SELECT setseed(0.07);

-- ---------------------------------------------------------------------
-- 1. Regions (ids 1..4 by insertion)
-- ---------------------------------------------------------------------
INSERT INTO pawtrace.region (code, name, center) VALUES
    ('BKK', 'Bangkok',    ST_SetSRID(ST_MakePoint(100.5018, 13.7563), 4326)::geography),
    ('NON', 'Nonthaburi', ST_SetSRID(ST_MakePoint(100.5144, 13.8591), 4326)::geography),
    ('CNX', 'Chiang Mai', ST_SetSRID(ST_MakePoint( 98.9853, 18.7883), 4326)::geography),
    ('HKT', 'Phuket',     ST_SetSRID(ST_MakePoint( 98.3923,  7.8804), 4326)::geography);

-- ---------------------------------------------------------------------
-- 2. Users and devices
-- ---------------------------------------------------------------------
INSERT INTO pawtrace.app_user (id, email, display_name, role, locale, consent_version, shelter_name) VALUES
    ('aaaaaaaa-0000-7000-8000-000000000001', 'nok@example.th',     'Nok',          'user',      'th', 'terms-2026-08', NULL),
    ('aaaaaaaa-0000-7000-8000-000000000002', 'beam@example.th',    'Beam',         'user',      'th', 'terms-2026-08', NULL),
    ('aaaaaaaa-0000-7000-8000-000000000003', 'fah@example.th',     'Fah',          'user',      'th', 'terms-2026-08', NULL),
    ('aaaaaaaa-0000-7000-8000-000000000004', 'ken@example.com',    'Ken',          'user',      'en', 'terms-2026-08', NULL),
    ('aaaaaaaa-0000-7000-8000-000000000005', 'mint@example.th',    'Mint',         'user',      'th', 'terms-2026-08', NULL),
    ('aaaaaaaa-0000-7000-8000-000000000006', 'sara@example.com',   'Sara',         'user',      'en', 'terms-2026-08', NULL),
    ('aaaaaaaa-0000-7000-8000-000000000007', 'pond@example.th',    'Pond',         'user',      'th', 'terms-2026-08', NULL),   -- will request deletion
    ('aaaaaaaa-0000-7000-8000-000000000008', 'mod1@pawtrace.test', 'Moderator A',  'moderator', 'th', 'terms-2026-08', NULL),
    ('aaaaaaaa-0000-7000-8000-000000000009', 'mod2@pawtrace.test', 'Moderator B',  'moderator', 'en', 'terms-2026-08', NULL),
    ('aaaaaaaa-0000-7000-8000-000000000010', 'admin@pawtrace.test','Admin',        'admin',     'en', 'terms-2026-08', NULL),
    ('aaaaaaaa-0000-7000-8000-000000000011', 'sctp@example.th',    'Soi Dog Foundation (demo)', 'shelter', 'th', 'terms-2026-08', 'Soi Dog Foundation (demo)'),
    ('aaaaaaaa-0000-7000-8000-000000000012', 'bkkshelter@example.th', 'BKK City Shelter (demo)', 'shelter', 'th', 'terms-2026-08', 'BKK City Shelter (demo)');

INSERT INTO pawtrace.device (id, token_hash, first_ip, trust_score)
SELECT ('dddddddd-0000-7000-8000-' || lpad(to_hex(n), 12, '0'))::uuid,
       public.digest('demo-device-' || n, 'sha256'),
       ('10.0.' || (n % 8) || '.' || (10 + n))::inet,
       round((0.3 + random() * 0.6)::numeric, 2)
  FROM generate_series(1, 30) n;

-- ---------------------------------------------------------------------
-- 3. Models (ids by insertion: 1 detector, 2 embedding v1 ACTIVE, 3 embedding v2, 4 attributes, 5 nsfw, 6 text)
-- ---------------------------------------------------------------------
INSERT INTO pawtrace.model_version (kind, name, version, dims, checksum, search_active, calibration_provisional, benchmark_recall1, benchmark_recall10, activated_at) VALUES
    ('detector',   'yolo-dog',        '1.0', NULL, 'sha256:det1',  false, true,  NULL,  NULL,  NULL),
    ('embedding',  'dogreid-arcface', '1.0', 768,  'sha256:emb1',  true,  false, 0.480, 0.830, '2026-07-01 09:00+07'),
    ('embedding',  'dogreid-arcface', '2.0', 768,  'sha256:emb2',  false, true,  0.520, 0.860, NULL),
    ('attributes', 'coat-head',       '1.0', NULL, 'sha256:attr1', false, true,  NULL,  NULL,  NULL),
    ('nsfw',       'nsfw-screen',     '1.0', NULL, 'sha256:nsfw1', false, true,  NULL,  NULL,  NULL),
    ('text',       'multilingual-e5-large', '1.0', 1024, 'sha256:txt1', true, true, NULL, NULL, '2026-07-01 09:00+07');

-- AI-04: calibration curve for v1 (from ~1,800 historical decisions; the demo inserts the curve, not the history)
INSERT INTO pawtrace.calibration_bin (model_version_id, bin_low, bin_high, n, confirmed, precision) VALUES
    (2, 0.000, 0.100, 210,   2, 0.010), (2, 0.100, 0.200, 260,   8, 0.031), (2, 0.200, 0.300, 300,  18, 0.060),
    (2, 0.300, 0.400, 280,  34, 0.121), (2, 0.400, 0.500, 240,  50, 0.208), (2, 0.500, 0.600, 200,  70, 0.350),
    (2, 0.600, 0.700, 160,  83, 0.519), (2, 0.700, 0.800, 100,  68, 0.680), (2, 0.800, 0.900,  60,  49, 0.817),
    (2, 0.900, 1.001,  20,  18, 0.900);

INSERT INTO pawtrace.benchmark_run (model_version_id, dataset, n_queries, recall1, recall10, notes) VALUES
    (2, 'dogreid-holdout-2026q2', 1200, 0.480, 0.830, 'Filtered protocol: radius 5 km, 3 days (AI-03)'),
    (3, 'dogreid-holdout-2026q2', 1200, 0.520, 0.860, 'Candidate v2; re-embed in progress');
INSERT INTO pawtrace.benchmark_slice (run_id, slice_kind, slice_value, n, recall10, gap_pct) VALUES
    (1, 'color', 'black',  260, 0.690, 16.87), (1, 'color', 'white', 240, 0.850, -2.41), (1, 'color', 'brown', 330, 0.840, -1.20), (1, 'color', 'tan', 200, 0.820, 1.20),
    (1, 'size',  'small',  380, 0.800,  3.61), (1, 'size',  'medium', 520, 0.840, -1.20), (1, 'size', 'large', 300, 0.820, 1.20),
    (2, 'color', 'black',  260, 0.790,  8.14);

-- ---------------------------------------------------------------------
-- 4. 10,000 distractor sightings (anonymous devices), each with one approved photo, one crop, one v1 embedding
--    Deterministic ids: report 0000…-7000-8000-<n>, photo …-7001-…, instance …-7002-…
-- ---------------------------------------------------------------------
CREATE TEMP TABLE tmp_d AS
SELECT n,
       ('00000000-0000-7000-8000-' || lpad(to_hex(n), 12, '0'))::uuid AS report_id,
       ('00000000-0000-7001-8000-' || lpad(to_hex(n), 12, '0'))::uuid AS photo_id,
       ('00000000-0000-7002-8000-' || lpad(to_hex(n), 12, '0'))::uuid AS instance_id,
       CASE WHEN n % 10 < 5 THEN 1 WHEN n % 10 < 7 THEN 2 WHEN n % 10 < 9 THEN 3 ELSE 4 END::smallint AS region_id,
       (random() * 2 - 1) * 0.135 AS dlat,                                  -- ≈ ±15 km
       (random() * 2 - 1) * 0.135 AS dlng,
       timestamptz '2026-09-10 08:00+07' - (random() * 30) * interval '1 day' AS event_at,
       ('dddddddd-0000-7000-8000-' || lpad(to_hex(1 + (n % 30)), 12, '0'))::uuid AS device_id,
       (ARRAY['small','medium','medium','large','giant'])[1 + floor(random() * 5)]::pawtrace.size_class AS size_class,
       (ARRAY['black','white','brown','tan','golden','grey','cream','brindle'])[1 + floor(random() * 8)]::pawtrace.coat_color AS color_primary,
       (ARRAY['short','short','medium','long'])[1 + floor(random() * 4)]::pawtrace.coat_len AS coat_len,
       (ARRAY['mixed','mixed','mixed','terrier','hound','working','herding','sporting','unknown'])[1 + floor(random() * 9)]::pawtrace.breed_group AS breed_group
  FROM generate_series(1, 10000) n;

INSERT INTO pawtrace.report (id, kind, status, title, event_at, event_at_source, location, location_precision_m, location_source, region_id, device_id, expires_at, created_at)
SELECT d.report_id, CASE WHEN d.n % 7 = 0 THEN 'found' ELSE 'sighting' END::pawtrace.report_kind, 'active', 'Dog seen',
       d.event_at, 'now',
       ST_SetSRID(ST_MakePoint(ST_X(rg.center::geometry) + d.dlng, ST_Y(rg.center::geometry) + d.dlat), 4326)::geography,
       25, 'gps', d.region_id, d.device_id, d.event_at + interval '30 days', d.event_at + interval '5 minutes'
  FROM tmp_d d JOIN pawtrace.region rg ON rg.id = d.region_id;

INSERT INTO pawtrace.photo (id, report_id, sha256, uri_full, uri_card, uri_thumb, width, height, exif_stripped, moderation_status, processing_state, created_at)
SELECT d.photo_id, d.report_id, public.digest('photo-' || d.n, 'sha256'),
       'derivatives/' || d.photo_id || '/full.jpg', 'derivatives/' || d.photo_id || '/card.jpg', 'derivatives/' || d.photo_id || '/thumb.jpg',
       1600, 1200, true, 'pending', 'queued', d.event_at + interval '5 minutes'
  FROM tmp_d d;
UPDATE pawtrace.photo SET processing_state = 'done';                    -- worker finished
UPDATE pawtrace.photo SET moderation_status = 'approved';               -- auto-approved by the NSFW screen (gate passes: stripped + done)

INSERT INTO pawtrace.dog_instance (id, photo_id, detector_version_id, bbox_json, crop_uri, quality_score, short_edge_px, det_confidence)
SELECT d.instance_id, d.photo_id, 1, '{"x": 200, "y": 150, "w": 900, "h": 800}', 'crops/' || d.instance_id || '.jpg',
       round((0.55 + random() * 0.45)::numeric, 3), 800, round((0.7 + random() * 0.3)::numeric, 3)
  FROM tmp_d d;

-- random unit vectors, one per instance (the LATERAL is correlated on d.n so it is evaluated per row)
INSERT INTO pawtrace.embedding (instance_id, model_version_id, vec)
SELECT d.instance_id, 2, l2_normalize(v.arr::vector)
  FROM tmp_d d
  JOIN LATERAL (SELECT array_agg(random() * 2 - 1) AS arr FROM generate_series(1, 768) g WHERE d.n IS NOT NULL) v ON true;

INSERT INTO pawtrace.report_embedding (report_id, model_version_id, vec, medoid_instance, n_instances)
SELECT d.report_id, 2, e.vec, d.instance_id, 1 FROM tmp_d d JOIN pawtrace.embedding e ON e.instance_id = d.instance_id AND e.model_version_id = 2;

INSERT INTO pawtrace.attributes (instance_id, model_version_id, size_class, color_primary, coat_len, breed_group, has_markings, confidence_json)
SELECT d.instance_id, 4, d.size_class, d.color_primary, d.coat_len, d.breed_group, d.n % 3 = 0,
       jsonb_build_object('size_class', 0.8, 'color_primary', 0.85, 'coat_len', 0.7, 'breed_group', 0.5)
  FROM tmp_d d;
INSERT INTO pawtrace.report_attr (report_id, size_class, color_primary, coat_len, breed_group, has_markings)
SELECT d.report_id, d.size_class, d.color_primary, d.coat_len, d.breed_group, d.n % 3 = 0 FROM tmp_d d;

-- ---------------------------------------------------------------------
-- 5. 20 planted pairs (owners u1..u6 round-robin) — exact cosine c_i between the lost and found vectors
--    found = normalise(c·b + sqrt(1−c²)·u), u ⟂ b   (so cosine(lost, found) = c exactly, up to float rounding)
-- ---------------------------------------------------------------------
DO $$
DECLARE i int; k int; b float8[]; nn float8[]; u float8[]; f float8[]; dot float8; nrm float8; c float8;
        owner uuid; lost_id uuid; found_id uuid; ph uuid; inst uuid; ch uuid;
        rg smallint; lat float8; lng float8; lost_at timestamptz; seen_at timestamptz; dl float8; dg float8;
        sz pawtrace.size_class; col pawtrace.coat_color; cl pawtrace.coat_len; bg pawtrace.breed_group;
BEGIN
    FOR i IN 1..20 LOOP
        owner := ('aaaaaaaa-0000-7000-8000-' || lpad(to_hex(1 + ((i - 1) % 6)), 12, '0'))::uuid;
        lost_id  := ('11111111-0000-7000-8000-' || lpad(to_hex(i), 12, '0'))::uuid;
        found_id := ('22222222-0000-7000-8000-' || lpad(to_hex(i), 12, '0'))::uuid;
        rg := CASE WHEN i <= 12 THEN 1 WHEN i <= 17 THEN 3 ELSE 4 END;
        SELECT ST_Y(center::geometry), ST_X(center::geometry) INTO lat, lng FROM pawtrace.region WHERE id = rg;
        IF i = 1 THEN                                                    -- Appendix A: Nok's dog
            lat := 13.7563; lng := 100.5018; lost_at := '2026-09-08 20:30+07'; seen_at := '2026-09-10 07:15+07';
            dl := 0; dg := 0.019425;                                     -- 0.019425° of longitude at 13.76° N ≈ 2,100 m
            c := 0.83; sz := 'medium'; col := 'brown'; cl := 'short'; bg := 'mixed';
        ELSE
            lat := lat + (random() * 2 - 1) * 0.08; lng := lng + (random() * 2 - 1) * 0.08;
            lost_at := timestamptz '2026-09-10 08:00+07' - (1 + random() * 25) * interval '1 day';
            seen_at := lost_at + (6 + random() * 54) * interval '1 hour';                       -- 6–60 h later (window 72 h)
            dl := (random() * 2 - 1) * 0.02; dg := (random() * 2 - 1) * 0.02;                  -- within ≈ 3 km
            c := 0.78 + random() * 0.12;
            sz := (ARRAY['small','medium','large'])[1 + floor(random() * 3)]::pawtrace.size_class;
            col := (ARRAY['black','white','brown','tan','golden'])[1 + floor(random() * 5)]::pawtrace.coat_color;
            cl := (ARRAY['short','medium','long'])[1 + floor(random() * 3)]::pawtrace.coat_len;
            bg := 'mixed';
        END IF;
        -- base unit vector b and an orthogonal unit vector u
        SELECT array_agg(random() * 2 - 1) INTO b FROM generate_series(1, 768);
        nrm := sqrt((SELECT sum(x * x) FROM unnest(b) x)); b := (SELECT array_agg(x / nrm) FROM unnest(b) x);
        SELECT array_agg(random() * 2 - 1) INTO nn FROM generate_series(1, 768);
        dot := (SELECT sum(x * y) FROM unnest(b, nn) AS t(x, y));
        u := (SELECT array_agg(y - dot * x) FROM unnest(b, nn) AS t(x, y));
        nrm := sqrt((SELECT sum(x * x) FROM unnest(u) x)); u := (SELECT array_agg(x / nrm) FROM unnest(u) x);
        f := (SELECT array_agg(c * x + sqrt(1 - c * c) * y) FROM unnest(b, u) AS t(x, y));

        -- lost report (needs an account and a contact channel)
        ch := public.uuid_generate_v7();
        INSERT INTO pawtrace.contact_channel (id, kind, user_id) VALUES (ch, 'relay_thread', owner);
        INSERT INTO pawtrace.report (id, kind, status, title, description, event_at, event_at_source, location, location_precision_m, location_source,
                                     region_id, contact_channel_id, user_id, expires_at, created_at)
        VALUES (lost_id, 'lost', 'active', CASE WHEN i = 1 THEN 'Lost: Latte, brown short-haired medium dog with white chest' ELSE 'Lost dog #' || i END,
                CASE WHEN i = 1 THEN 'Medium brown short-haired dog, white chest patch, red collar, answers to Latte. Lost near Lumphini park.' ELSE 'Planted pair ' || i END,
                lost_at, 'user', ST_SetSRID(ST_MakePoint(lng, lat), 4326)::geography, 15, 'pin', rg, ch, owner, lost_at + interval '30 days', lost_at + interval '40 minutes');
        ph := ('11111111-0000-7001-8000-' || lpad(to_hex(i), 12, '0'))::uuid;
        inst := ('11111111-0000-7002-8000-' || lpad(to_hex(i), 12, '0'))::uuid;
        INSERT INTO pawtrace.photo (id, report_id, sha256, uri_full, uri_card, uri_thumb, width, height, exif_stripped, processing_state, created_at)
        VALUES (ph, lost_id, public.digest('lost-photo-' || i, 'sha256'), 'derivatives/' || ph || '/full.jpg', 'derivatives/' || ph || '/card.jpg', 'derivatives/' || ph || '/thumb.jpg', 2048, 1536, true, 'done', lost_at + interval '41 minutes');
        UPDATE pawtrace.photo SET moderation_status = 'approved' WHERE id = ph;
        INSERT INTO pawtrace.dog_instance (id, photo_id, detector_version_id, bbox_json, crop_uri, quality_score, short_edge_px, det_confidence)
        VALUES (inst, ph, 1, '{"x": 300, "y": 200, "w": 1100, "h": 1000}', 'crops/' || inst || '.jpg', CASE WHEN i = 1 THEN 0.91 ELSE 0.8 END, 1000, 0.97);
        INSERT INTO pawtrace.embedding (instance_id, model_version_id, vec) VALUES (inst, 2, b::vector);
        INSERT INTO pawtrace.report_embedding (report_id, model_version_id, vec, medoid_instance, n_instances) VALUES (lost_id, 2, b::vector, inst, 1);
        INSERT INTO pawtrace.attributes (instance_id, model_version_id, size_class, color_primary, color_secondary, coat_len, breed_group, has_markings, confidence_json)
        VALUES (inst, 4, sz, col, CASE WHEN i = 1 THEN 'white' END, cl, bg, i = 1, '{"size_class": 0.9, "color_primary": 0.9, "coat_len": 0.8, "breed_group": 0.6}');
        INSERT INTO pawtrace.report_attr (report_id, size_class, color_primary, color_secondary, coat_len, breed_group, has_markings, user_declared)
        VALUES (lost_id, sz, col, CASE WHEN i = 1 THEN 'white' END, cl, bg, i = 1, true);
        INSERT INTO pawtrace.text_embedding (report_id, model_version_id, vec, source_text)
        SELECT lost_id, 6, l2_normalize((SELECT array_agg(random() * 2 - 1) FROM generate_series(1, 1024))::vector), 'lost ' || sz || ' ' || col || ' ' || cl;

        -- found / sighting (anonymous device for even i, a user for odd i > 1)
        INSERT INTO pawtrace.report (id, kind, status, title, event_at, event_at_source, location, location_precision_m, location_source, region_id,
                                     user_id, device_id, expires_at, created_at)
        VALUES (found_id, 'sighting', 'active', 'Dog seen', seen_at, CASE WHEN i = 1 THEN 'exif' ELSE 'now' END,
                ST_SetSRID(ST_MakePoint(lng + dg, lat + dl), 4326)::geography, 25, 'gps', rg,
                CASE WHEN i > 1 AND i % 2 = 1 THEN ('aaaaaaaa-0000-7000-8000-' || lpad(to_hex(1 + (i % 6)), 12, '0'))::uuid END,
                CASE WHEN i = 1 OR i % 2 = 0 THEN ('dddddddd-0000-7000-8000-' || lpad(to_hex(1 + (i % 30)), 12, '0'))::uuid END,
                seen_at + interval '30 days', seen_at + interval '3 minutes');
        ph := ('22222222-0000-7001-8000-' || lpad(to_hex(i), 12, '0'))::uuid;
        inst := ('22222222-0000-7002-8000-' || lpad(to_hex(i), 12, '0'))::uuid;
        INSERT INTO pawtrace.photo (id, report_id, sha256, uri_full, uri_card, uri_thumb, width, height, exif_stripped, capture_time_exif, processing_state, created_at)
        VALUES (ph, found_id, public.digest('found-photo-' || i, 'sha256'), 'derivatives/' || ph || '/full.jpg', 'derivatives/' || ph || '/card.jpg', 'derivatives/' || ph || '/thumb.jpg', 1600, 1200, true, CASE WHEN i = 1 THEN seen_at END, 'done', seen_at + interval '3 minutes');
        UPDATE pawtrace.photo SET moderation_status = 'approved' WHERE id = ph;
        INSERT INTO pawtrace.dog_instance (id, photo_id, detector_version_id, bbox_json, crop_uri, quality_score, short_edge_px, det_confidence)
        VALUES (inst, ph, 1, '{"x": 100, "y": 120, "w": 700, "h": 650}', 'crops/' || inst || '.jpg', CASE WHEN i = 1 THEN 0.77 ELSE 0.75 END, 650, 0.93);
        INSERT INTO pawtrace.embedding (instance_id, model_version_id, vec) VALUES (inst, 2, f::vector);
        INSERT INTO pawtrace.report_embedding (report_id, model_version_id, vec, medoid_instance, n_instances) VALUES (found_id, 2, f::vector, inst, 1);
        INSERT INTO pawtrace.attributes (instance_id, model_version_id, size_class, color_primary, color_secondary, coat_len, breed_group, has_markings, confidence_json)
        VALUES (inst, 4, sz, col, CASE WHEN i = 1 THEN 'white' END, cl, bg, i = 1, '{"size_class": 0.8, "color_primary": 0.85, "coat_len": 0.7, "breed_group": 0.5}');
        INSERT INTO pawtrace.report_attr (report_id, size_class, color_primary, color_secondary, coat_len, breed_group, has_markings)
        VALUES (found_id, sz, col, CASE WHEN i = 1 THEN 'white' END, cl, bg, i = 1);
        INSERT INTO pawtrace.text_embedding (report_id, model_version_id, vec, source_text)
        SELECT found_id, 6, l2_normalize((SELECT array_agg(random() * 2 - 1) FROM generate_series(1, 1024))::vector), 'sighting ' || sz || ' ' || col || ' ' || cl;
    END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- 6. u7's own lost report (to be deleted in §12)
-- ---------------------------------------------------------------------
INSERT INTO pawtrace.contact_channel (id, kind, user_id) VALUES ('cccccccc-0000-7000-8000-000000000007', 'relay_thread', 'aaaaaaaa-0000-7000-8000-000000000007');
INSERT INTO pawtrace.report (id, kind, status, title, event_at, location, location_precision_m, location_source, region_id, contact_channel_id, user_id, expires_at)
VALUES ('77777777-0000-7000-8000-000000000001', 'lost', 'active', 'Lost: Mochi', '2026-09-09 18:00+07',
        ST_SetSRID(ST_MakePoint(100.53, 13.74), 4326)::geography, 15, 'pin', 1, 'cccccccc-0000-7000-8000-000000000007', 'aaaaaaaa-0000-7000-8000-000000000007', '2026-10-09 18:00+07');
INSERT INTO pawtrace.photo (id, report_id, sha256, uri_full, uri_card, uri_thumb, width, height, exif_stripped, processing_state)
VALUES ('77777777-0000-7001-8000-000000000001', '77777777-0000-7000-8000-000000000001', public.digest('mochi', 'sha256'), 'derivatives/m/full.jpg', 'derivatives/m/card.jpg', 'derivatives/m/thumb.jpg', 1200, 1600, true, 'done');
UPDATE pawtrace.photo SET moderation_status = 'approved' WHERE id = '77777777-0000-7001-8000-000000000001';
INSERT INTO pawtrace.dog_instance (id, photo_id, detector_version_id, bbox_json, crop_uri, quality_score, short_edge_px, det_confidence)
VALUES ('77777777-0000-7002-8000-000000000001', '77777777-0000-7001-8000-000000000001', 1, '{"x": 0, "y": 0, "w": 600, "h": 600}', 'crops/m.jpg', 0.8, 600, 0.9);
INSERT INTO pawtrace.embedding (instance_id, model_version_id, vec)
SELECT '77777777-0000-7002-8000-000000000001', 2, l2_normalize((SELECT array_agg(random() * 2 - 1) FROM generate_series(1, 768))::vector);
INSERT INTO pawtrace.report_embedding (report_id, model_version_id, vec, medoid_instance, n_instances)
SELECT '77777777-0000-7000-8000-000000000001', 2, vec, '77777777-0000-7002-8000-000000000001', 1 FROM pawtrace.embedding WHERE instance_id = '77777777-0000-7002-8000-000000000001';

-- ---------------------------------------------------------------------
-- 7. AC-08: v2 re-embed in progress — 62 % of the 10,041 instances have a v2 vector; v1 remains the only search_active version
-- ---------------------------------------------------------------------
INSERT INTO pawtrace.embedding (instance_id, model_version_id, vec)
SELECT di.id, 3, l2_normalize(v.arr::vector)
  FROM (SELECT id FROM pawtrace.dog_instance ORDER BY created_at, id LIMIT 6225) di
  JOIN LATERAL (SELECT array_agg(random() * 2 - 1) AS arr FROM generate_series(1, 768) g WHERE di.id IS NOT NULL) v ON true;
INSERT INTO pawtrace.reembed_job (from_version_id, to_version_id, total, done, state, started_at) VALUES (2, 3, 10041, 6225, 'running', '2026-09-09 02:00+07');

-- ---------------------------------------------------------------------
-- 8. Matching — through the real functions (FR-14/15, AC-02). Top 10 per lost report.
-- ---------------------------------------------------------------------
INSERT INTO pawtrace.match (lost_report_id, found_report_id, model_version_id, score, calibrated_precision, components_json, rank, created_at)
SELECT lost_report_id, found_report_id, 2, score, pawtrace.calibrated_precision(score, 2), components, rk, now()
  FROM (
    SELECT l.id AS lost_report_id, c.found_report_id, s.score,
           jsonb_build_object('cosine', c.cosine, 'sim_visual', pawtrace.sim_visual(c.cosine), 'attr_compat', COALESCE(c.attr_compat, 0.7),
                              'spatial', c.spatial, 'temporal', c.temporal, 'distance_m', round(c.distance_m::numeric, 1), 'hours_after', c.hours_after,
                              'penalty', CASE WHEN COALESCE(c.min_quality, 1) < 0.5 THEN 0.05 ELSE 0 END) AS components,
           row_number() OVER (PARTITION BY l.id ORDER BY s.score DESC, c.cosine DESC) AS rk
      FROM pawtrace.report l
      CROSS JOIN LATERAL pawtrace.search_candidates(l.id) c
      CROSS JOIN LATERAL (SELECT pawtrace.fusion_score(pawtrace.sim_visual(c.cosine), COALESCE(c.attr_compat, 0.7), c.spatial, c.temporal, COALESCE(c.min_quality, 1)) AS score) s
     WHERE l.kind = 'lost' AND l.status = 'active'
  ) ranked
 WHERE rk <= 10;

-- ---------------------------------------------------------------------
-- 9. Notifications (FR-22, FR-25): rank ≤ 5 and calibrated ≥ threshold → push; u1 owns pairs 1, 7, 13, 19 (4 candidate alerts) + 3 area alerts → 7 in a day → 2 become digest
-- ---------------------------------------------------------------------
INSERT INTO pawtrace.notification (user_id, kind, channel, entity, entity_id, payload)
SELECT l.user_id, 'candidate', 'push', 'report', m.lost_report_id,
       jsonb_build_object('match_id', m.id, 'calibrated_precision', m.calibrated_precision, 'rank', m.rank, 'cell', pawtrace.fuzz_cell(f.location, 'subscriber', f.region_id))
  FROM pawtrace.match m JOIN pawtrace.report l ON l.id = m.lost_report_id JOIN pawtrace.report f ON f.id = m.found_report_id JOIN pawtrace.region rg ON rg.id = l.region_id
 WHERE m.rank <= rg.notify_rank_max AND m.calibrated_precision >= rg.notify_threshold
 ORDER BY l.user_id, m.created_at;
UPDATE pawtrace.match m SET notified_at = now()
 WHERE EXISTS (SELECT 1 FROM pawtrace.notification n WHERE (n.payload->>'match_id')::uuid = m.id);
INSERT INTO pawtrace.notification (user_id, kind, channel, entity, entity_id, payload)
SELECT 'aaaaaaaa-0000-7000-8000-000000000001', 'new_report_in_area', 'push', 'report', r.id, jsonb_build_object('cell', pawtrace.fuzz_cell(r.location, 'subscriber', r.region_id))
  FROM pawtrace.report r WHERE r.kind = 'sighting' AND r.region_id = 1 AND r.device_id IS NOT NULL ORDER BY r.created_at DESC LIMIT 3;

-- ---------------------------------------------------------------------
-- 10. Decisions (FR-19, AI-07) → threads → reunions (FR-20)
-- ---------------------------------------------------------------------
DO $$
DECLARE i int; lost_id uuid; found_id uuid; owner uuid; mid uuid;
BEGIN
    FOR i IN 2..15 LOOP
        lost_id  := ('11111111-0000-7000-8000-' || lpad(to_hex(i), 12, '0'))::uuid;
        found_id := ('22222222-0000-7000-8000-' || lpad(to_hex(i), 12, '0'))::uuid;
        SELECT user_id INTO owner FROM pawtrace.report WHERE id = lost_id;
        -- reject the rank-2 candidate first (where a distractor qualified), i ≤ 13
        IF i <= 13 THEN
            SELECT id INTO mid FROM pawtrace.match WHERE lost_report_id = lost_id AND rank = 2 AND found_report_id <> found_id;
            IF FOUND THEN
                INSERT INTO pawtrace.match_decision (match_id, decision, decided_by, consent_version, note) VALUES (mid, 'reject', owner, 'terms-2026-08', 'different dog');
            END IF;
        END IF;
        -- confirm the planted pair
        SELECT id INTO mid FROM pawtrace.match WHERE lost_report_id = lost_id AND found_report_id = found_id;
        IF NOT FOUND THEN RAISE EXCEPTION 'seed: planted pair % not among candidates', i; END IF;
        INSERT INTO pawtrace.match_decision (match_id, decision, decided_by, consent_version, note) VALUES (mid, 'confirm', owner, 'terms-2026-08', 'that is my dog');
        IF i <= 4 THEN
            UPDATE pawtrace.thread SET lost_side_consent_exact = true, found_side_consent_exact = (i = 2) WHERE match_id = mid;
            INSERT INTO pawtrace.reunion (lost_report_id, found_report_id, match_id, confirmed_by, story, story_public)
            VALUES (lost_id, found_id, mid, owner, CASE WHEN i = 2 THEN 'Found two streets away thanks to a neighbour''s sighting.' END, i = 2);
        END IF;
    END LOOP;
    -- messages in pair #5's thread
    SELECT t.id INTO mid FROM pawtrace.thread t JOIN pawtrace.match m ON m.id = t.match_id WHERE m.lost_report_id = '11111111-0000-7000-8000-000000000005';
    INSERT INTO pawtrace.message (thread_id, sender, user_id, body) VALUES
        (mid, 'lost_side',  'aaaaaaaa-0000-7000-8000-000000000005', 'Hi — that looks like Bo. Is he still there?'),
        (mid, 'found_side', 'aaaaaaaa-0000-7000-8000-000000000006', 'Yes, near the temple. He is friendly but scared.'),
        (mid, 'lost_side',  'aaaaaaaa-0000-7000-8000-000000000005', 'I can be there in 20 minutes. Can you share the exact spot?'),
        (mid, 'system',     NULL, 'Both sides must consent before exact locations are shared.');
END $$;

-- ---------------------------------------------------------------------
-- 11. Subscriptions, push, moderation, abuse, duplicates, config, rate limits
-- ---------------------------------------------------------------------
INSERT INTO pawtrace.subscription (user_id, area, filters_json) VALUES
    ('aaaaaaaa-0000-7000-8000-000000000001', ST_SetSRID(ST_MakeEnvelope(100.45, 13.70, 100.56, 13.80), 4326)::geography, '{"kind": ["found", "sighting"]}'),
    ('aaaaaaaa-0000-7000-8000-000000000004', ST_SetSRID(ST_MakeEnvelope( 98.93, 18.75,  99.03, 18.83), 4326)::geography, '{"color_primary": ["black"]}'),
    ('aaaaaaaa-0000-7000-8000-000000000011', ST_SetSRID(ST_MakeEnvelope( 98.30,  7.80,  98.45,  7.95), 4326)::geography, '{}');
INSERT INTO pawtrace.push_subscription (user_id, device_id, provider, endpoint, keys_json) VALUES
    ('aaaaaaaa-0000-7000-8000-000000000001', NULL, 'webpush', 'https://push.example/ep/nok',  '{"p256dh": "demo", "auth": "demo"}'),
    ('aaaaaaaa-0000-7000-8000-000000000002', NULL, 'fcm',     'fcm:token:beam',                NULL),
    ('aaaaaaaa-0000-7000-8000-000000000005', NULL, 'webpush', 'https://push.example/ep/mint', '{"p256dh": "demo", "auth": "demo"}'),
    (NULL, 'dddddddd-0000-7000-8000-000000000003', 'webpush', 'https://push.example/ep/dev3', '{"p256dh": "demo", "auth": "demo"}');

-- moderation: two photos hidden by a moderator, one NSFW auto-hide, one device banned
UPDATE pawtrace.photo SET moderation_status = 'hidden', moderation_reason = 'not a dog (cat)' WHERE id = '00000000-0000-7001-8000-000000000011';
UPDATE pawtrace.photo SET moderation_status = 'hidden', moderation_reason = 'abusive overlay text' WHERE id = '00000000-0000-7001-8000-000000000012';
UPDATE pawtrace.photo SET moderation_status = 'hidden', moderation_reason = 'NSFW score 0.97', processing_error = 'NSFW' WHERE id = '00000000-0000-7001-8000-000000000013';
INSERT INTO pawtrace.moderation_event (entity, entity_id, action, moderator_id, reason) VALUES
    ('photo',  '00000000-0000-7001-8000-000000000011', 'hide', 'aaaaaaaa-0000-7000-8000-000000000008', 'not a dog (cat)'),
    ('photo',  '00000000-0000-7001-8000-000000000012', 'hide', 'aaaaaaaa-0000-7000-8000-000000000009', 'abusive overlay text'),
    ('photo',  '00000000-0000-7001-8000-000000000013', 'nsfw_auto_hide', NULL, 'NSFW score 0.97 ≥ 0.90'),
    ('device', 'dddddddd-0000-7000-8000-000000000029', 'ban_device', 'aaaaaaaa-0000-7000-8000-000000000008', '14 duplicate sightings in 10 minutes');
UPDATE pawtrace.device SET banned_at = now(), ban_reason = '14 duplicate sightings in 10 minutes', trust_score = 0 WHERE id = 'dddddddd-0000-7000-8000-000000000029';

INSERT INTO pawtrace.abuse_report (entity, entity_id, reporter_user_id, reporter_device_id, reason, detail, resolved_at, resolution, resolved_by) VALUES
    ('photo',  '00000000-0000-7001-8000-000000000011', 'aaaaaaaa-0000-7000-8000-000000000002', NULL, 'not_a_dog', 'this is a cat', now(), 'hidden', 'aaaaaaaa-0000-7000-8000-000000000008'),
    ('report', '00000000-0000-7000-8000-000000000021', NULL, 'dddddddd-0000-7000-8000-000000000005', 'fake', 'same photo posted from 3 places', NULL, NULL, NULL),
    ('report', '00000000-0000-7000-8000-000000000022', 'aaaaaaaa-0000-7000-8000-000000000003', NULL, 'spam', NULL, NULL, NULL, NULL);

INSERT INTO pawtrace.duplicate_cluster (primary_report_id, member_report_ids, cosine, distance_m, hours_apart)
VALUES ('00000000-0000-7000-8000-000000000021', ARRAY['00000000-0000-7000-8000-000000000022'::uuid], 0.960, 180, 0.4);

INSERT INTO pawtrace.config_version (version, loaded_by, doc)
VALUES ('2026-09-01', 'aaaaaaaa-0000-7000-8000-000000000010', '{"fusion": {"weights": {"visual": 0.55, "attr": 0.15, "spatial": 0.20, "temporal": 0.10}}, "notify": {"threshold": 0.25, "rank_max": 5, "daily_cap": 5}}');

INSERT INTO pawtrace.rate_limit_bucket (key, window_start, count) VALUES
    ('device:dddddddd-0000-7000-8000-000000000029:post', date_trunc('hour', now()), 14),
    ('ip:10.0.5.39:post', date_trunc('hour', now()), 14),
    ('device:dddddddd-0000-7000-8000-000000000003:post', date_trunc('hour', now()), 2);

-- ---------------------------------------------------------------------
-- 12. AC-06: u7 asks for deletion — the cascade trigger runs inside the insert
-- ---------------------------------------------------------------------
INSERT INTO pawtrace.deletion_request (id, user_id) VALUES ('eeeeeeee-0000-7000-8000-000000000001', 'aaaaaaaa-0000-7000-8000-000000000007');

DROP TABLE tmp_d;

-- =====================================================================
-- 13. VERIFICATION  (compare with the header)
-- =====================================================================
\echo '--- reports by kind/status'
SELECT kind, status, count(*) FROM pawtrace.report GROUP BY 1, 2 ORDER BY 1, 2;
\echo '--- photos / instances / embeddings v1 / v2 / text'
SELECT (SELECT count(*) FROM pawtrace.photo) photos, (SELECT count(*) FROM pawtrace.dog_instance) instances,
       (SELECT count(*) FROM pawtrace.embedding WHERE model_version_id = 2) emb_v1, (SELECT count(*) FROM pawtrace.embedding WHERE model_version_id = 3) emb_v2,
       (SELECT count(*) FROM pawtrace.text_embedding) text_emb;
\echo '--- AC-02: planted pairs in top 10 (expect 20 of 20; AC-02 needs >= 16) and rank distribution'
SELECT count(*) FILTER (WHERE m.rank <= 10) AS in_top10, count(*) FILTER (WHERE m.rank = 1) AS rank1, count(*) AS pairs
  FROM generate_series(1, 20) i
  LEFT JOIN pawtrace.match m ON m.lost_report_id = ('11111111-0000-7000-8000-' || lpad(to_hex(i), 12, '0'))::uuid
                            AND m.found_report_id = ('22222222-0000-7000-8000-' || lpad(to_hex(i), 12, '0'))::uuid;
\echo '--- Appendix A (pair #1): expect cosine 0.830, sim 0.80, attr 1.0, distance ~2100.8, spatial ~0.4965, temporal 0.8432, score ~0.7736, precision 0.680, rank 1, notified'
SELECT m.rank, m.score, m.calibrated_precision, m.components_json, m.notified_at IS NOT NULL AS notified, m.status
  FROM pawtrace.match m WHERE m.lost_report_id = '11111111-0000-7000-8000-000000000001' AND m.found_report_id = '22222222-0000-7000-8000-000000000001';
\echo '--- one vector space per query: active embedding version = 2 (v1)'
SELECT pawtrace.active_embedding_version() AS active_version, (SELECT count(*) FROM pawtrace.model_version WHERE kind = 'embedding' AND search_active) AS n_active;
SELECT * FROM pawtrace.v_model_status ORDER BY id;
\echo '--- decisions (<= 26: 14 confirm + <= 12 reject), reunions 3, threads 14, messages 4'
SELECT (SELECT count(*) FROM pawtrace.match_decision WHERE decision = 'confirm') confirms, (SELECT count(*) FROM pawtrace.match_decision WHERE decision = 'reject') rejects,
       (SELECT count(*) FROM pawtrace.reunion) reunions, (SELECT count(*) FROM pawtrace.thread) threads, (SELECT count(*) FROM pawtrace.message) messages;
SELECT status, count(*) FROM pawtrace.match GROUP BY 1 ORDER BY 1;
\echo '--- FR-25: Nok (u1) 7 notifications -> 5 sent-channel + 2 digest; can_notify false'
SELECT channel, count(*) FROM pawtrace.notification WHERE user_id = 'aaaaaaaa-0000-7000-8000-000000000001' GROUP BY 1 ORDER BY 1;
SELECT sent_today, digested_today, can_notify FROM pawtrace.v_notify_budget WHERE user_id = 'aaaaaaaa-0000-7000-8000-000000000001';
\echo '--- C-01: public shapes carry cells only (expect 5-char cells; no lat/lng column in report_public)'
SELECT cell, length(cell) AS chars, kind, event_hour FROM pawtrace.report_public WHERE id = '22222222-0000-7000-8000-000000000001';
SELECT count(*) AS cells, sum(n) AS reports_on_map FROM pawtrace.v_map_cells;
\echo '--- AI-08 bias report (black: rebalance_required true)'
SELECT slice_kind, slice_value, recall10, gap_pct, rebalance_required FROM pawtrace.v_bias_report WHERE model LIKE '%1.0' ORDER BY slice_kind, slice_value;
\echo '--- AC-06 deletion: db_done, summary {1,1,1}; u7 anonymised; tombstone in audit'
SELECT state, summary_json, sla_breached FROM pawtrace.v_deletion_status;
SELECT email, display_name, deleted_at IS NOT NULL AS deleted FROM pawtrace.app_user WHERE id = 'aaaaaaaa-0000-7000-8000-000000000007';
SELECT actor, action, entity, after_json FROM audit.log WHERE actor = 'deletion_request';
\echo '--- moderation queue / abuse / duplicates / audit'
SELECT item, count(*) FROM pawtrace.v_moderation_queue GROUP BY 1 ORDER BY 1;
SELECT (SELECT count(*) FROM pawtrace.moderation_event) mod_events, (SELECT count(*) FROM pawtrace.abuse_report WHERE resolved_at IS NULL) open_abuse,
       (SELECT count(*) FROM pawtrace.duplicate_cluster WHERE merged_at IS NULL) open_dups, (SELECT count(*) FROM audit.log) audit_rows;

-- =====================================================================
-- 14. CONSTRAINT PROBES — each must FAIL (TEST-07 TC-003). Run inside a transaction with savepoints.
-- =====================================================================
\set ON_ERROR_STOP off
BEGIN;
\echo '--- probe 1: match inserted as confirmed (C-03) — expect MATCH_NOT_CANDIDATE'
SAVEPOINT p1;
INSERT INTO pawtrace.match (lost_report_id, found_report_id, model_version_id, score, calibrated_precision, components_json, rank, status)
VALUES ('11111111-0000-7000-8000-000000000001', '00000000-0000-7000-8000-000000000001', 2, 0.5, 0.3, '{"cosine":0.5,"sim_visual":0.3,"attr_compat":0.7,"spatial":0.5,"temporal":1,"distance_m":100,"hours_after":2}', 3, 'confirmed');
ROLLBACK TO SAVEPOINT p1;
\echo '--- probe 2: match set to confirmed without a decision (FR-19) — expect MATCH_NEEDS_DECISION'
SAVEPOINT p2;
UPDATE pawtrace.match SET status = 'confirmed' WHERE lost_report_id = '11111111-0000-7000-8000-000000000001' AND rank = 1;
ROLLBACK TO SAVEPOINT p2;
\echo '--- probe 3: editing a decision (AI-07) — expect DECISION_IMMUTABLE'
SAVEPOINT p3;
UPDATE pawtrace.match_decision SET decision = 'reject' WHERE id = (SELECT min(id) FROM pawtrace.match_decision);
ROLLBACK TO SAVEPOINT p3;
\echo '--- probe 4: approving an unprocessed photo (C-05) — expect PHOTO_NOT_PROCESSED'
SAVEPOINT p4;
INSERT INTO pawtrace.photo (report_id, sha256, uri_full, uri_card, uri_thumb, width, height, exif_stripped, moderation_status, processing_state, position)
VALUES ('11111111-0000-7000-8000-000000000001', public.digest('probe4', 'sha256'), 'x', 'x', 'x', 100, 100, true, 'approved', 'queued', 2);
ROLLBACK TO SAVEPOINT p4;
\echo '--- probe 5: a photo row with EXIF not stripped (C-04) — expect CHECK stripped_before_store'
SAVEPOINT p5;
INSERT INTO pawtrace.photo (report_id, sha256, uri_full, uri_card, uri_thumb, width, height, exif_stripped, position)
VALUES ('11111111-0000-7000-8000-000000000001', public.digest('probe5', 'sha256'), 'x', 'x', 'x', 100, 100, false, 2);
ROLLBACK TO SAVEPOINT p5;
\echo '--- probe 6: activating v2 before its re-embed completes (AC-08) — expect REEMBED_INCOMPLETE'
SAVEPOINT p6;
UPDATE pawtrace.model_version SET search_active = true WHERE id = 3;
ROLLBACK TO SAVEPOINT p6;
\echo '--- probe 7: a notification payload with coordinates (C-01) — expect NOTIFICATION_LEAK'
SAVEPOINT p7;
INSERT INTO pawtrace.notification (user_id, kind, channel, payload) VALUES ('aaaaaaaa-0000-7000-8000-000000000002', 'message', 'push', '{"lat": 13.75, "lng": 100.5}');
ROLLBACK TO SAVEPOINT p7;
\echo '--- probe 8: a banned device posting (FR-28) — expect DEVICE_BANNED'
SAVEPOINT p8;
INSERT INTO pawtrace.report (kind, event_at, location, location_source, region_id, device_id, expires_at)
VALUES ('sighting', now(), ST_SetSRID(ST_MakePoint(100.5, 13.75), 4326)::geography, 'gps', 1, 'dddddddd-0000-7000-8000-000000000029', now() + interval '30 days');
ROLLBACK TO SAVEPOINT p8;
COMMIT;
\echo '--- seed complete'
