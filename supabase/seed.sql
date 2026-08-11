-- SEED DATA: Run this AFTER migration_paper_ballots.sql
-- Note: ALTER SYSTEM must be run separately (not in transaction)

-- 1. FIRST: Run this separately in SQL Editor (outside transaction):
-- ALTER SYSTEM SET app.ballot_hmac_key = 'test-hmac-key-32-chars-minimum!!';
-- SELECT pg_reload_conf();

-- 2. THEN run the rest below:

UPDATE election_settings SET current_phase = 'VOTING', voting_start = NOW() WHERE id = 1;

TRUNCATE candidates, tokens, anonymous_nominations, ballots, paper_ballots CASCADE;
DELETE FROM members;

INSERT INTO candidates (id, full_name, statement, photo_url, is_active)
VALUES
  ('11111111-1111-1111-1111-111111111111', 'Dr. Eleanor Vance', 'Focusing on community sustainability, green spaces, and expanding our local workshops.', 'https://images.unsplash.com/photo-1573496359142-b8d87734a5a2?auto=format&fit=crop&w=300&q=80', TRUE),
  ('22222222-2222-2222-2222-222222222222', 'Marcus Thorne', 'Dedicated to 100% financial transparency and modernizing community digital tools.', 'https://images.unsplash.com/photo-1560250097-0b93528c311a?auto=format&fit=crop&w=300&q=80', TRUE),
  ('33333333-3333-3333-3333-333333333333', 'Sarah Lin', 'Championing inclusivity, youth involvement, and launching quarterly social events.', 'https://images.unsplash.com/photo-1580489944761-15a19d654956?auto=format&fit=crop&w=300&q=80', TRUE),
  ('44444444-4444-4444-4444-444444444444', 'David O''Connor', 'Prioritizing facility upgrades and streamlined facility booking processes.', 'https://images.unsplash.com/photo-1534528741775-53994a69daeb?auto=format&fit=crop&w=300&q=80', TRUE);

INSERT INTO members (member_code, full_name, email, phone, is_active)
SELECT
  'M-' || substr(encode(gen_random_bytes(6), 'hex'), 1, 8) AS member_code,
  (ARRAY['Alex', 'Jordan', 'Taylor', 'Morgan', 'Sam', 'Chris', 'Pat', 'Riley', 'Avery', 'Casey'])[floor(random() * 10 + 1)] || ' ' ||
  (ARRAY['Smith', 'Johnson', 'Williams', 'Brown', 'Jones', 'Garcia', 'Miller', 'Davis'])[floor(random() * 8 + 1)] AS full_name,
  'member' || i || '@example.com' AS email,
  '+1555' || LPAD(i::text, 7, '0') AS phone,
  TRUE AS is_active
FROM generate_series(1, 300) AS i;