-- Deterministic test fixtures. Minimum needed to exercise the RLS matrix — nothing more.
--
--   inspector_a  owns one draft and one submitted inspection
--   inspector_b  owns one draft — the negative-case counterparty
--   admin_u      owns nothing; exists only to exercise the read-only admin overlay
--
-- Fixed UUIDs so assertions can name rows directly instead of querying for them.

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data,
  confirmation_token, recovery_token, email_change, email_change_token_new
)
values
  ('00000000-0000-0000-0000-000000000000', '11111111-1111-4111-8111-111111111111',
   'authenticated', 'authenticated', 'inspector.a@fieldproof.test', crypt('password123', gen_salt('bf')),
   now(), now(), now(),
   '{"provider":"email","providers":["email"]}', '{"full_name":"Inspector Alpha"}',
   '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '22222222-2222-4222-8222-222222222222',
   'authenticated', 'authenticated', 'inspector.b@fieldproof.test', crypt('password123', gen_salt('bf')),
   now(), now(), now(),
   '{"provider":"email","providers":["email"]}', '{"full_name":"Inspector Bravo"}',
   '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000', '33333333-3333-4333-8333-333333333333',
   'authenticated', 'authenticated', 'admin@fieldproof.test', crypt('password123', gen_salt('bf')),
   now(), now(), now(),
   '{"provider":"email","providers":["email"]}', '{"full_name":"Ada Admin"}',
   '', '', '', '');

-- profiles rows already exist via on_auth_user_created. Only the role needs promoting,
-- and only a privileged session can do it — which is the point of D4.
update public.profiles set role = 'admin' where id = '33333333-3333-4333-8333-333333333333';

-- ---------------------------------------------------------------- inspections

insert into public.inspections
  (id, inspector_id, site_name, site_address, client_name, inspection_date, status, submitted_at)
values
  ('a0000000-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111',
   'Harbour View Apartments', '12 Dock Road, Bristol', 'Meridian Property Group',
   date '2026-08-20', 'draft', null),
  ('a0000000-0000-4000-8000-000000000002', '11111111-1111-4111-8111-111111111111',
   'Northgate Retail Park', '4 Northgate Way, Leeds', 'Cavendish Estates',
   date '2026-08-22', 'submitted', timestamptz '2026-08-22 14:00:00+00'),
  ('b0000000-0000-4000-8000-000000000001', '22222222-2222-4222-8222-222222222222',
   'Riverside Depot', '88 Mill Lane, Sheffield', 'Ashcroft Logistics',
   date '2026-08-21', 'draft', null);

-- ---------------------------------------------------------------- items

insert into public.inspection_items
  (id, inspection_id, sort_order, title, description, area, severity, status)
values
  ('a1000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000001',
   0, 'Cracked window pane', 'Hairline crack, lower left pane.', 'Stairwell, level 2', 'medium', 'open'),
  ('a1000000-0000-4000-8000-000000000002', 'a0000000-0000-4000-8000-000000000002',
   0, 'Exposed wiring at junction box', 'Cover plate missing; conductors visible.', 'Plant room', 'critical', 'open'),
  ('a1000000-0000-4000-8000-000000000003', 'a0000000-0000-4000-8000-000000000002',
   1, 'Fire door does not latch', 'Door binds on the frame and fails to self-close.', 'Corridor B', 'high', 'open'),
  ('b1000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000001',
   0, 'Damaged loading bay seal', null, 'Bay 3', 'low', 'open');

-- ---------------------------------------------------------------- photos

insert into public.item_photos
  (id, item_id, inspection_id, storage_path, caption, content_type, byte_size)
values
  ('a2000000-0000-4000-8000-000000000001',
   'a1000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000001',
   '11111111-1111-4111-8111-111111111111/a0000000-0000-4000-8000-000000000001/a1000000-0000-4000-8000-000000000001/a2000000-0000-4000-8000-000000000001.jpg',
   'Crack detail', 'image/jpeg', 482113),
  ('a2000000-0000-4000-8000-000000000002',
   'a1000000-0000-4000-8000-000000000002', 'a0000000-0000-4000-8000-000000000002',
   '11111111-1111-4111-8111-111111111111/a0000000-0000-4000-8000-000000000002/a1000000-0000-4000-8000-000000000002/a2000000-0000-4000-8000-000000000002.jpg',
   'Junction box, cover removed', 'image/jpeg', 733920),
  ('b2000000-0000-4000-8000-000000000001',
   'b1000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000001',
   '22222222-2222-4222-8222-222222222222/b0000000-0000-4000-8000-000000000001/b1000000-0000-4000-8000-000000000001/b2000000-0000-4000-8000-000000000001.jpg',
   null, 'image/jpeg', 210044);
