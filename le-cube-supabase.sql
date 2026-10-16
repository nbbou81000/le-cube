-- =====================================================================
--  LE CUBE — installation / mise à jour Supabase  (version 2)
--  À coller EN ENTIER dans Supabase > SQL Editor > New query, puis "Run".
--  Relançable sans danger : la partie en cours, les comptes et les
--  inventaires sont conservés lors d'une mise à jour.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. JOUEURS ET VALIDATION
--    Le tout premier inscrit devient automatiquement administrateur.
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  pseudo     text not null,
  status     text not null default 'pending' check (status in ('pending', 'approved', 'refused')),
  is_admin   boolean not null default false,
  created_at timestamptz not null default now()
);

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare premier boolean;
begin
  select not exists (select 1 from public.profiles) into premier;
  insert into public.profiles (id, pseudo, status, is_admin)
  values (
    new.id,
    left(coalesce(nullif(trim(new.raw_user_meta_data ->> 'pseudo'), ''), split_part(new.email, '@', 1)), 20),
    case when premier then 'approved' else 'pending' end,
    premier
  );
  return new;
end $$;

drop trigger if exists le_cube_new_user on auth.users;
create trigger le_cube_new_user after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.is_approved() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and status = 'approved');
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and status = 'approved' and is_admin);
$$;


-- ---------------------------------------------------------------------
-- 2. TABLES
-- ---------------------------------------------------------------------
create table if not exists public.game (
  id          int primary key default 1 check (id = 1),
  size        int not null default 128,
  started_at  timestamptz not null default now(),
  revealed_at timestamptz
);
-- Règles réglables par l'admin (ajoutées en version 2)
alter table public.game add column if not exists max_hp     int not null default 10;   -- clics pour casser un bloc
alter table public.game add column if not exists gold_every int not null default 200;  -- 1 bloc sur X contient de l'or (0 = jamais)
alter table public.game add column if not exists mat_every  int not null default 60;   -- 1 bloc sur X contient un matériau (0 = jamais)
alter table public.game add column if not exists seed       int not null default floor(random() * 2000000000)::int;
alter table public.game add column if not exists destroyed  bigint not null default 0;  -- blocs détruits (tenu à jour)
-- Effets en cours pour tout le monde (version 4)
alter table public.game add column if not exists rally_until timestamptz;   -- 📯 Cor de ralliement
alter table public.game add column if not exists eye_until   timestamptz;   -- 👁️ Œil du Cube
alter table public.game add column if not exists arts_v4     boolean not null default false;

create table if not exists public.treasure (
  id         int primary key default 1 check (id = 1),
  kind       text not null default 'noeud',
  message    text not null default '',
  image      text not null default '',
  updated_at timestamptz not null default now()
);

-- Seuls les blocs abîmés ou détruits sont stockés (absent = intact)
create table if not exists public.blocks (
  i  int primary key,
  hp smallint not null
);

-- Positions secrètes des artefacts (identiques pour tout le monde)
create table if not exists public.artifacts (
  i        int primary key,
  kind     text not null,
  found_by uuid references public.profiles(id) on delete set null,
  found_at timestamptz
);

-- Inventaire : artefacts, matériaux et pièces d'or ('or')
create table if not exists public.inventory (
  player uuid not null references public.profiles(id) on delete cascade,
  kind   text not null,
  qty    int  not null default 0,
  primary key (player, kind)
);

create table if not exists public.stats (
  player          uuid primary key references public.profiles(id) on delete cascade,
  hits            bigint not null default 0,
  blocks          bigint not null default 0,
  artifacts_found int not null default 0,
  artifacts_used  int not null default 0,
  best_break_ms   int,
  best_cps        int not null default 0,
  deepest         int not null default 0,
  last_seen       timestamptz
);
alter table public.stats add column if not exists gold_found      int not null default 0;
alter table public.stats add column if not exists materials_found int not null default 0;
alter table public.stats add column if not exists crafted         int not null default 0;
alter table public.stats add column if not exists trades          int not null default 0;
alter table public.stats add column if not exists missions_done   int not null default 0;
alter table public.stats add column if not exists peels           int not null default 0;  -- 🧅 Écorces arrachées
alter table public.stats add column if not exists magnet_until    timestamptz;              -- 🧲 Aimant actif jusqu'à

-- Boutique : prix en pièces d'or (0 = pas en vente)
create table if not exists public.shop (
  kind  text primary key,
  price int not null default 0
);
insert into public.shop (kind, price) values
  ('radar', 15), ('marteau', 20), ('foreuse', 25), ('bombe', 30), ('megabombe', 200),
  ('sonde', 10), ('scie', 25), ('aimant', 30), ('seisme', 35), ('cor', 40),
  ('ecorce', 0), ('oeil', 0)                   -- les deux légendaires ne se vendent jamais
on conflict (kind) do nothing;

-- Recettes de l'atelier
create table if not exists public.recipes (
  result      text primary key,
  ingredients jsonb not null
);
insert into public.recipes (result, ingredients) values
  ('radar',     '{"silex": 4, "fer": 1}'),
  ('marteau',   '{"fer": 4, "or": 3}'),
  ('bombe',     '{"poudre": 3, "fer": 2}'),
  ('foreuse',   '{"cristal": 2, "fer": 3}'),
  ('megabombe', '{"bombe": 3, "cristal": 3}'),
  ('scie',      '{"fer": 3, "silex": 2}'),
  ('seisme',    '{"poudre": 3, "cristal": 1}'),
  ('aimant',    '{"fer": 4, "cristal": 1}'),
  ('cor',       '{"or": 2, "cristal": 2, "fer": 2}'),
  ('sonde',     '{"silex": 3, "fer": 1}'),
  ('ecorce',    '{"megabombe": 2, "cristal": 10, "or": 100}'),
  ('oeil',      '{"radar": 3, "cristal": 5, "or": 50}')
on conflict (result) do nothing;

-- Marché entre joueurs : l'objet proposé est mis de côté jusqu'à la vente
create table if not exists public.market (
  id         bigserial primary key,
  seller     uuid not null references public.profiles(id) on delete cascade,
  give_kind  text not null,
  give_qty   int  not null check (give_qty > 0),
  want_kind  text not null,
  want_qty   int  not null check (want_qty > 0),
  created_at timestamptz not null default now()
);

-- Missions personnelles (3 par joueur)
create table if not exists public.missions (
  player     uuid not null references public.profiles(id) on delete cascade,
  slot       int  not null check (slot between 1 and 3),
  typ        text not null,             -- creuser | utiliser | livrer | trouver
  item       text,
  param      int  not null default 0,   -- creuser : couche minimale (0 = surface)
  target     int  not null,
  progress   int  not null default 0,
  reward     int  not null,
  created_at timestamptz not null default now(),
  primary key (player, slot)
);

-- Aucun accès direct aux tables : tout passe par les fonctions ci-dessous.
alter table public.profiles  enable row level security;
alter table public.game      enable row level security;
alter table public.treasure  enable row level security;
alter table public.blocks    enable row level security;
alter table public.artifacts enable row level security;
alter table public.inventory enable row level security;
alter table public.stats     enable row level security;
alter table public.shop      enable row level security;
alter table public.recipes   enable row level security;
alter table public.market    enable row level security;
alter table public.missions  enable row level security;

-- Salon de discussion (les 5 000 derniers messages au maximum, environ 1 Mo)
create table if not exists public.chat (
  id         bigserial primary key,
  player     uuid references public.profiles(id) on delete set null,
  body       text not null check (char_length(body) between 1 and 500),
  created_at timestamptz not null default now()
);
alter table public.chat enable row level security;

insert into public.game (id) values (1) on conflict (id) do nothing;
insert into public.treasure (id) values (1) on conflict (id) do nothing;
-- recalcule le compteur à chaque installation / mise à jour
update public.game set destroyed = (select count(*) from public.blocks where hp = 0) where id = 1;


-- ---------------------------------------------------------------------
-- 3. OUTILS INTERNES
-- ---------------------------------------------------------------------
-- Anciennes versions dont le format change
drop function if exists public._destroy(int, uuid);
drop function if exists public.get_leaderboard();
drop function if exists public._loot(int);
drop function if exists public._reward(int, uuid);
drop function if exists public._destroy(int, uuid);

create or replace function public._check_kind(k text) returns void
language plpgsql immutable as $$
begin
  if k is null or k not in ('bombe', 'foreuse', 'marteau', 'radar', 'megabombe', 'scie', 'seisme', 'aimant', 'cor', 'sonde', 'ecorce', 'oeil') then
    raise exception 'Type d''artefact inconnu';
  end if;
end $$;

create or replace function public._check_item(k text) returns void
language plpgsql immutable as $$
begin
  if k is null or k not in ('bombe', 'foreuse', 'marteau', 'radar', 'megabombe', 'scie', 'seisme', 'aimant', 'cor', 'sonde', 'ecorce', 'oeil', 'or', 'silex', 'fer', 'poudre', 'cristal') then
    raise exception 'Objet inconnu';
  end if;
end $$;

-- Artefacts légendaires : jamais en vente contre de l'or
create or replace function public._legendary(k text) returns boolean
language sql immutable as $$ select k in ('ecorce', 'oeil'); $$;

-- Couche d'un bloc : 0 = surface
create or replace function public._depth(idx int, s int) returns int
language sql immutable as $$
  select least(idx % s, s - 1 - idx % s, (idx / s) % s, s - 1 - (idx / s) % s, idx / (s*s), s - 1 - idx / (s*s));
$$;

create or replace function public._is_core(idx int, s int) returns boolean
language sql immutable as $$
  with b as (
    select case when s % 2 = 0 then s/2 - 1 else (s-1)/2 - 1 end as lo,
           case when s % 2 = 0 then s/2     else (s-1)/2 + 1 end as hi
  )
  select (idx % s) between b.lo and b.hi
     and ((idx / s) % s) between b.lo and b.hi
     and (idx / (s*s)) between b.lo and b.hi
  from b;
$$;

create or replace function public.core_done() returns boolean
language sql stable security definer set search_path = public as $$
  with g as (
    select size as s,
           case when size % 2 = 0 then size/2 - 1 else (size-1)/2 - 1 end as lo,
           case when size % 2 = 0 then size/2     else (size-1)/2 + 1 end as hi
    from public.game where id = 1
  ), cells as (
    select x + y*g.s + z*g.s*g.s as i
    from g, generate_series(g.lo, g.hi) as x, generate_series(g.lo, g.hi) as y, generate_series(g.lo, g.hi) as z
  )
  select not exists (
    select 1 from cells left join public.blocks b on b.i = cells.i where coalesce(b.hp, 1) > 0
  );
$$;

-- Nombre de blocs du cœur (2×2×2 si la taille est paire, 3×3×3 sinon)
create or replace function public._core_count(s int) returns int
language sql immutable as $$ select case when s % 2 = 0 then 8 else 27 end; $$;

-- Le cœur est scellé tant qu'il reste des blocs ailleurs dans le cube
create or replace function public._sealed() returns boolean
language sql stable security definer set search_path = public as $$
  select destroyed < size::bigint * size * size - public._core_count(size) from public.game where id = 1;
$$;

-- Fin de partie : absolument tous les blocs sont détruits
create or replace function public.all_done() returns boolean
language sql stable security definer set search_path = public as $$
  select destroyed >= size::bigint * size * size from public.game where id = 1;
$$;

-- Valeur indicative d'un objet en pièces d'or (missions)
create or replace function public._value(k text) returns int
language sql stable security definer set search_path = public as $$
  select case k when 'silex' then 1 when 'fer' then 2 when 'poudre' then 3 when 'cristal' then 5 when 'or' then 1
         else coalesce((select nullif(price, 0) from public.shop where kind = k), 20) end;
$$;

create or replace function public._add(p_uid uuid, p_kind text, p_qty int) returns void
language sql security definer set search_path = public as $$
  insert into public.inventory as inv (player, kind, qty) values (p_uid, p_kind, greatest(p_qty, 0))
  on conflict (player, kind) do update set qty = greatest(inv.qty + p_qty, 0);
$$;

create or replace function public._take(p_uid uuid, p_kind text, p_qty int) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.inventory set qty = qty - p_qty where player = p_uid and kind = p_kind and qty >= p_qty;
  if not found then raise exception 'Pas assez de « % »', p_kind; end if;
end $$;

create or replace function public._stats(uid uuid, h int, b int, af int, au int, bms int, cps int, deep int)
returns void language sql security definer set search_path = public as $$
  insert into public.stats as st (player, hits, blocks, artifacts_found, artifacts_used, best_break_ms, best_cps, deepest, last_seen)
  values (uid, h, b, af, au, bms, coalesce(cps, 0), coalesce(deep, 0), now())
  on conflict (player) do update set
    hits            = st.hits + excluded.hits,
    blocks          = st.blocks + excluded.blocks,
    artifacts_found = st.artifacts_found + excluded.artifacts_found,
    artifacts_used  = st.artifacts_used + excluded.artifacts_used,
    best_break_ms   = least(st.best_break_ms, excluded.best_break_ms),
    best_cps        = greatest(st.best_cps, excluded.best_cps),
    deepest         = greatest(st.deepest, excluded.deepest),
    last_seen       = now();
$$;

create or replace function public._bump(p_uid uuid, p_gold int, p_mats int, p_craft int, p_trades int, p_missions int)
returns void language sql security definer set search_path = public as $$
  insert into public.stats as st (player, gold_found, materials_found, crafted, trades, missions_done, last_seen)
  values (p_uid, p_gold, p_mats, p_craft, p_trades, p_missions, now())
  on conflict (player) do update set
    gold_found      = st.gold_found + excluded.gold_found,
    materials_found = st.materials_found + excluded.materials_found,
    crafted         = st.crafted + excluded.crafted,
    trades          = st.trades + excluded.trades,
    missions_done   = st.missions_done + excluded.missions_done,
    last_seen       = now();
$$;

-- Butin d'un bloc : calculé à partir de sa position et d'une graine secrète,
-- donc identique quel que soit le joueur qui le casse. Renvoie 'or:5', 'fer:1'… ou null.
-- mult = 3 quand l'🧲 Aimant du joueur est actif.
create or replace function public._loot(idx int, mult int default 1) returns text
language plpgsql stable security definer set search_path = public as $$
declare g record; h1 float8; h2 float8; h3 float8; t float8;
begin
  select size, seed, gold_every, mat_every,
         ((seed::bigint * 31 + 7) % 2147483647)::int as seed2,
         ((seed::bigint + 99991) % 2147483647)::int as seed3
    into g from public.game where id = 1;
  h1 := (hashint4(idx # g.seed)::bigint + 2147483648) / 4294967296.0;
  if g.gold_every > 0 and h1 < mult::float8 / g.gold_every then
    h3 := (hashint4(idx # g.seed3)::bigint + 2147483648) / 4294967296.0;
    return 'or:' || case when h3 < 0.025 then 20 when h3 < 0.2 then 5 else 1 end;   -- 2,5 % de bourses de 20
  end if;
  h2 := (hashint4(idx # g.seed2)::bigint + 2147483648) / 4294967296.0;
  if g.mat_every > 0 and h2 < mult::float8 / g.mat_every then
    h3 := h2 * g.mat_every / mult;
    t := public._depth(idx, g.size)::float8 / greatest(1, (g.size - 1) / 2);
    return case
      when t < 0.25 then (case when h3 < 0.7 then 'silex' else 'fer' end)
      when t < 0.5  then (case when h3 < 0.25 then 'silex' when h3 < 0.75 then 'fer' else 'poudre' end)
      when t < 0.75 then (case when h3 < 0.3 then 'fer' when h3 < 0.8 then 'poudre' else 'cristal' end)
      else (case when h3 < 0.4 then 'poudre' else 'cristal' end)
    end || ':1';
  end if;
  return null;
end $$;

-- Récompenses d'un bloc détruit : artefact caché + butin. Renvoie {artefact, butin}.
create or replace function public._reward(idx int, uid uuid, mult int default 1) returns text[]
language plpgsql security definer set search_path = public as $$
declare a text; l text; lk text; lq int;
begin
  update public.artifacts set found_by = uid, found_at = now()
    where artifacts.i = idx and found_by is null
    returning kind into a;
  if a is not null then perform public._add(uid, a, 1); end if;
  l := public._loot(idx, mult);
  if l is not null then
    lk := split_part(l, ':', 1); lq := split_part(l, ':', 2)::int;
    perform public._add(uid, lk, lq);
    perform public._bump(uid, case when lk = 'or' then lq else 0 end, case when lk <> 'or' then lq else 0 end, 0, 0, 0);
  end if;
  return array[coalesce(a, ''), coalesce(l, '')];
end $$;

-- Détruit un bloc. Renvoie null s'il l'était déjà, sinon {artefact, butin}.
create or replace function public._destroy(idx int, uid uuid, mult int default 1) returns text[]
language plpgsql security definer set search_path = public as $$
declare v smallint; s int;
begin
  select size into s from public.game where id = 1;
  if public._is_core(idx, s) and public._sealed() then return null; end if;   -- cœur scellé
  insert into public.blocks as b (i, hp) values (idx, 0)
    on conflict (i) do update set hp = 0 where b.hp > 0
    returning b.hp into v;
  if v is null then return null; end if;
  return public._reward(idx, uid, mult);
end $$;

-- Multiplicateur de butin du joueur (🧲 Aimant : ×3 pendant 3 minutes)
create or replace function public._mult(uid uuid) returns int
language sql stable security definer set search_path = public as $$
  select case when exists (select 1 from public.stats where player = uid and magnet_until > now()) then 3 else 1 end;
$$;

-- Cache des artefacts au hasard dans les blocs encore intacts
-- (pour un cube 128³ : 233 artefacts, dont 1 Écorce du Monde et 2 Œils du Cube ; proportionnel ailleurs)
drop function if exists public._regen(int);
create or replace function public._regen(s int, only_kinds text[] default null) returns void
language sql security definer set search_path = public as $$
  insert into public.artifacts (i, kind)
  select c.cell, c.kind from (
    select floor(random() * (s::bigint * s * s))::int as cell, k.kind
    from (values ('bombe', 40), ('foreuse', 30), ('marteau', 25), ('radar', 20), ('megabombe', 6),
                 ('scie', 25), ('sonde', 25), ('seisme', 15), ('aimant', 15), ('cor', 10),
                 ('ecorce', 1), ('oeil', 2)) as k(kind, cnt),
         generate_series(1, greatest(1, round(k.cnt * (s::numeric * s * s) / 2097152)::int))
    where only_kinds is null or k.kind = any(only_kinds)
  ) c
  where not exists (select 1 from public.blocks b where b.i = c.cell and b.hp = 0)
    and not public._is_core(c.cell, s)
  on conflict (i) do nothing;
$$;

-- Nouvelle mission pour un joueur
create or replace function public._new_mission(p_uid uuid, p_slot int) returns void
language plpgsql security definer set search_path = public as $$
declare r float8 := random(); s int; dp int; t text; it text := null; pa int := 0; tg int; rw int;
  arts text[] := array['bombe', 'foreuse', 'marteau', 'radar', 'scie', 'sonde', 'seisme', 'aimant', 'cor'];
  mats text[] := array['silex', 'fer', 'poudre', 'cristal'];
begin
  select size into s from public.game where id = 1;
  select coalesce(max(deepest), 0) into dp from public.stats where player = p_uid;
  if r < 0.35 then
    t := 'creuser'; pa := least(greatest((s - 1) / 2 - 3, 0), dp + floor(random() * 4)::int);
    tg := 15 + floor(random() * 31)::int; rw := greatest(2, tg / 6 + pa / 3);
  elsif r < 0.55 then
    t := 'utiliser'; it := arts[1 + floor(random() * 9)::int]; tg := 1; rw := public._value(it) / 2 + 5;
  elsif r < 0.8 then
    t := 'livrer';
    if random() < 0.75 then
      it := mats[1 + floor(random() * 4)::int]; tg := 2 + floor(random() * 4)::int; rw := tg * public._value(it) * 2 + 2;
    else
      it := arts[1 + floor(random() * 9)::int]; tg := 1; rw := (public._value(it) * 3) / 2;
    end if;
  else
    t := 'trouver'; it := mats[1 + floor(random() * 4)::int]; tg := 1 + floor(random() * 3)::int;
    rw := tg * public._value(it) * 2 + 3;
  end if;
  insert into public.missions as ms (player, slot, typ, item, param, target, progress, reward, created_at)
  values (p_uid, p_slot, t, it, pa, tg, 0, rw, now())
  on conflict (player, slot) do update set typ = excluded.typ, item = excluded.item, param = excluded.param,
    target = excluded.target, progress = 0, reward = excluded.reward, created_at = now();
end $$;

-- Fait avancer les missions et paie celles qui sont terminées. Renvoie les messages à afficher.
create or replace function public._missions_progress(p_uid uuid, p_depths int[], p_loots text[], p_used text)
returns text[] language plpgsql security definer set search_path = public as $$
declare r record; msgs text[] := '{}';
begin
  if coalesce(array_length(p_depths, 1), 0) > 0 then
    update public.missions m set progress = m.progress + (select count(*) from unnest(p_depths) as dd where dd >= m.param)
     where m.player = p_uid and m.typ = 'creuser';
  end if;
  if coalesce(array_length(p_loots, 1), 0) > 0 then
    update public.missions m set progress = m.progress + coalesce((
        select sum(split_part(l, ':', 2)::int) from unnest(p_loots) as l where split_part(l, ':', 1) = m.item), 0)
     where m.player = p_uid and m.typ = 'trouver';
  end if;
  if p_used is not null then
    update public.missions set progress = progress + 1 where player = p_uid and typ = 'utiliser' and item = p_used;
  end if;
  for r in select * from public.missions
           where player = p_uid and typ in ('creuser', 'trouver', 'utiliser') and progress >= target loop
    perform public._add(p_uid, 'or', r.reward);
    perform public._bump(p_uid, r.reward, 0, 0, 0, 1);
    msgs := msgs || ('📜 Mission accomplie ! +' || r.reward || ' 🪙');
    perform public._new_mission(p_uid, r.slot);
  end loop;
  return msgs;
end $$;

revoke execute on function public._destroy(int, uuid, int) from public, anon, authenticated;
revoke execute on function public._reward(int, uuid, int) from public, anon, authenticated;
revoke execute on function public._loot(int, int) from public, anon, authenticated;
revoke execute on function public._mult(uuid) from public, anon, authenticated;
revoke execute on function public._stats(uuid, int, int, int, int, int, int, int) from public, anon, authenticated;
revoke execute on function public._bump(uuid, int, int, int, int, int) from public, anon, authenticated;
revoke execute on function public._add(uuid, text, int) from public, anon, authenticated;
revoke execute on function public._take(uuid, text, int) from public, anon, authenticated;
revoke execute on function public._regen(int, text[]) from public, anon, authenticated;
revoke execute on function public._new_mission(uuid, int) from public, anon, authenticated;
revoke execute on function public._missions_progress(uuid, int[], text[], text) from public, anon, authenticated;


-- ---------------------------------------------------------------------
-- 4. FONCTIONS DU JEU
-- ---------------------------------------------------------------------
create or replace function public.me() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('id', id, 'pseudo', pseudo, 'status', status, 'is_admin', is_admin)
  from public.profiles where id = auth.uid();
$$;

create or replace function public.game_state() returns json
language sql stable security definer set search_path = public as $$
  select case when public.is_approved() then json_build_object(
    'size', size, 'revealed', revealed_at is not null, 'max_hp', max_hp, 'destroyed', destroyed,
    'gold_every', gold_every, 'mat_every', mat_every,
    'rally_left', greatest(0, extract(epoch from rally_until - now())),
    'eye_left', greatest(0, extract(epoch from eye_until - now())),
    'eye', case when eye_until > now() then
      (select coalesce(json_agg(a.i), '[]'::json) from (select ar.i from public.artifacts ar where ar.found_by is null limit 3000) a) end,
    'magnet_left', (select greatest(0, extract(epoch from st.magnet_until - now())) from public.stats st where st.player = auth.uid()),
    'shop', (select coalesce(json_object_agg(kind, price), '{}'::json) from public.shop),
    'recipes', (select coalesce(json_object_agg(result, ingredients), '{}'::json) from public.recipes)
  ) end
  from public.game where id = 1;
$$;

create or replace function public.get_blocks() returns text
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_approved() then raise exception 'Accès non autorisé'; end if;
  return (select string_agg(i::text || ':' || hp::text, ',') from public.blocks);
end $$;

-- Coups groupés. Renvoie { r: [[index, pv, artefact, butin], ...], msgs: [...] }
create or replace function public.hit_blocks(idx int[], n int[], best_ms int default null, cps int default null, deep int default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid(); g record; k int; m int; v smallint; d text[];
  total int := 0; broke int := 0; nf int := 0; sealed boolean;
  res jsonb := '[]'::jsonb; depths int[] := '{}'; loots text[] := '{}'; msgs text[]; mult int;
begin
  if not public.is_approved() then raise exception 'Accès non autorisé'; end if;
  if idx is null or coalesce(array_length(idx, 1), 0) = 0 then return jsonb_build_object('r', res, 'msgs', '[]'::jsonb); end if;
  if array_length(idx, 1) > 500 then raise exception 'Trop de coups envoyés en même temps'; end if;
  select * into g from public.game where id = 1;
  sealed := public._sealed();
  mult := public._mult(uid);
  for k in 1 .. array_length(idx, 1) loop
    continue when idx[k] is null or idx[k] < 0 or idx[k] >= g.size * g.size * g.size;
    if sealed and public._is_core(idx[k], g.size) then     -- cœur scellé : le coup ne compte pas
      res := res || jsonb_build_array(jsonb_build_array(idx[k],
        coalesce((select b.hp from public.blocks b where b.i = idx[k]), g.max_hp), '', 'scelle'));
      continue;
    end if;
    m := least(greatest(coalesce(n[k], 1), 1), g.max_hp);
    v := null; d := null;
    insert into public.blocks as b (i, hp) values (idx[k], greatest(g.max_hp - m, 0))
      on conflict (i) do update set hp = greatest(b.hp - m, 0) where b.hp > 0
      returning b.hp into v;
    if v is null then
      res := res || jsonb_build_array(jsonb_build_array(idx[k], 0, '', ''));
      continue;
    end if;
    total := total + m;
    if v = 0 then
      broke := broke + 1;
      d := public._reward(idx[k], uid, mult);
      depths := depths || public._depth(idx[k], g.size);
      if d[1] <> '' then nf := nf + 1; end if;
      if d[2] <> '' then loots := loots || d[2]; end if;
    end if;
    res := res || jsonb_build_array(jsonb_build_array(idx[k], v, coalesce(d[1], ''), coalesce(d[2], '')));
  end loop;
  perform public._stats(uid, total, broke, nf, 0, best_ms, cps, deep);
  msgs := public._missions_progress(uid, depths, loots, null);
  if broke > 0 then
    update public.game set destroyed = destroyed + broke where id = 1;
    update public.game set revealed_at = now() where id = 1 and revealed_at is null and public.all_done();
  end if;
  return jsonb_build_object('r', res, 'msgs', to_jsonb(coalesce(msgs, '{}')));
end $$;

-- Utiliser un artefact.
--   dir : laser = 0..5 (+x, -x, +y, -y, +z, -z) ; scie = axe de la ligne (0 = x, 1 = y, 2 = z)
create or replace function public.use_artifact(k text, center int, dir int default 0)
returns json language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid(); g record; s int; cx int; cy int; cz int; r int;
  dx int := 0; dy int := 0; dz int := 0; px int; py int; pz int; cell int; d text[];
  destroyed int[] := '{}'; found_list jsonb := '[]'::jsonb; nf int := 0; radar int := -1;
  depths int[] := '{}'; loots text[] := '{}'; msgs text[];
  cells int[] := '{}'; nd int; mult int; sealed boolean;
  damaged jsonb := '[]'::jsonb; probe jsonb := null; eye jsonb := null;
  layer int := null; peeled int := 0; bonus int := 0; core_d int; fa int; fb int;
  e record;
begin
  if not public.is_approved() then raise exception 'Accès non autorisé'; end if;
  perform public._check_kind(k);
  perform public._take(uid, k, 1);
  select * into g from public.game where id = 1;
  s := g.size;
  mult := public._mult(uid);
  sealed := public._sealed();
  if center is null or center < 0 or center >= s*s*s then
    center := (s/2) + (s/2)*s + (s/2)*s*s;
  end if;
  cx := center % s; cy := (center / s) % s; cz := center / (s*s);

  if k in ('bombe', 'megabombe') then
    r := case when k = 'bombe' then 1 else 3 end;
    for pz in greatest(cz - r, 0) .. least(cz + r, s - 1) loop
      for py in greatest(cy - r, 0) .. least(cy + r, s - 1) loop
        for px in greatest(cx - r, 0) .. least(cx + r, s - 1) loop
          cells := cells || (px + py*s + pz*s*s);
        end loop;
      end loop;
    end loop;
  elsif k = 'foreuse' then
    dx := case dir when 0 then 1 when 1 then -1 else 0 end;
    dy := case dir when 2 then 1 when 3 then -1 else 0 end;
    dz := case dir when 4 then 1 when 5 then -1 else 0 end;
    for r in 0 .. 14 loop
      px := cx + dx*r; py := cy + dy*r; pz := cz + dz*r;
      exit when px < 0 or py < 0 or pz < 0 or px >= s or py >= s or pz >= s;
      cells := cells || (px + py*s + pz*s*s);
    end loop;
  elsif k = 'scie' then
    -- 🪚 une ligne entière, d'un bord à l'autre du cube
    for r in 0 .. s - 1 loop
      cells := cells || case coalesce(dir, 0) when 1 then cx + r*s + cz*s*s
                                              when 2 then cx + cy*s + r*s*s
                                              else r + cy*s + cz*s*s end;
    end loop;
  elsif k = 'radar' then
    select ar.i into radar from public.artifacts ar
      where ar.found_by is null
      order by abs(ar.i % s - cx) + abs((ar.i / s) % s - cy) + abs(ar.i / (s*s) - cz)
      limit 1;
    radar := coalesce(radar, -1);
  elsif k = 'seisme' then
    -- 🌋 tous les blocs dans un rayon de 6 perdent la moitié de leurs points de vie
    for e in
      with c as (
        select (cx + ox) + (cy + oy)*s + (cz + oz)*s*s as i
        from generate_series(-6, 6) ox, generate_series(-6, 6) oy, generate_series(-6, 6) oz
        where ox*ox + oy*oy + oz*oz <= 36
          and cx + ox between 0 and s - 1 and cy + oy between 0 and s - 1 and cz + oz between 0 and s - 1
      )
      insert into public.blocks as b (i, hp)
      select c.i, (g.max_hp / 2)::smallint from c
      where not (sealed and public._is_core(c.i, s))
      on conflict (i) do update set hp = (b.hp / 2)::smallint where b.hp > 0
      returning b.i, b.hp
    loop
      if e.hp = 0 then
        d := public._reward(e.i, uid, mult);
        destroyed := destroyed || e.i;
        depths := depths || public._depth(e.i, s);
        if d[1] <> '' then nf := nf + 1; found_list := found_list || jsonb_build_array(jsonb_build_object('i', e.i, 'kind', d[1])); end if;
        if d[2] <> '' then loots := loots || d[2]; end if;
      else
        damaged := damaged || jsonb_build_array(jsonb_build_array(e.i, e.hp));
      end if;
    end loop;
  elsif k = 'sonde' then
    -- 🔍 butin caché dans un cube de 11×11×11 autour du point visé
    select coalesce(jsonb_agg(jsonb_build_array(q.i, q.l)), '[]'::jsonb) into probe from (
      select c.i, public._loot(c.i, mult) as l
      from (select (cx + ox) + (cy + oy)*s + (cz + oz)*s*s as i
            from generate_series(-5, 5) ox, generate_series(-5, 5) oy, generate_series(-5, 5) oz
            where cx + ox between 0 and s - 1 and cy + oy between 0 and s - 1 and cz + oz between 0 and s - 1) c
      where not exists (select 1 from public.blocks b where b.i = c.i and b.hp = 0)
    ) q where q.l is not null;
  elsif k = 'aimant' then
    insert into public.stats as st (player, magnet_until) values (uid, now() + interval '3 minutes')
      on conflict (player) do update set magnet_until = greatest(coalesce(st.magnet_until, now()), now()) + interval '3 minutes';
  elsif k = 'cor' then
    update public.game set rally_until = greatest(coalesce(rally_until, now()), now()) + interval '60 seconds' where id = 1;
  elsif k = 'oeil' then
    update public.game set eye_until = greatest(coalesce(eye_until, now()), now()) + interval '5 minutes' where id = 1;
    select coalesce(jsonb_agg(a.i), '[]'::jsonb) into eye
      from (select ar.i from public.artifacts ar where ar.found_by is null limit 3000) a;
  elsif k = 'ecorce' then
    -- 🧅 arrache toute la couche la plus extérieure qui reste (jamais le cœur)
    core_d := case when s % 2 = 0 then s/2 - 1 else (s-1)/2 - 1 end;   -- première couche du cœur
    if not sealed then raise exception 'Il ne reste plus que le cœur : l''Écorce du Monde ne peut pas l''arracher'; end if;
    with dd as (
      select public._depth(b.i, s) as dp, count(*) as n from public.blocks b where b.hp = 0 group by 1
    )
    select min(l.dp) into layer
      from generate_series(0, core_d - 1) as l(dp) left join dd on dd.dp = l.dp
     where coalesce(dd.n, 0) < (s - 2*l.dp)::bigint ^ 3 - greatest(s - 2*l.dp - 2, 0)::bigint ^ 3;
    if layer is null then raise exception 'Plus aucune couche à arracher'; end if;
    fa := layer; fb := s - 1 - layer;
    with c as (
      select x + y*s + z*s*s as i from generate_series(fa, fb) x, generate_series(fa, fb) y, unnest(array[fa, fb]) z
      union all
      select x + y*s + z*s*s from generate_series(fa, fb) x, unnest(array[fa, fb]) y, generate_series(fa + 1, fb - 1) z
      union all
      select x + y*s + z*s*s from unnest(array[fa, fb]) x, generate_series(fa + 1, fb - 1) y, generate_series(fa + 1, fb - 1) z
    ), ins as (
      insert into public.blocks as b (i, hp) select c.i, 0 from c
      on conflict (i) do update set hp = 0 where b.hp > 0
      returning b.i
    ), arts as (
      update public.artifacts a set found_by = uid, found_at = now()
        from ins where a.i = ins.i and a.found_by is null
      returning a.i, a.kind
    )
    select (select count(*) from ins),
           (select coalesce(jsonb_agg(jsonb_build_object('i', arts.i, 'kind', arts.kind)), '[]'::jsonb) from arts)
      into peeled, found_list;
    for e in select x->>'kind' as kind from jsonb_array_elements(found_list) x loop
      perform public._add(uid, e.kind, 1); nf := nf + 1;
    end loop;
    -- pas de butin bloc par bloc (l'économie exploserait) : une prime fixe à la place
    bonus := 50;
    perform public._add(uid, 'or', bonus);
    perform public._bump(uid, bonus, 0, 0, 0, 0);
  end if;

  if coalesce(array_length(cells, 1), 0) > 0 then
    foreach cell in array cells loop
      d := public._destroy(cell, uid, mult);
      if d is not null then
        destroyed := destroyed || cell;
        depths := depths || public._depth(cell, s);
        if d[1] <> '' then
          nf := nf + 1;
          found_list := found_list || jsonb_build_array(jsonb_build_object('i', cell, 'kind', d[1]));
        end if;
        if d[2] <> '' then loots := loots || d[2]; end if;
      end if;
    end loop;
  end if;

  nd := coalesce(array_length(destroyed, 1), 0);
  -- (les blocs de l'Écorce ne comptent pas dans « blocs cassés » du classement)
  perform public._stats(uid, 0, nd, nf, 1, null, null, null);
  if k = 'ecorce' then update public.stats set peels = peels + 1 where player = uid; end if;
  msgs := public._missions_progress(uid, depths, loots, k);
  if nd + peeled > 0 then
    update public.game as gm set destroyed = gm.destroyed + nd + peeled where gm.id = 1;
    update public.game set revealed_at = now() where id = 1 and revealed_at is null and public.all_done();
  end if;
  return json_build_object('destroyed', destroyed, 'found', found_list, 'loot', loots, 'radar', radar,
                           'damaged', damaged, 'probe', probe, 'eye', eye,
                           'layer', layer, 'peeled', peeled, 'bonus', bonus,
                           'msgs', coalesce(msgs, '{}'));
end $$;

create or replace function public.get_inventory() returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_object_agg(kind, qty), '{}'::json)
  from public.inventory where player = auth.uid() and qty > 0;
$$;

-- Donner n'importe quel objet (artefact, matériau, or) à un autre joueur
create or replace function public.give_item(to_player uuid, k text, qty int default 1) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_approved() then raise exception 'Accès non autorisé'; end if;
  perform public._check_item(k);
  if qty is null or qty < 1 or qty > 9999 then raise exception 'Quantité invalide'; end if;
  if to_player = auth.uid() then raise exception 'Tu ne peux pas te faire un cadeau à toi-même'; end if;
  if not exists (select 1 from public.profiles where id = to_player and status = 'approved') then
    raise exception 'Joueur inconnu';
  end if;
  perform public._take(auth.uid(), k, qty);
  perform public._add(to_player, k, qty);
end $$;

-- (ancienne version, gardée pour compatibilité)
create or replace function public.give_artifact(to_player uuid, k text) returns void
language sql security definer set search_path = public as $$
  select public.give_item(to_player, k, 1);
$$;

-- ----- Boutique et atelier -----
create or replace function public.shop_buy(p_kind text, p_qty int default 1) returns void
language plpgsql security definer set search_path = public as $$
declare pr int;
begin
  if not public.is_approved() then raise exception 'Accès non autorisé'; end if;
  perform public._check_kind(p_kind);
  if p_qty is null or p_qty < 1 or p_qty > 99 then raise exception 'Quantité invalide'; end if;
  if public._legendary(p_kind) then raise exception 'Les artefacts légendaires ne s''achètent pas'; end if;
  select price into pr from public.shop where kind = p_kind;
  if coalesce(pr, 0) <= 0 then raise exception 'Cet artefact n''est pas en vente'; end if;
  perform public._take(auth.uid(), 'or', pr * p_qty);
  perform public._add(auth.uid(), p_kind, p_qty);
end $$;

create or replace function public.craft(p_kind text) returns void
language plpgsql security definer set search_path = public as $$
declare ing jsonb; e record;
begin
  if not public.is_approved() then raise exception 'Accès non autorisé'; end if;
  select ingredients into ing from public.recipes where result = p_kind;
  if ing is null then raise exception 'Pas de recette pour cet objet'; end if;
  for e in select key, value::int as q from jsonb_each_text(ing) loop
    perform public._take(auth.uid(), e.key, e.q);
  end loop;
  perform public._add(auth.uid(), p_kind, 1);
  perform public._bump(auth.uid(), 0, 0, 1, 0, 0);
end $$;

-- ----- Marché -----
create or replace function public.market_list() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_approved() then raise exception 'Accès non autorisé'; end if;
  return (select coalesce(json_agg(json_build_object(
      'id', m.id, 'seller', m.seller, 'pseudo', p.pseudo, 'give_kind', m.give_kind, 'give_qty', m.give_qty,
      'want_kind', m.want_kind, 'want_qty', m.want_qty, 'created_at', m.created_at) order by m.created_at desc), '[]'::json)
    from public.market m join public.profiles p on p.id = m.seller);
end $$;

create or replace function public.market_create(p_give text, p_give_qty int, p_want text, p_want_qty int) returns bigint
language plpgsql security definer set search_path = public as $$
declare new_id bigint;
begin
  if not public.is_approved() then raise exception 'Accès non autorisé'; end if;
  perform public._check_item(p_give); perform public._check_item(p_want);
  if p_give = p_want then raise exception 'Choisis deux objets différents'; end if;
  if p_give_qty < 1 or p_give_qty > 9999 or p_want_qty < 1 or p_want_qty > 9999 then raise exception 'Quantité invalide'; end if;
  if (select count(*) from public.market where seller = auth.uid()) >= 10 then
    raise exception 'Maximum 10 offres en même temps';
  end if;
  perform public._take(auth.uid(), p_give, p_give_qty);   -- mis de côté jusqu'à la vente
  insert into public.market (seller, give_kind, give_qty, want_kind, want_qty)
    values (auth.uid(), p_give, p_give_qty, p_want, p_want_qty) returning id into new_id;
  return new_id;
end $$;

create or replace function public.market_cancel(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare o record;
begin
  select * into o from public.market where id = p_id for update;
  if not found then raise exception 'Offre introuvable'; end if;
  if o.seller <> auth.uid() and not public.is_admin() then raise exception 'Ce n''est pas ton offre'; end if;
  delete from public.market where id = p_id;
  perform public._add(o.seller, o.give_kind, o.give_qty);
end $$;

create or replace function public.market_accept(p_id bigint) returns json
language plpgsql security definer set search_path = public as $$
declare o record;
begin
  if not public.is_approved() then raise exception 'Accès non autorisé'; end if;
  select * into o from public.market where id = p_id for update;
  if not found then raise exception 'Offre déjà prise ou retirée'; end if;
  if o.seller = auth.uid() then raise exception 'C''est ta propre offre'; end if;
  perform public._take(auth.uid(), o.want_kind, o.want_qty);
  perform public._add(o.seller, o.want_kind, o.want_qty);
  perform public._add(auth.uid(), o.give_kind, o.give_qty);
  delete from public.market where id = p_id;
  perform public._bump(auth.uid(), 0, 0, 0, 1, 0);
  perform public._bump(o.seller, 0, 0, 0, 1, 0);
  return json_build_object('seller', o.seller, 'give_kind', o.give_kind, 'give_qty', o.give_qty,
                           'want_kind', o.want_kind, 'want_qty', o.want_qty);
end $$;

-- ----- Missions -----
create or replace function public.get_missions() returns json
language plpgsql security definer set search_path = public as $$
declare sl int;
begin
  if not public.is_approved() then raise exception 'Accès non autorisé'; end if;
  for sl in 1 .. 3 loop
    if not exists (select 1 from public.missions where player = auth.uid() and slot = sl) then
      perform public._new_mission(auth.uid(), sl);
    end if;
  end loop;
  return (select json_agg(json_build_object('slot', slot, 'typ', typ, 'item', item, 'param', param,
            'target', target, 'progress', least(progress, target), 'reward', reward) order by slot)
          from public.missions where player = auth.uid());
end $$;

create or replace function public.deliver_mission(p_slot int) returns int
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if not public.is_approved() then raise exception 'Accès non autorisé'; end if;
  select * into r from public.missions where player = auth.uid() and slot = p_slot and typ = 'livrer' for update;
  if not found then raise exception 'Mission introuvable'; end if;
  perform public._take(auth.uid(), r.item, r.target);
  perform public._add(auth.uid(), 'or', r.reward);
  perform public._bump(auth.uid(), r.reward, 0, 0, 0, 1);
  perform public._new_mission(auth.uid(), p_slot);
  return r.reward;
end $$;

create or replace function public.reroll_mission(p_slot int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_approved() then raise exception 'Accès non autorisé'; end if;
  if p_slot not between 1 and 3 then raise exception 'Mission introuvable'; end if;
  perform public._take(auth.uid(), 'or', 1);
  perform public._new_mission(auth.uid(), p_slot);
end $$;

create or replace function public.get_leaderboard()
returns table (id uuid, pseudo text, hits bigint, blocks bigint, artifacts_found int, artifacts_used int,
               best_break_ms int, best_cps int, deepest int, last_seen timestamptz,
               gold int, gold_found int, materials_found int, crafted int, trades int, missions_done int, peels int)
language sql stable security definer set search_path = public as $$
  select p.id, p.pseudo, coalesce(s.hits, 0), coalesce(s.blocks, 0), coalesce(s.artifacts_found, 0),
         coalesce(s.artifacts_used, 0), s.best_break_ms, coalesce(s.best_cps, 0), coalesce(s.deepest, 0), s.last_seen,
         coalesce((select iv.qty from public.inventory iv where iv.player = p.id and iv.kind = 'or'), 0),
         coalesce(s.gold_found, 0), coalesce(s.materials_found, 0), coalesce(s.crafted, 0),
         coalesce(s.trades, 0), coalesce(s.missions_done, 0), coalesce(s.peels, 0)
  from public.profiles p left join public.stats s on s.player = p.id
  where p.status = 'approved' and public.is_approved()
  order by coalesce(s.blocks, 0) desc, coalesce(s.hits, 0) desc;
$$;

create or replace function public.get_treasure() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if public.is_admin() or (public.is_approved() and public.all_done()) then
    return (select json_build_object('kind', kind, 'message', message, 'image', image)
            from public.treasure where id = 1);
  end if;
  return null;
end $$;


-- ---------------------------------------------------------------------
-- 5. FONCTIONS ADMIN
-- ---------------------------------------------------------------------
create or replace function public.set_treasure(k text, msg text, img text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Réservé à l''administrateur'; end if;
  if (select revealed_at from public.game where id = 1) is not null then
    raise exception 'Le trésor a déjà été révélé';
  end if;
  update public.treasure
     set kind = coalesce(k, 'noeud'), message = left(coalesce(msg, ''), 200),
         image = coalesce(img, ''), updated_at = now()
   where id = 1;
end $$;

create or replace function public.admin_players()
returns table (id uuid, pseudo text, email text, status text, is_admin boolean, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Réservé à l''administrateur'; end if;
  return query
    select p.id, p.pseudo, u.email::text, p.status, p.is_admin, p.created_at
    from public.profiles p join auth.users u on u.id = p.id
    order by p.created_at desc;
end $$;

create or replace function public.admin_set_status(p uuid, s text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Réservé à l''administrateur'; end if;
  if s not in ('pending', 'approved', 'refused') then raise exception 'Statut inconnu'; end if;
  if p = auth.uid() then raise exception 'Tu ne peux pas changer ton propre statut'; end if;
  update public.profiles set status = s where profiles.id = p;
end $$;

-- Règles : clics par bloc, rareté de l'or et des matériaux (modifiables à tout moment)
create or replace function public.admin_set_config(p_max_hp int, p_gold_every int, p_mat_every int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Réservé à l''administrateur'; end if;
  if p_max_hp < 1 or p_max_hp > 100 then raise exception 'Clics par bloc : entre 1 et 100'; end if;
  if p_gold_every < 0 or p_gold_every > 1000000 or p_mat_every < 0 or p_mat_every > 1000000 then
    raise exception 'Rareté invalide';
  end if;
  update public.game set max_hp = p_max_hp, gold_every = p_gold_every, mat_every = p_mat_every where id = 1;
  -- un bloc entamé ne peut pas avoir plus de PV que le nouveau maximum
  update public.blocks set hp = p_max_hp where hp > p_max_hp;
end $$;

create or replace function public.admin_set_price(p_kind text, p_price int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Réservé à l''administrateur'; end if;
  perform public._check_kind(p_kind);
  if p_price < 0 or p_price > 1000000 then raise exception 'Prix invalide'; end if;
  if public._legendary(p_kind) and p_price > 0 then raise exception 'Les artefacts légendaires ne se vendent pas'; end if;
  insert into public.shop (kind, price) values (p_kind, p_price)
    on conflict (kind) do update set price = excluded.price;
end $$;

create or replace function public.admin_new_cube(new_size int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Réservé à l''administrateur'; end if;
  if new_size < 10 or new_size > 256 then raise exception 'Taille entre 10 et 256'; end if;
  truncate public.blocks;
  delete from public.artifacts;
  delete from public.inventory;
  delete from public.stats;
  delete from public.market;
  delete from public.missions;
  -- (le salon est conservé : on le vide séparément si on veut)
  update public.game set size = new_size, started_at = now(), revealed_at = null, destroyed = 0,
         rally_until = null, eye_until = null, arts_v4 = true,
         seed = floor(random() * 2000000000)::int where id = 1;
  perform public._regen(new_size);
end $$;

create or replace function public.admin_artifacts() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Réservé à l''administrateur'; end if;
  return json_build_object(
    'kinds', (select coalesce(json_object_agg(t.kind, json_build_object('hidden', t.n_hidden, 'found', t.n_found)), '{}'::json)
              from (select a.kind, count(*) filter (where a.found_by is null) as n_hidden,
                           count(*) filter (where a.found_by is not null) as n_found
                    from public.artifacts a group by a.kind) t),
    'inventories', (select coalesce(json_agg(json_build_object('id', p.id, 'pseudo', p.pseudo, 'kind', iv.kind, 'qty', iv.qty)
                                             order by p.pseudo, iv.kind), '[]'::json)
                    from public.inventory iv join public.profiles p on p.id = iv.player where iv.qty > 0)
  );
end $$;

create or replace function public.admin_add_artifacts(k text, cnt int, min_layer int default 0, max_layer int default 999)
returns int language plpgsql security definer set search_path = public as $$
declare s int; lo int; hi int; added int;
begin
  if not public.is_admin() then raise exception 'Réservé à l''administrateur'; end if;
  perform public._check_kind(k);
  if cnt is null or cnt < 1 or cnt > 500 then raise exception 'Quantité entre 1 et 500'; end if;
  select size into s from public.game where id = 1;
  min_layer := greatest(coalesce(min_layer, 0), 0);
  max_layer := least(coalesce(max_layer, 999), (s - 1) / 2);
  if min_layer > max_layer then raise exception 'Couches invalides'; end if;
  lo := min_layer; hi := s - 1 - min_layer;
  with cand as (
    select distinct (lo + floor(random() * (hi - lo + 1))::int)
                  + (lo + floor(random() * (hi - lo + 1))::int) * s
                  + (lo + floor(random() * (hi - lo + 1))::int) * s * s as cell
    from generate_series(1, cnt * 80)
  )
  insert into public.artifacts (i, kind)
  select cand.cell, k from cand
  left join public.blocks b on b.i = cand.cell
  where coalesce(b.hp, 1) > 0
    and public._depth(cand.cell, s) <= max_layer
    and not exists (select 1 from public.artifacts a where a.i = cand.cell)
  order by random()
  limit cnt
  on conflict (i) do nothing;
  get diagnostics added = row_count;
  return added;
end $$;

create or replace function public.admin_remove_artifacts(k text, cnt int default null)
returns int language plpgsql security definer set search_path = public as $$
declare removed int;
begin
  if not public.is_admin() then raise exception 'Réservé à l''administrateur'; end if;
  perform public._check_kind(k);
  delete from public.artifacts where i in (
    select i from public.artifacts where kind = k and found_by is null order by random() limit cnt
  );
  get diagnostics removed = row_count;
  return removed;
end $$;

-- Donner (delta > 0) ou reprendre (delta < 0) n'importe quel objet à un joueur
create or replace function public.admin_set_inventory(p uuid, k text, delta int)
returns int language plpgsql security definer set search_path = public as $$
declare q int;
begin
  if not public.is_admin() then raise exception 'Réservé à l''administrateur'; end if;
  perform public._check_item(k);
  if not exists (select 1 from public.profiles where id = p) then raise exception 'Joueur inconnu'; end if;
  insert into public.inventory as inv (player, kind, qty) values (p, k, greatest(coalesce(delta, 0), 0))
    on conflict (player, kind) do update set qty = greatest(inv.qty + coalesce(delta, 0), 0)
    returning qty into q;
  return q;
end $$;

-- ---------------------------------------------------------------------
-- 5 bis. SALON DE DISCUSSION ET ESPACE DISQUE
-- ---------------------------------------------------------------------
create or replace function public._chat_row(c public.chat) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('id', c.id, 'player', c.player,
    'pseudo', coalesce((select pseudo from public.profiles where id = c.player), 'Ancien joueur'),
    'body', c.body, 'at', c.created_at);
$$;

create or replace function public.chat_send(p_body text) returns json
language plpgsql security definer set search_path = public as $$
declare b text := trim(coalesce(p_body, '')); last_at timestamptz; c public.chat;
begin
  if not public.is_approved() then raise exception 'Accès non autorisé'; end if;
  if b = '' then raise exception 'Message vide'; end if;
  if char_length(b) > 500 then raise exception 'Message trop long (500 caractères maximum)'; end if;
  select max(created_at) into last_at from public.chat where player = auth.uid();
  if last_at is not null and last_at > now() - interval '700 milliseconds' then
    raise exception 'Doucement ! Un message à la fois';
  end if;
  insert into public.chat (player, body) values (auth.uid(), b) returning * into c;
  -- garde-fou : jamais plus de 5 000 messages
  if c.id % 100 = 0 then
    delete from public.chat where id <= (select id from public.chat order by id desc offset 5000 limit 1);
  end if;
  return public._chat_row(c);
end $$;

-- Messages les plus récents (ou plus anciens que before_id), du plus ancien au plus récent
create or replace function public.chat_list(before_id bigint default null, lim int default 60) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_approved() then raise exception 'Accès non autorisé'; end if;
  return (select coalesce(json_agg(public._chat_row(t) order by t.id), '[]'::json) from (
    select * from public.chat c where before_id is null or c.id < before_id
    order by c.id desc limit least(greatest(coalesce(lim, 60), 1), 200)) t);
end $$;

create or replace function public.admin_chat_delete(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Réservé à l''administrateur'; end if;
  delete from public.chat where id = p_id;
end $$;

-- Vider le salon : older_days = 0 efface tout, sinon les messages plus vieux que X jours
create or replace function public.admin_chat_clear(older_days int default 0) returns bigint
language plpgsql security definer set search_path = public as $$
declare n bigint;
begin
  if not public.is_admin() then raise exception 'Réservé à l''administrateur'; end if;
  if coalesce(older_days, 0) <= 0 then
    select count(*) into n from public.chat;
    truncate public.chat;                    -- libère immédiatement l'espace disque
  else
    delete from public.chat where created_at < now() - make_interval(days => older_days);
    get diagnostics n = row_count;
  end if;
  return n;
end $$;

-- Place occupée dans la base (pour la jauge du panneau admin)
create or replace function public.admin_db_size() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Réservé à l''administrateur'; end if;
  return json_build_object(
    'total', pg_database_size(current_database()),
    'blocks', pg_total_relation_size('public.blocks'),
    'chat', pg_total_relation_size('public.chat'),
    'chat_count', (select count(*) from public.chat),
    'blocks_count', (select count(*) from public.blocks),
    'limit', 500 * 1024 * 1024
  );
end $$;

-- Premier remplissage des artefacts
do $$
begin
  if not exists (select 1 from public.artifacts) then
    perform public._regen((select size from public.game where id = 1));
    update public.game set arts_v4 = true where id = 1;
  end if;
end $$;

-- Version 4 : cache une seule fois les 7 nouveaux artefacts dans la partie en cours
do $$
begin
  if not (select arts_v4 from public.game where id = 1) then
    perform public._regen((select size from public.game where id = 1),
                          array['scie', 'sonde', 'seisme', 'aimant', 'cor', 'ecorce', 'oeil']);
    update public.game set arts_v4 = true where id = 1;
  end if;
end $$;


-- ---------------------------------------------------------------------
-- 6. PHOTO DU TRÉSOR (stockage privé)
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public) values ('tresor', 'tresor', false)
  on conflict (id) do nothing;

drop policy if exists "le_cube_tresor_lire" on storage.objects;
create policy "le_cube_tresor_lire" on storage.objects for select to authenticated
  using (bucket_id = 'tresor' and (public.is_admin() or (public.is_approved() and public.all_done())));

drop policy if exists "le_cube_tresor_ajouter" on storage.objects;
create policy "le_cube_tresor_ajouter" on storage.objects for insert to authenticated
  with check (bucket_id = 'tresor' and public.is_admin());

drop policy if exists "le_cube_tresor_modifier" on storage.objects;
create policy "le_cube_tresor_modifier" on storage.objects for update to authenticated
  using (bucket_id = 'tresor' and public.is_admin());

drop policy if exists "le_cube_tresor_supprimer" on storage.objects;
create policy "le_cube_tresor_supprimer" on storage.objects for delete to authenticated
  using (bucket_id = 'tresor' and public.is_admin());


-- ---------------------------------------------------------------------
-- 7. TEMPS RÉEL PRIVÉ
-- ---------------------------------------------------------------------
drop policy if exists "le_cube_temps_reel_lire" on realtime.messages;
create policy "le_cube_temps_reel_lire" on realtime.messages for select to authenticated
  using (public.is_approved());

drop policy if exists "le_cube_temps_reel_ecrire" on realtime.messages;
create policy "le_cube_temps_reel_ecrire" on realtime.messages for insert to authenticated
  with check (public.is_approved());

-- Fin. Tu peux fermer cette page.
