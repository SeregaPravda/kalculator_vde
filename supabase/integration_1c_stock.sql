-- ============================================================================
-- Склад з 1С: номенклатура, залишки, собівартість (27.10.2026)
--
-- Таблиця stock_1c уже існувала, тому структуру не міняємо, лише додаємо
-- три службові колонки для логіки оновлення. Ключ лишається складений:
-- (item_code, warehouse) — одна позиція унікальна в межах складу.
--
-- Як працює оновлення:
--   · усі позиції одного вивантаження позначені спільним sync_id;
--   · режим 'full' = повний знімок. Після останньої пачки позиції, яких
--     у знімку не було, гасяться: active = false, qty = 0. Нічого не
--     видаляється, історія лишається;
--   · режим 'delta' = часткове оновлення, чіпає лише передані позиції;
--   · до 2000 позицій в одному запиті. Для складу на 1000 позицій це один
--     запит, пачки не потрібні.
-- ============================================================================

-- ---- 1. Службові колонки до наявної таблиці -----------------------------
alter table public.stock_1c add column if not exists active    boolean not null default true;
alter table public.stock_1c add column if not exists last_sync text;
alter table public.stock_1c add column if not exists raw       jsonb;
alter table public.stock_1c add column if not exists price     numeric(14,2);   -- ціна з 1С, окремо від собівартості
alter table public.stock_1c add column if not exists currency  text not null default 'UAH';

create index if not exists stock_1c_active_idx   on public.stock_1c (active, item_name);
create index if not exists stock_1c_category_idx on public.stock_1c (category);

-- ---- 2. Журнал вивантажень ----------------------------------------------
create table if not exists public.stock_1c_sync (
  sync_id        text primary key,
  mode           text not null default 'full' check (mode in ('full','delta')),
  chunks_total   integer,
  chunks_done    integer not null default 0,
  items_received integer not null default 0,
  deactivated    integer,
  started_at     timestamptz not null default now(),
  finished_at    timestamptz,
  sent_by        uuid references public.profiles(id) on delete set null
);

alter table public.stock_1c      enable row level security;
alter table public.stock_1c_sync enable row level security;

-- Склад бачить лише адмін: у ньому собівартість.
drop policy if exists stock_1c_admin on public.stock_1c;
create policy stock_1c_admin on public.stock_1c for all
  using (public.is_admin()) with check (public.is_admin());
drop policy if exists stock_1c_sync_admin on public.stock_1c_sync;
create policy stock_1c_sync_admin on public.stock_1c_sync for all
  using (public.is_admin()) with check (public.is_admin());

-- ---- 3. Приймання вивантаження ------------------------------------------
create or replace function public.ingest_1c_stock(p_payload jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid        uuid := auth.uid();
  r_role     text;
  v_sync     text;
  v_mode     text;
  v_chunk    integer;
  v_total    integer;
  v_items    jsonb;
  it         jsonb;
  n_items    integer := 0;
  n_off      integer := 0;
  v_finished boolean := false;
  i          integer := 0;
begin
  if uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  select role into r_role from public.profiles where id = uid;
  if r_role is distinct from 'service' then
    raise exception 'forbidden: only service account may ingest' using errcode = '42501';
  end if;
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'payload must be a json object';
  end if;
  if pg_column_size(p_payload) > 2000000 then
    raise exception 'payload too large (max 2 MB), send fewer items per chunk';
  end if;

  v_sync := nullif(trim(coalesce(p_payload->>'sync_id', '')), '');
  if v_sync is null then
    raise exception 'sync_id is required';
  end if;
  v_mode := lower(coalesce(nullif(trim(coalesce(p_payload->>'mode','')), ''), 'full'));
  if v_mode not in ('full','delta') then
    raise exception 'mode must be full or delta';
  end if;
  v_chunk := coalesce(nullif(p_payload->>'chunk','')::integer, 1);
  v_total := coalesce(nullif(p_payload->>'chunks_total','')::integer, 1);
  v_items := coalesce(p_payload->'items', '[]'::jsonb);
  if jsonb_typeof(v_items) <> 'array' then
    raise exception 'items must be an array';
  end if;
  if jsonb_array_length(v_items) > 2000 then
    raise exception 'too many items in one chunk (max 2000)';
  end if;

  insert into public.stock_1c_sync (sync_id, mode, chunks_total, sent_by)
  values (v_sync, v_mode, v_total, uid)
  on conflict (sync_id) do update set chunks_total = coalesce(excluded.chunks_total, stock_1c_sync.chunks_total);

  for it in select * from jsonb_array_elements(v_items) loop
    i := i + 1;
    if nullif(trim(coalesce(it->>'item_code','')), '') is null then
      raise exception 'item_code is required in item %', i;
    end if;
    if nullif(trim(coalesce(it->>'item_name','')), '') is null then
      raise exception 'item_name is required in item %', i;
    end if;
    insert into public.stock_1c (item_code, item_name, category, power_kw, qty, unit,
                                 warehouse, price, currency, cost_uah, active, last_sync, raw, synced_at)
    values (it->>'item_code', it->>'item_name',
            nullif(it->>'category',''),
            nullif(it->>'power_kw','')::numeric,
            coalesce(nullif(it->>'qty','')::numeric, 0),
            nullif(it->>'unit',''),
            coalesce(nullif(trim(coalesce(it->>'warehouse','')), ''), 'основний'),
            nullif(it->>'price','')::numeric,
            coalesce(nullif(it->>'currency',''), 'UAH'),
            nullif(it->>'cost_uah','')::numeric,
            true, v_sync, it, now())
    on conflict (item_code, warehouse) do update set
      item_name = excluded.item_name, category = excluded.category,
      power_kw = excluded.power_kw, qty = excluded.qty, unit = excluded.unit,
      price = excluded.price, currency = excluded.currency,
      cost_uah = excluded.cost_uah, active = true, last_sync = excluded.last_sync,
      raw = excluded.raw, synced_at = now();
    n_items := n_items + 1;
  end loop;

  update public.stock_1c_sync
     set chunks_done = chunks_done + 1, items_received = items_received + n_items
   where sync_id = v_sync;

  -- остання пачка повного знімка: гасимо те, чого в ньому не було
  if v_mode = 'full' and v_chunk >= v_total then
    update public.stock_1c
       set active = false, qty = 0, synced_at = now()
     where active and last_sync is distinct from v_sync;
    get diagnostics n_off = row_count;
    update public.stock_1c_sync
       set finished_at = now(), deactivated = n_off
     where sync_id = v_sync;
    v_finished := true;
  end if;

  return jsonb_build_object(
    'ok', true, 'sync_id', v_sync, 'mode', v_mode,
    'chunk', v_chunk, 'chunks_total', v_total,
    'items', n_items, 'finished', v_finished,
    'deactivated', case when v_finished then n_off else null end
  );
end $$;

revoke all on function public.ingest_1c_stock(jsonb) from public, anon;
grant execute on function public.ingest_1c_stock(jsonb) to authenticated;

-- ---- 4. Статус вивантаження ---------------------------------------------
create or replace function public.ingest_1c_stock_status(p_sync_id text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid    uuid := auth.uid();
  r_role text;
  s      public.stock_1c_sync%rowtype;
  n_act  integer; n_all integer;
begin
  if uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  select role into r_role from public.profiles where id = uid;
  if r_role not in ('service','admin') then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  if p_sync_id is null then
    select * into s from public.stock_1c_sync order by started_at desc limit 1;
  else
    select * into s from public.stock_1c_sync where sync_id = p_sync_id;
  end if;

  select count(*) filter (where active), count(*) into n_act, n_all from public.stock_1c;

  if s.sync_id is null then
    return jsonb_build_object('found', false, 'items_active', n_act, 'items_total', n_all);
  end if;
  return jsonb_build_object('found', true, 'sync_id', s.sync_id, 'mode', s.mode,
    'chunks_done', s.chunks_done, 'chunks_total', s.chunks_total,
    'items_received', s.items_received, 'deactivated', s.deactivated,
    'started_at', s.started_at, 'finished_at', s.finished_at,
    'items_active', n_act, 'items_total', n_all);
end $$;

revoke all on function public.ingest_1c_stock_status(text) from public, anon;
grant execute on function public.ingest_1c_stock_status(text) to authenticated;
