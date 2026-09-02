-- ============================================================================
-- Промавтоматика · Калькулятор індикативних КП · схема Supabase
-- Версія 1.0 · 22.08.2026
-- Виконати ОДИН раз у Supabase → SQL Editor (увесь файл цілком).
-- Повторний запуск безпечний: усе створюється з "if not exists" / "on conflict".
-- ============================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------- ПРОФІЛІ
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text not null default '',
  position    text default 'Менеджер з прямих продажів',
  phone       text,
  email       text,
  filial      text not null default 'Вінниця',
  role        text not null default 'manager' check (role in ('manager','admin')),
  created_at  timestamptz default now()
);

-- Профіль створюється автоматично для кожного нового користувача Auth.
-- Адмін потім дописує ПІБ/телефон/філію на сторінці «Користувачі» сайту.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, full_name)
  values (new.id, new.email, coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)))
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- Хелпер для політик: чи є поточний користувач адміном.
-- security definer → читає profiles в обхід RLS, щоб не було рекурсії політик.
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin')
$$;

-- ------------------------------------------------------------------- ЦІНИ
create table if not exists public.pv_prices (
  id               serial primary key,
  system_type      text not null check (system_type in ('network','hybrid')),
  placement        text not null check (placement in ('roof','ground')),
  power_segment    text not null check (power_segment in ('small','medium','large')),
  rate_usd_per_kwp numeric not null,
  updated_at       timestamptz default now(),
  updated_by       uuid references public.profiles(id),
  unique (system_type, placement, power_segment)
);

create table if not exists public.battery_prices (
  id               serial primary key,
  capacity_segment text not null unique check (capacity_segment in ('small','medium','large')),
  rate_usd_per_kwh numeric not null,
  updated_at       timestamptz default now(),
  updated_by       uuid references public.profiles(id)
);

-- Ціни УЗЕ. Відкриті для всіх авторизованих (не таємниця), редагує адмін.
create table if not exists public.uze_prices (
  uze_id      text primary key,
  brand       text not null,
  model       text not null,
  kind        text not null default 'Шафове (All-in-One)',
  kw          numeric not null,
  kwh         numeric not null,
  cooling     text,
  price_eur   numeric not null,             -- ціна постачальника як надана
  vat_in      boolean not null default false, -- чи включає ПДВ
  incoterm    text default 'уточнити',
  included    text,
  warranty    text,
  source      text,                         -- звідки ціна (рахунок, дата)
  sort        integer default 100,
  active      boolean not null default true,
  updated_at  timestamptz default now(),
  updated_by  uuid references public.profiles(id)
);

-- ----------------------------------------------------------- ЛІЧИЛЬНИК КП
create table if not exists public.kp_log (
  id               bigserial primary key,
  manager_id       uuid not null references public.profiles(id),
  created_at       timestamptz default now(),
  system_type      text not null,
  placement        text,
  installed_dc_kwp numeric,
  battery_kwh      numeric,
  total_price_usd  numeric not null default 0,
  uze_id           text,
  uze_qty          integer,
  uze_total_eur    numeric,
  client_name      text,
  city             text,
  kp_number        text
);
create index if not exists kp_log_manager_idx on public.kp_log (manager_id, created_at desc);
alter table public.kp_log add column if not exists params jsonb;

-- Автономер КП: YYYY-NNNN, окремий лічильник на кожен рік
create table if not exists public.kp_counter (year integer primary key, last integer not null default 0);
create or replace function public.next_kp_number()
returns text language plpgsql security definer set search_path = public as $$
declare y integer := extract(year from now())::integer; n integer;
begin
  insert into public.kp_counter (year, last) values (y, 1)
    on conflict (year) do update set last = public.kp_counter.last + 1
    returning last into n;
  return y::text || '-' || lpad(n::text, 4, '0');
end $$;

-- ------------------------------------------------------------- СТАРТОВІ ЦІНИ
-- Значення 1:1 з calc_engine.js v2.0 (PRICE_PER_KWP_USD, BATTERY_PRICE_PER_KWH_USD)
insert into public.pv_prices (system_type, placement, power_segment, rate_usd_per_kwp) values
  ('network','roof','small',420), ('network','ground','small',450),
  ('network','roof','medium',390), ('network','ground','medium',430),
  ('network','roof','large',380), ('network','ground','large',420),
  ('hybrid','roof','small',420),  ('hybrid','ground','small',450),
  ('hybrid','roof','medium',390), ('hybrid','ground','medium',430),
  ('hybrid','roof','large',380),  ('hybrid','ground','large',420)
on conflict (system_type, placement, power_segment) do nothing;

insert into public.battery_prices (capacity_segment, rate_usd_per_kwh) values
  ('small',460), ('medium',430), ('large',400)
on conflict (capacity_segment) do nothing;

-- УЗЕ: KSTAR — рахунки KSTR-QTN-20262807 від 28.07.2026; Elecnova і Huawei — дані комерційної функції 22.08.2026
insert into public.uze_prices (uze_id, brand, model, kw, kwh, cooling, price_eur, vat_in, incoterm, included, warranty, source, sort) values
  ('UZE-KS-240','KSTAR','KAC125DP2 + BC240DE2A',125,241.15,'Рідинне',36735.5,false,'FCA Poland',
   'Гібридний інвертор 125 кВт (Gen 2) · батарейна шафа 241,15 кВт·год · кабелі АКБ · вбудований EMS · трифазний лічильник',
   '5 років на продукт / 10 років на продуктивність','KSTR-QTN-20262807 від 28.07.2026, дійсний 1 місяць',10),
  ('UZE-KS-260','KSTAR','KAC125DP2 + BC260DE2A',125,261.24,'Рідинне',38774.5,false,'FCA Poland',
   'Гібридний інвертор 125 кВт (Gen 2) · батарейна шафа 261,24 кВт·год · кабелі АКБ · вбудований EMS · трифазний лічильник',
   '5 років на продукт / 10 років на продуктивність','KSTR-QTN-20262807-2 від 28.07.2026, дійсний 1 місяць',20),
  ('UZE-EN-261','Elecnova','ECO-E261LP-2A · 125 кВт / 261 кВт·год',125,261,'Рідинне',30500,false,'уточнити',
   'уточнити склад комплекту','уточнити','закупівельна ціна, 22.08.2026',30),
  ('UZE-HW-241','Huawei','LUNA2000-241-2S1',108,241,'Гібридне (рідинне + повітряне)',58000,true,'уточнити',
   'Батарейні модулі · вбудований PCS · RCM · система терморегулювання · TRSD (придушення теплового розгону) · DC-DC опційно',
   'уточнити','рахунок від 07.05.2026',40)
on conflict (uze_id) do nothing;

-- --------------------------------------------------------------------- RLS
alter table public.profiles       enable row level security;
alter table public.pv_prices      enable row level security;
alter table public.battery_prices enable row level security;
alter table public.kp_log         enable row level security;
alter table public.uze_prices     enable row level security;
alter table public.kp_counter     enable row level security;

-- profiles: менеджер читає тільки себе; адмін — читає і пише все
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select
  using (id = auth.uid() or public.is_admin());
drop policy if exists profiles_admin_write on public.profiles;
create policy profiles_admin_write on public.profiles for all
  using (public.is_admin()) with check (public.is_admin());

-- ціни: прямого доступу в менеджера НЕМАЄ. Тільки адмін.
drop policy if exists pv_prices_admin on public.pv_prices;
create policy pv_prices_admin on public.pv_prices for all
  using (public.is_admin()) with check (public.is_admin());
drop policy if exists battery_prices_admin on public.battery_prices;
create policy battery_prices_admin on public.battery_prices for all
  using (public.is_admin()) with check (public.is_admin());

-- uze_prices: читають усі авторизовані, пише адмін
drop policy if exists uze_prices_read on public.uze_prices;
create policy uze_prices_read on public.uze_prices for select to authenticated using (true);
drop policy if exists uze_prices_admin on public.uze_prices;
create policy uze_prices_admin on public.uze_prices for all
  using (public.is_admin()) with check (public.is_admin());

-- kp_log: читання — свої рядки або адмін; вставка — тільки через RPC (політики insert немає)
drop policy if exists kp_log_select on public.kp_log;
create policy kp_log_select on public.kp_log for select
  using (manager_id = auth.uid() or public.is_admin());
drop policy if exists kp_log_admin_delete on public.kp_log;
create policy kp_log_admin_delete on public.kp_log for delete
  using (public.is_admin());

-- ------------------------------------------------------------ RPC: РОЗРАХУНОК
-- Єдина точка, де ставки торкаються розрахунку. Менеджер отримує тільки підсумки.
-- p = {
--   system_type: 'network'|'hybrid'|'bess', placement: 'roof'|'ground',
--   installed_dc_kwp, battery_kwh,
--   uze_id, uze_qty, uze_total_eur   (УЗЕ рахується в браузері, тут лише для логу)
--   client_name, city, kp_number (порожній → згенерується автоматично при do_log),
--   params: повний стан форми для повтору КП з історії
-- }
-- do_log = true → одночасно пише рядок у kp_log (викликається при друку КП)
create or replace function public.calculate_quote(p jsonb, do_log boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid        uuid := auth.uid();
  adm        boolean;
  st         text := p->>'system_type';
  pl         text := p->>'placement';
  kwp        numeric := coalesce((p->>'installed_dc_kwp')::numeric, 0);
  kwh        numeric := coalesce((p->>'battery_kwh')::numeric, 0);
  pcat       text; bcat text;
  rate_a     numeric := 0; rate_b numeric := 0;
  pv_usd     numeric := 0; bat_usd numeric := 0; total_usd numeric := 0;
  u_id       text := p->>'uze_id';
  u_qty      integer := coalesce((p->>'uze_qty')::integer, 0);
  u_total    numeric := (p->>'uze_total_eur')::numeric;
  kp_no      text := nullif(trim(coalesce(p->>'kp_number', '')), '');
  res        jsonb;
begin
  if uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  adm := public.is_admin();

  -- ---- СЕС: PV + накопичення
  if st in ('network','hybrid') and kwp > 0 then
    if pl not in ('roof','ground') then
      raise exception 'placement must be roof|ground';
    end if;
    pcat := case when kwp <= 30 then 'small' when kwp < 100 then 'medium' else 'large' end;
    select rate_usd_per_kwp into rate_a from public.pv_prices
      where system_type = st and placement = pl and power_segment = pcat;
    if rate_a is null then
      raise exception 'no pv price for %/%/%', st, pl, pcat;
    end if;
    pv_usd := kwp * rate_a;

    if st = 'hybrid' and kwh > 0 then
      bcat := case when kwh <= 30 then 'small' when kwh < 100 then 'medium' else 'large' end;
      select rate_usd_per_kwh into rate_b from public.battery_prices where capacity_segment = bcat;
      if rate_b is null then
        raise exception 'no battery price for %', bcat;
      end if;
      bat_usd := kwh * rate_b;
    else
      kwh := 0;
    end if;
    total_usd := round(pv_usd + bat_usd);
  else
    kwp := 0; kwh := 0;
  end if;

  -- ---- лог
  if do_log then
    if kp_no is null then kp_no := public.next_kp_number(); end if;
    insert into public.kp_log (manager_id, system_type, placement, installed_dc_kwp, battery_kwh,
                               total_price_usd, uze_id, uze_qty, uze_total_eur,
                               client_name, city, kp_number, params)
    values (uid, coalesce(st, '?'), pl, nullif(kwp, 0), nullif(kwh, 0),
            total_usd, u_id, nullif(u_qty, 0), u_total,
            p->>'client_name', p->>'city', kp_no, p->'params');
  end if;

  res := jsonb_build_object(
    'total_price_usd', total_usd,
    'pv_kwp', kwp, 'battery_kwh', kwh,
    'vat_included', true,
    'is_admin', adm,
    'logged', do_log,
    'kp_number', kp_no
  );
  -- Розбивку і ставки бачить тільки адмін
  if adm then
    res := res || jsonb_build_object('breakdown', jsonb_build_object(
      'power_segment', pcat, 'rate_usd_per_kwp', rate_a, 'pv_price_usd', round(pv_usd),
      'battery_segment', bcat, 'rate_usd_per_kwh', rate_b, 'battery_price_usd', round(bat_usd)
    ));
  end if;
  return res;
end $$;

revoke all on function public.calculate_quote(jsonb, boolean) from public, anon;
grant execute on function public.calculate_quote(jsonb, boolean) to authenticated;

-- ---------------------------------------------------- ДАШБОРД: зведення по менеджерах
drop function if exists public.kp_stats(timestamptz, timestamptz);
-- Статистика по менеджерах. Рахується ПО ОСТАННЬОМУ КП на кожного клієнта
-- (повторні прорахунки того самого клієнта не псують суми й середній чек);
-- calc_count — скільки всього прорахунків зробив менеджер за період.
create or replace function public.kp_stats(date_from timestamptz default null, date_to timestamptz default null)
returns table (manager_id uuid, full_name text, filial text, kp_count bigint,
               sum_usd numeric, sum_uze_eur numeric, last_at timestamptz,
               avg_usd numeric, avg_kwp numeric, sum_kwp numeric, bess_count bigint, calc_count bigint)
language sql stable security definer set search_path = public as $$
  with lastkp as (
    select distinct on (k.manager_id, lower(trim(coalesce(nullif(k.client_name, ''), '~' || k.id::text)))) k.*
    from public.kp_log k
    where (date_from is null or k.created_at >= date_from)
      and (date_to   is null or k.created_at <  date_to)
    order by k.manager_id, lower(trim(coalesce(nullif(k.client_name, ''), '~' || k.id::text))), k.created_at desc
  ), allk as (
    select k.manager_id as mid, count(*) as c from public.kp_log k
    where (date_from is null or k.created_at >= date_from)
      and (date_to   is null or k.created_at <  date_to)
    group by k.manager_id
  )
  select pr.id, pr.full_name, pr.filial,
         count(k.id), coalesce(sum(k.total_price_usd),0), coalesce(sum(k.uze_total_eur),0), max(k.created_at),
         round(avg(k.total_price_usd) filter (where k.total_price_usd > 0)),
         round(avg(k.installed_dc_kwp) filter (where k.installed_dc_kwp > 0), 1),
         coalesce(sum(k.installed_dc_kwp), 0),
         count(k.id) filter (where coalesce(k.total_price_usd, 0) = 0),
         coalesce(max(a.c), 0)
  from public.profiles pr
  left join lastkp k on k.manager_id = pr.id
  left join allk a on a.mid = pr.id
  where public.is_admin() and pr.role = 'manager'
  group by pr.id, pr.full_name, pr.filial
  order by count(k.id) desc, pr.full_name
$$;
revoke all on function public.kp_stats(timestamptz, timestamptz) from public, anon;
grant execute on function public.kp_stats(timestamptz, timestamptz) to authenticated;

-- ------------------------------------------------------------ ПЕРШИЙ АДМІН
-- Створює користувача admin@admin / admin і робить його адміном.
-- ОБОВ'ЯЗКОВО змініть пароль після першого входу (Supabase → Authentication → Users).
do $$
declare new_id uuid := gen_random_uuid();
begin
  if not exists (select 1 from auth.users where email = 'admin@admin') then
    insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
                            email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                            created_at, updated_at, confirmation_token, recovery_token,
                            email_change_token_new, email_change)
    values ('00000000-0000-0000-0000-000000000000', new_id, 'authenticated', 'authenticated',
            'admin@admin', crypt('admin', gen_salt('bf')), now(),
            '{"provider":"email","providers":["email"]}', '{"full_name":"admin"}',
            now(), now(), '', '', '', '');
    insert into auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
    values (gen_random_uuid(), new_id, 'admin@admin', 'email',
            jsonb_build_object('sub', new_id::text, 'email', 'admin@admin', 'email_verified', true),
            now(), now(), now());
  end if;
end $$;

update public.profiles set
  role = 'admin', full_name = 'admin', position = 'Адміністратор',
  filial = 'Вінниця', phone = '+380674334333', email = 'admin@admin'
where id = (select id from auth.users where email = 'admin@admin');

-- ------------------------------------------------ ОЧІКУВАНІ ПРОФІЛІ МЕНЕДЖЕРІВ
-- Адмін заводить акаунт у Supabase Auth (Add user) з цією поштою → тригер
-- handle_new_user бере ПІБ/телефон/філію звідси, а не лишає порожній профіль.
create table if not exists public.pending_profiles (
  email     text primary key,
  full_name text not null,
  phone     text,
  filial    text not null default 'Вінниця',
  position  text default 'Менеджер з прямих продажів',
  role      text not null default 'manager' check (role in ('manager','admin'))
);
alter table public.pending_profiles enable row level security;
drop policy if exists pending_profiles_admin on public.pending_profiles;
create policy pending_profiles_admin on public.pending_profiles for all
  using (public.is_admin()) with check (public.is_admin());

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare pp public.pending_profiles%rowtype;
begin
  select * into pp from public.pending_profiles where lower(email) = lower(new.email);
  insert into public.profiles (id, email, full_name, phone, filial, position, role)
  values (new.id, new.email,
          coalesce(pp.full_name, new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)),
          pp.phone, coalesce(pp.filial, 'Вінниця'), coalesce(pp.position, 'Менеджер з прямих продажів'), coalesce(pp.role, 'manager'))
  on conflict (id) do nothing;
  return new;
end $$;

insert into public.pending_profiles (email, full_name, phone, filial) values
  ('dmytro.osadchuk@pa.ua',       'Осадчук Дмитро',        '+380966777877', 'Вінниця'),
  ('oleksandr.velhus@pa.ua',      'Вельгус Олександр',     '+380674308108', 'Вінниця'),
  ('mykola.maksymenko@pa.ua',     'Максименко Микола',     '+380984606896', 'Вінниця'),
  ('kostiantyn.podolynnyi@pa.ua', 'Подолинний Костянтин',  '+380935566508', 'Вінниця'),
  ('mykhailo.martyniuk@pa.ua',    'Мартинюк Михайло',      '+380676538347', 'Хмельницький'),
  ('illia.tymtsias@pa.ua',        'Тимцясь Ілля',          '+380971044255', 'Хмельницький'),
  ('andrii.kichura@pa.ua',        'Кічура Андрій',         '+380978699266', 'Львів'),
  ('pavlo.boichuk@pa.ua',         'Бойчук Павло',          '+380673534523', 'Львів'),
  ('yurii.dublianko@pa.ua',       'Дублянко Юрій',         '+380670080883', 'Львів'),
  ('mariia.olesenko@pa.ua',       'Олесенко Марія',        '+380930502017', 'Київ'),
  ('andrushchak@pa.ua',           'Андрущак Сергій',       '+380632600827', 'Вінниця'),
  ('ihor.usatiuk@pa.ua',          'Усатюк Ігор',           null,            'Вінниця'),
  ('valerii.prydryk@pa.ua',       'Придрик Валерій',       null,            'Хмельницький')
on conflict (email) do update set full_name = excluded.full_name, phone = excluded.phone, filial = excluded.filial;

-- Комерційна функція = адмін
insert into public.pending_profiles (email, full_name, phone, filial, position, role)
values ('commerce@pa.ua', 'Комерційна функція', '+380674334333', 'Вінниця', 'Комерційна функція', 'admin')
on conflict (email) do update set role = 'admin', position = 'Комерційна функція', phone = excluded.phone;
update public.profiles set role = 'admin', position = 'Комерційна функція' where lower(email) = 'commerce@pa.ua';

-- Якщо акаунт уже існує, а профіль ще порожній — дозаповнити
update public.profiles p set full_name = pp.full_name, phone = pp.phone, filial = pp.filial
from public.pending_profiles pp
where lower(p.email) = lower(pp.email) and (p.full_name = '' or p.full_name = split_part(p.email, '@', 1));

-- ------------------------------------------------ НАЦІНКА УЗЕ (30.08.2026)
-- Коефіцієнт комерційної функції зберігається в uze_prices.markup_k і менеджерам не видимий:
-- прямого читання uze_prices у менеджерів немає, вони читають view uze_catalog з кінцевою ціною.
alter table public.uze_prices add column if not exists markup_k numeric not null default 1.10 check (markup_k >= 1);
drop policy if exists uze_prices_read on public.uze_prices;   -- раніше читали всі авторизовані
create or replace view public.uze_catalog as
  select uze_id, brand, model, kind, kw, kwh, cooling, incoterm, included, warranty, sort,
         round((case when vat_in then price_eur else price_eur * 1.2 end) * markup_k, 2) as price_eur
  from public.uze_prices where active;
grant select on public.uze_catalog to authenticated;
revoke select on public.uze_catalog from anon;
-- Huawei не продаємо
update public.uze_prices set active = false where uze_id = 'UZE-HW-241';

-- ------------------------------------------------ ПРОФІЛІ: корпоративні номери (30.08.2026)
insert into public.pending_profiles (email, full_name, phone, filial, position) values
  ('valerii.prydryk@pa.ua',       'Придрик Валерій',       '+380674977181', 'Хмельницький', 'Менеджер з прямих продажів'),
  ('andrii.kichura@pa.ua',        'Кічура Андрій',         '+380632600632', 'Львів',        'Менеджер з прямих продажів'),
  ('yurii.dublianko@pa.ua',       'Дублянко Юрій',         '+380635832721', 'Львів',        'Менеджер з прямих продажів'),
  ('mykhailo.martyniuk@pa.ua',    'Мартинюк Михайло',      '+380631897096', 'Хмельницький', 'Менеджер з прямих продажів'),
  ('mariia.olesenko@pa.ua',       'Олесенко Марія',        '+380632600639', 'Київ',         'Менеджер з прямих продажів'),
  ('mykola.maksymenko@pa.ua',     'Максименко Микола',     '+380632600568', 'Вінниця',      'Менеджер з прямих продажів'),
  ('kostiantyn.podolynnyi@pa.ua', 'Подолинний Костянтин',  '+380674770922', 'Вінниця',      'Менеджер з прямих продажів'),
  ('dmytro.osadchuk@pa.ua',       'Осадчук Дмитро',        '+380674950867', 'Вінниця',      'Менеджер з прямих продажів'),
  ('oleksandr.velhus@pa.ua',      'Вельгус Олександр',     '+380674308108', 'Вінниця',      'Менеджер з прямих продажів')
on conflict (email) do update set full_name = excluded.full_name, phone = excluded.phone, filial = excluded.filial, position = excluded.position;
update public.profiles p set full_name = pp.full_name, phone = pp.phone, filial = pp.filial, position = pp.position
from public.pending_profiles pp where lower(p.email) = lower(pp.email) and p.role = 'manager';
