-- =========================================================
-- RUNOVA — Esquema de base de datos (PostgreSQL / Supabase)
-- =========================================================
-- Cómo usar:
-- 1. Crea un proyecto en supabase.com.
-- 2. Pega este archivo completo en SQL Editor y ejecútalo.
-- 3. Supabase ya gestiona auth.users (login); este esquema
--    engancha "profiles" a auth.users con el mismo id.
-- 4. Crea los buckets de Storage indicados al final.
--
-- Convenciones:
-- - UUID como clave primaria en casi todo (generado con gen_random_uuid()).
-- - Toda tabla con datos de usuario tiene Row Level Security (RLS) activada.
-- - La visibilidad usa el enum visibility ('public','followers','friends','only_me').
-- - Las políticas usan funciones auxiliares (is_following, are_friends, etc.)
--   en vez de repetir subconsultas, para que sean fáciles de mantener.
-- =========================================================

create extension if not exists pgcrypto; -- para gen_random_uuid()

-- =========================================================
-- 1. ENUMS
-- =========================================================
create type visibility as enum ('public','followers','friends','only_me');
create type account_type as enum ('public','private');
create type post_type as enum ('activity','meal','event','achievement','challenge','text');
create type report_category as enum ('spam','harassment','inappropriate','misinformation','other');
create type report_target as enum ('post','user','event','comment');
create type challenge_scope as enum ('personal','friends','community');
create type sub_tier as enum ('free','pro');
create type message_status as enum ('pending','accepted','blocked');

-- =========================================================
-- 2. USUARIOS Y PERFILES
-- =========================================================
-- auth.users ya existe (lo crea Supabase Auth). profiles.id = auth.users.id

create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique not null check (username ~ '^[a-z0-9_]{3,20}$'),
  name text not null,
  avatar_url text,
  cover_url text,
  bio text check (char_length(bio) <= 200),
  birthdate date,
  sex text,
  height_cm numeric(5,1),
  weight_kg numeric(5,1),
  city text,                       -- ubicación aproximada, nunca domicilio exacto
  units text not null default 'km' check (units in ('km','mi')),
  goal text,                       -- mantenerme activo, perder grasa, etc.
  level text,                      -- nivel deportivo general
  account_type account_type not null default 'public',
  home_privacy_radius_m integer default 500, -- radio de ocultación alrededor del domicilio
  hide_route_start_end boolean not null default true,
  tier sub_tier not null default 'free',
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);
create index on profiles (username);

create table user_settings (
  user_id uuid primary key references profiles(id) on delete cascade,
  theme text not null default 'system' check (theme in ('light','dark','system')),
  language text not null default 'es',
  notif_prefs jsonb not null default '{}'::jsonb,
  recommendations_enabled boolean not null default true,
  location_enabled boolean not null default false,
  updated_at timestamptz not null default now()
);

create table privacy_settings (
  user_id uuid primary key references profiles(id) on delete cascade,
  activities_visibility visibility not null default 'followers',
  meals_visibility visibility not null default 'followers',
  events_visibility visibility not null default 'public',
  stats_visibility visibility not null default 'followers',
  who_can_follow text not null default 'everyone' check (who_can_follow in ('everyone','approval')),
  who_can_message text not null default 'followers' check (who_can_message in ('everyone','followers','nobody')),
  who_can_invite_events text not null default 'followers' check (who_can_invite_events in ('everyone','followers','nobody')),
  show_streak_publicly boolean not null default true
);

create table subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  tier sub_tier not null default 'pro',
  provider text, -- 'stripe'
  provider_ref text,
  status text not null default 'active' check (status in ('active','canceled','past_due')),
  current_period_end timestamptz,
  created_at timestamptz not null default now()
);
create index on subscriptions (user_id, status);

-- =========================================================
-- 3. RELACIONES SOCIALES
-- =========================================================
create table followers (
  follower_id uuid not null references profiles(id) on delete cascade,
  followee_id uuid not null references profiles(id) on delete cascade,
  status text not null default 'accepted' check (status in ('pending','accepted')), -- pending si followee es privado
  created_at timestamptz not null default now(),
  primary key (follower_id, followee_id),
  check (follower_id <> followee_id)
);
create index on followers (followee_id, status);

create table friendships (
  user_a uuid not null references profiles(id) on delete cascade,
  user_b uuid not null references profiles(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted')),
  requested_by uuid not null references profiles(id),
  created_at timestamptz not null default now(),
  primary key (user_a, user_b),
  check (user_a < user_b) -- evita duplicados (a,b) y (b,a); insertar siempre ordenado
);

create table blocked_users (
  blocker_id uuid not null references profiles(id) on delete cascade,
  blocked_id uuid not null references profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id)
);

create table muted_users (
  muter_id uuid not null references profiles(id) on delete cascade,
  muted_id uuid not null references profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (muter_id, muted_id)
);

-- =========================================================
-- 4. DEPORTES Y ACTIVIDADES
-- =========================================================
create table sports (
  id smallint primary key,
  code text unique not null,      -- 'run','bike','gym',...
  name text not null,
  icon text,
  supports_gps boolean not null default false
);
insert into sports (id,code,name,icon,supports_gps) values
 (1,'run','Running','🏃',true),(2,'walk','Caminar','🚶',true),(3,'bike','Ciclismo','🚴',true),
 (4,'swim','Natación','🏊',false),(5,'gym','Gimnasio','🏋️',false),(6,'basketball','Baloncesto','🏀',false),
 (7,'football','Fútbol','⚽',false),(8,'tennis','Tenis','🎾',false),(9,'badminton','Pádel/Bádminton','🏸',false),
 (10,'hike','Senderismo','🥾',true),(11,'yoga','Yoga','🧘',false),(12,'surf','Surf','🏄',false),(13,'other','Otros','⛹️',false);

create table activities (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  sport_id smallint not null references sports(id),
  source text not null default 'manual' check (source in ('manual','gps','integration')),
  distance_km numeric(7,3) default 0,
  duration_s integer not null check (duration_s > 0),
  calories_kcal integer,
  elevation_gain_m numeric(6,1),
  avg_pace_s_per_km integer,
  note text check (char_length(note) <= 280),
  place_label text,              -- texto libre, no coordenadas exactas
  visibility visibility not null default 'followers',
  started_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create index on activities (user_id, started_at desc);
create index on activities (sport_id);

-- Ruta GPS: puntos guardados aparte para no inflar "activities" y poder
-- aplicar privacidad de inicio/fin de forma independiente.
create table activity_routes (
  activity_id uuid primary key references activities(id) on delete cascade,
  points jsonb not null,          -- [[lat,lng,ts], ...] simplificado/decimado
  hide_start_end boolean not null default true,
  created_at timestamptz not null default now()
);

create table activity_stats (
  activity_id uuid primary key references activities(id) on delete cascade,
  splits jsonb,                   -- parciales por km/milla
  max_speed_kmh numeric(5,2),
  avg_hr integer,                 -- si llega de un wearable en el futuro
  cadence integer
);

create table streaks (
  user_id uuid primary key references profiles(id) on delete cascade,
  current_days integer not null default 0,
  longest_days integer not null default 0,
  last_active_date date,
  updated_at timestamptz not null default now()
);

create table achievements (
  id smallint primary key,
  code text unique not null,      -- 'first_activity','10km','30_days',...
  name text not null,
  icon text not null
);

create table user_achievements (
  user_id uuid not null references profiles(id) on delete cascade,
  achievement_id smallint not null references achievements(id),
  unlocked_at timestamptz not null default now(),
  primary key (user_id, achievement_id)
);

-- =========================================================
-- 5. NUTRICIÓN
-- =========================================================
create table foods (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  brand text,
  kcal_per_100g numeric(6,1) not null,
  protein_g numeric(5,1) not null default 0,
  carbs_g numeric(5,1) not null default 0,
  fat_g numeric(5,1) not null default 0,
  fiber_g numeric(5,1) default 0,
  created_by uuid references profiles(id), -- null = alimento base del sistema
  verified boolean not null default false,
  created_at timestamptz not null default now()
);
create index on foods using gin (to_tsvector('spanish', name));

create table recipes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  name text not null,
  photo_url text,
  servings integer not null default 1,
  created_at timestamptz not null default now()
);

create table meals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  slot text not null check (slot in ('breakfast','mid_morning','lunch','snack','dinner','other')),
  name text not null,
  photo_url text,
  kcal integer not null,
  protein_g numeric(5,1) not null default 0,
  carbs_g numeric(5,1) not null default 0,
  fat_g numeric(5,1) not null default 0,
  fiber_g numeric(5,1) default 0,
  estimated boolean not null default true, -- true si viene del escáner con IA
  visibility visibility not null default 'followers',
  logged_at timestamptz not null default now()
);
create index on meals (user_id, logged_at desc);

create table meal_items (
  id uuid primary key default gen_random_uuid(),
  meal_id uuid not null references meals(id) on delete cascade,
  food_id uuid references foods(id),
  quantity_g numeric(6,1) not null
);

-- =========================================================
-- 6. PUBLICACIONES Y SOCIAL
-- =========================================================
create table posts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  type post_type not null default 'text',
  text text check (char_length(text) <= 500),
  activity_id uuid references activities(id) on delete cascade,
  meal_id uuid references meals(id) on delete cascade,
  event_id uuid, -- FK añadida más abajo con ALTER TABLE, una vez existe "events"
  achievement_id smallint references achievements(id),
  visibility visibility not null default 'followers',
  created_at timestamptz not null default now()
);
create index on posts (user_id, created_at desc);
create index on posts (created_at desc);

create table post_media (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references posts(id) on delete cascade,
  url text not null,
  position smallint not null default 0
);

create table comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references posts(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  text text not null check (char_length(text) <= 300),
  created_at timestamptz not null default now()
);
create index on comments (post_id, created_at);

create table likes (
  post_id uuid not null references posts(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

create table saved_posts (
  post_id uuid not null references posts(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

-- =========================================================
-- 7. COMUNIDADES
-- =========================================================
create table communities (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text unique not null,
  description text,
  cover_url text,
  sport_id smallint references sports(id),
  created_by uuid not null references profiles(id),
  created_at timestamptz not null default now()
);

create table community_members (
  community_id uuid not null references communities(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  role text not null default 'member' check (role in ('member','moderator','owner')),
  joined_at timestamptz not null default now(),
  primary key (community_id, user_id)
);

-- =========================================================
-- 8. EVENTOS
-- =========================================================
create table events (
  id uuid primary key default gen_random_uuid(),
  organizer_id uuid not null references profiles(id) on delete cascade,
  community_id uuid references communities(id),
  name text not null,
  sport_id smallint not null references sports(id),
  description text,
  cover_url text,
  meeting_point_label text not null,  -- siempre texto/punto público, nunca domicilio
  meeting_lat numeric(9,6),
  meeting_lng numeric(9,6),
  event_date date not null,
  event_time time not null,
  distance_km numeric(6,2),
  level text,
  pace_label text,                    -- p.ej. "5:00-5:30/km"
  max_participants integer not null check (max_participants > 1),
  visibility visibility not null default 'public',
  status text not null default 'open' check (status in ('open','canceled','completed')),
  created_at timestamptz not null default now()
);
create index on events (event_date, sport_id);
create index on events (organizer_id);

alter table posts add constraint posts_event_fk
  foreign key (event_id) references events(id) on delete cascade;

create table event_participants (
  event_id uuid not null references events(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  status text not null default 'going' check (status in ('going','left','removed')),
  joined_at timestamptz not null default now(),
  primary key (event_id, user_id)
);

create table event_messages (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  text text not null check (char_length(text) <= 300),
  is_organizer_notice boolean not null default false,
  created_at timestamptz not null default now()
);
create index on event_messages (event_id, created_at);

-- =========================================================
-- 9. RETOS
-- =========================================================
create table challenges (
  id uuid primary key default gen_random_uuid(),
  scope challenge_scope not null default 'personal',
  created_by uuid not null references profiles(id),
  community_id uuid references communities(id),
  name text not null,
  sport_id smallint references sports(id),
  metric text not null check (metric in ('distance_km','duration_min','sessions_count')),
  target_value numeric(10,2) not null,
  starts_at date not null,
  ends_at date not null,
  created_at timestamptz not null default now(),
  check (ends_at >= starts_at)
);

create table challenge_members (
  challenge_id uuid not null references challenges(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  progress_value numeric(10,2) not null default 0,
  hide_participation boolean not null default false,
  joined_at timestamptz not null default now(),
  primary key (challenge_id, user_id)
);

-- =========================================================
-- 10. MENSAJERÍA
-- =========================================================
create table message_requests (
  id uuid primary key default gen_random_uuid(),
  from_user uuid not null references profiles(id) on delete cascade,
  to_user uuid not null references profiles(id) on delete cascade,
  status message_status not null default 'pending',
  created_at timestamptz not null default now(),
  unique (from_user, to_user)
);

create table messages (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references profiles(id) on delete cascade,
  recipient_id uuid not null references profiles(id) on delete cascade,
  text text check (char_length(text) <= 2000),
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index on messages (least(sender_id,recipient_id), greatest(sender_id,recipient_id), created_at);

-- =========================================================
-- 11. NOTIFICACIONES
-- =========================================================
create table notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  type text not null, -- 'new_follower','like','comment','event_invite','challenge_completed',...
  actor_id uuid references profiles(id),
  payload jsonb not null default '{}'::jsonb,
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index on notifications (user_id, created_at desc);

-- =========================================================
-- 12. MODERACIÓN
-- =========================================================
create table reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references profiles(id) on delete cascade,
  target_type report_target not null,
  target_id uuid not null,
  category report_category not null,
  details text,
  status text not null default 'open' check (status in ('open','reviewing','resolved','dismissed')),
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);
create index on reports (status, created_at);

-- =========================================================
-- 13. FUNCIONES AUXILIARES (usadas por las políticas RLS)
-- =========================================================
create or replace function is_blocked(a uuid, b uuid) returns boolean
language sql stable as $$
  select exists(
    select 1 from blocked_users
    where (blocker_id = a and blocked_id = b) or (blocker_id = b and blocked_id = a)
  );
$$;

create or replace function is_following(a uuid, b uuid) returns boolean
language sql stable as $$
  select exists(select 1 from followers where follower_id = a and followee_id = b and status = 'accepted');
$$;

create or replace function are_friends(a uuid, b uuid) returns boolean
language sql stable as $$
  select exists(
    select 1 from friendships
    where status = 'accepted' and ((user_a = least(a,b) and user_b = greatest(a,b)))
  );
$$;

-- ¿puede "viewer" ver contenido de "owner" con esta visibilidad?
create or replace function can_view(viewer uuid, owner uuid, vis visibility) returns boolean
language sql stable as $$
  select case
    when viewer = owner then true
    when is_blocked(viewer, owner) then false
    when vis = 'public' then true
    when vis = 'followers' then is_following(viewer, owner)
    when vis = 'friends' then are_friends(viewer, owner)
    else false
  end;
$$;

-- =========================================================
-- 14. ROW LEVEL SECURITY
-- =========================================================
alter table profiles enable row level security;
alter table user_settings enable row level security;
alter table privacy_settings enable row level security;
alter table subscriptions enable row level security;
alter table followers enable row level security;
alter table friendships enable row level security;
alter table blocked_users enable row level security;
alter table muted_users enable row level security;
alter table activities enable row level security;
alter table activity_routes enable row level security;
alter table activity_stats enable row level security;
alter table streaks enable row level security;
alter table user_achievements enable row level security;
alter table meals enable row level security;
alter table meal_items enable row level security;
alter table recipes enable row level security;
alter table posts enable row level security;
alter table post_media enable row level security;
alter table comments enable row level security;
alter table likes enable row level security;
alter table saved_posts enable row level security;
alter table community_members enable row level security;
alter table communities enable row level security;
alter table events enable row level security;
alter table event_participants enable row level security;
alter table event_messages enable row level security;
alter table challenges enable row level security;
alter table challenge_members enable row level security;
alter table message_requests enable row level security;
alter table messages enable row level security;
alter table notifications enable row level security;
alter table reports enable row level security;

-- --- profiles ---
create policy "profiles_select" on profiles for select
  using (account_type = 'public' or id = auth.uid() or is_following(auth.uid(), id));
create policy "profiles_update_own" on profiles for update
  using (id = auth.uid());
create policy "profiles_insert_own" on profiles for insert
  with check (id = auth.uid());

-- --- settings / privacy / subscriptions: solo el propio usuario ---
create policy "own_rows_only" on user_settings for all using (user_id = auth.uid());
create policy "own_rows_only" on privacy_settings for all using (user_id = auth.uid());
create policy "own_rows_only" on subscriptions for select using (user_id = auth.uid());

-- --- relaciones sociales ---
create policy "followers_select" on followers for select
  using (follower_id = auth.uid() or followee_id = auth.uid());
create policy "followers_insert" on followers for insert
  with check (follower_id = auth.uid() and not is_blocked(auth.uid(), followee_id));
create policy "followers_delete" on followers for delete
  using (follower_id = auth.uid());

create policy "friendships_select" on friendships for select
  using (user_a = auth.uid() or user_b = auth.uid());
create policy "friendships_write" on friendships for all
  using (user_a = auth.uid() or user_b = auth.uid());

create policy "blocked_own" on blocked_users for all using (blocker_id = auth.uid());
create policy "muted_own" on muted_users for all using (muter_id = auth.uid());

-- --- actividades ---
create policy "activities_select" on activities for select
  using (can_view(auth.uid(), user_id, visibility));
create policy "activities_write_own" on activities for all
  using (user_id = auth.uid());

create policy "activity_routes_select" on activity_routes for select
  using (exists(select 1 from activities a where a.id = activity_id
         and can_view(auth.uid(), a.user_id, a.visibility)));
create policy "activity_routes_write_own" on activity_routes for all
  using (exists(select 1 from activities a where a.id = activity_id and a.user_id = auth.uid()));

create policy "activity_stats_select" on activity_stats for select
  using (exists(select 1 from activities a where a.id = activity_id
         and can_view(auth.uid(), a.user_id, a.visibility)));
create policy "activity_stats_write_own" on activity_stats for all
  using (exists(select 1 from activities a where a.id = activity_id and a.user_id = auth.uid()));

create policy "streaks_select" on streaks for select
  using (user_id = auth.uid() or is_following(auth.uid(), user_id));
create policy "user_achievements_select" on user_achievements for select
  using (user_id = auth.uid() or is_following(auth.uid(), user_id));

-- --- nutrición: siempre privada salvo que el usuario comparta un post ---
create policy "meals_select" on meals for select
  using (can_view(auth.uid(), user_id, visibility));
create policy "meals_write_own" on meals for all using (user_id = auth.uid());
create policy "meal_items_select" on meal_items for select
  using (exists(select 1 from meals m where m.id = meal_id and can_view(auth.uid(), m.user_id, m.visibility)));
create policy "meal_items_write_own" on meal_items for all
  using (exists(select 1 from meals m where m.id = meal_id and m.user_id = auth.uid()));
create policy "recipes_own" on recipes for all using (user_id = auth.uid());

-- --- feed social ---
create policy "posts_select" on posts for select
  using (can_view(auth.uid(), user_id, visibility));
create policy "posts_write_own" on posts for all using (user_id = auth.uid());
create policy "post_media_select" on post_media for select
  using (exists(select 1 from posts p where p.id = post_id and can_view(auth.uid(), p.user_id, p.visibility)));
create policy "post_media_write_own" on post_media for all
  using (exists(select 1 from posts p where p.id = post_id and p.user_id = auth.uid()));

create policy "comments_select" on comments for select
  using (exists(select 1 from posts p where p.id = post_id and can_view(auth.uid(), p.user_id, p.visibility)));
create policy "comments_insert" on comments for insert
  with check (user_id = auth.uid());
create policy "comments_delete_own" on comments for delete using (user_id = auth.uid());

create policy "likes_select" on likes for select
  using (exists(select 1 from posts p where p.id = post_id and can_view(auth.uid(), p.user_id, p.visibility)));
create policy "likes_own" on likes for all using (user_id = auth.uid());
create policy "saved_own" on saved_posts for all using (user_id = auth.uid());

-- --- comunidades (públicas de lectura; escritura de miembros/moderadores) ---
create policy "communities_select" on communities for select using (true);
create policy "communities_insert" on communities for insert with check (created_by = auth.uid());
create policy "community_members_select" on community_members for select using (true);
create policy "community_members_join" on community_members for insert with check (user_id = auth.uid());
create policy "community_members_leave" on community_members for delete using (user_id = auth.uid());

-- --- eventos ---
create policy "events_select" on events for select
  using (visibility = 'public' or organizer_id = auth.uid()
         or exists(select 1 from event_participants ep where ep.event_id = id and ep.user_id = auth.uid()));
create policy "events_insert" on events for insert with check (organizer_id = auth.uid());
create policy "events_update_organizer" on events for update using (organizer_id = auth.uid());

create policy "event_participants_select" on event_participants for select using (true);
create policy "event_participants_join" on event_participants for insert with check (user_id = auth.uid());
create policy "event_participants_leave" on event_participants for update using (user_id = auth.uid());

-- chat de evento: solo organizador y participantes actuales
create policy "event_messages_rw" on event_messages for all
  using (exists(select 1 from events e where e.id = event_id and e.organizer_id = auth.uid())
         or exists(select 1 from event_participants ep where ep.event_id = event_id
                   and ep.user_id = auth.uid() and ep.status = 'going'));

-- --- retos ---
create policy "challenges_select" on challenges for select using (true);
create policy "challenges_insert" on challenges for insert with check (created_by = auth.uid());
create policy "challenge_members_select" on challenge_members for select using (true);
create policy "challenge_members_own" on challenge_members for all using (user_id = auth.uid());

-- --- mensajería directa ---
create policy "message_requests_rw" on message_requests for all
  using (from_user = auth.uid() or to_user = auth.uid());
create policy "messages_rw" on messages for all
  using (sender_id = auth.uid() or recipient_id = auth.uid());

-- --- notificaciones y reportes ---
create policy "notifications_own" on notifications for select using (user_id = auth.uid());
create policy "notifications_update_own" on notifications for update using (user_id = auth.uid());
create policy "reports_insert" on reports for insert with check (reporter_id = auth.uid());
create policy "reports_select_own" on reports for select using (reporter_id = auth.uid());
-- Nota: el panel de administración usa un rol de servicio (service_role),
-- que puentea RLS, para leer y resolver todos los reportes.

-- =========================================================
-- 15. STORAGE (buckets a crear desde el panel de Supabase)
-- =========================================================
-- avatars        -> fotos de perfil (pública de lectura, escritura: dueño)
-- covers         -> portadas de perfil
-- meal-photos    -> fotos de comidas y del escáner de alimentos
-- post-media     -> fotos/vídeos de publicaciones
-- event-covers   -> imágenes de eventos
-- community-media -> imágenes de comunidades
--
-- Política típica por bucket (ejemplo para "meal-photos"):
--   select: true (si el post asociado es visible) o solo el dueño si es privado
--   insert/update/delete: auth.uid()::text = (storage.foldername(name))[1]
-- Guarda las rutas como {user_id}/{archivo}.jpg para poder aplicar esa regla.

-- =========================================================
-- 16. ÍNDICES ADICIONALES RECOMENDADOS
-- =========================================================
create index on followers (follower_id);
create index on event_participants (user_id);
create index on challenge_members (user_id);
create index on likes (user_id);
create index on comments (user_id);
