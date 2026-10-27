-- ============================================================================
-- Документи з 1С: шапка + позиції (27.10.2026)
--
-- Чому саме так:
--   · один запит на документ — немає порядку «спочатку шапка, потім позиції»
--     і немає напівзаписаних документів, усе в одній транзакції;
--   · повторне надсилання того самого doc_id оновлює документ, а не падає
--     з помилкою дубля;
--   · 1С не читає і не пише таблиці напряму, тільки через функцію, тому
--     структуру таблиць можна міняти, не чіпаючи інтеграцію;
--   · права прив'язані до ролі 'service', а не до UUID конкретного акаунта:
--     акаунт можна перестворити, інтеграція не зламається.
-- ============================================================================

-- ---- 1. Таблиці ----------------------------------------------------------
create table if not exists public.doc_1c (
  doc_id       text primary key,                 -- номер документа в 1С
  doc_type     text not null default 'spec',     -- spec | invoice | price | order
  doc_date     date,
  counterparty text,
  manager      text,
  total        numeric(14,2),
  currency     text not null default 'UAH',
  note         text,
  raw          jsonb,                            -- документ як прийшов, для розбору потім
  received_at  timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  sent_by      uuid references public.profiles(id) on delete set null
);

create table if not exists public.doc_item_1c (
  id        bigserial primary key,
  doc_id    text not null references public.doc_1c(doc_id) on delete cascade,
  line_no   integer,
  item_code text,
  item_name text not null,
  unit      text,
  qty       numeric(14,3) not null default 1,
  price     numeric(14,2),
  amount    numeric(14,2),
  raw       jsonb
);
create index if not exists doc_item_1c_doc_idx on public.doc_item_1c (doc_id);
create index if not exists doc_1c_type_idx     on public.doc_1c (doc_type, received_at desc);

alter table public.doc_1c      enable row level security;
alter table public.doc_item_1c enable row level security;

-- Напряму таблиці доступні лише адміну. 1С працює виключно через функції нижче.
drop policy if exists doc_1c_admin on public.doc_1c;
create policy doc_1c_admin on public.doc_1c for all
  using (public.is_admin()) with check (public.is_admin());
drop policy if exists doc_item_1c_admin on public.doc_item_1c;
create policy doc_item_1c_admin on public.doc_item_1c for all
  using (public.is_admin()) with check (public.is_admin());

-- ---- 2. Приймання документа ---------------------------------------------
create or replace function public.ingest_1c_doc(p_payload jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid      uuid := auth.uid();
  r_role   text;
  v_doc    text;
  v_type   text;
  v_items  jsonb;
  it       jsonb;
  n_items  integer := 0;
  existed  boolean;
  i        integer := 0;
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
    raise exception 'payload too large (max 2 MB)';
  end if;

  v_doc := nullif(trim(coalesce(p_payload->>'doc_id', '')), '');
  if v_doc is null then
    raise exception 'doc_id is required';
  end if;
  v_type  := coalesce(nullif(trim(coalesce(p_payload->>'doc_type', '')), ''), 'spec');
  v_items := coalesce(p_payload->'items', '[]'::jsonb);
  if jsonb_typeof(v_items) <> 'array' then
    raise exception 'items must be an array';
  end if;

  select true into existed from public.doc_1c where doc_id = v_doc;

  insert into public.doc_1c (doc_id, doc_type, doc_date, counterparty, manager,
                             total, currency, note, raw, sent_by)
  values (v_doc, v_type,
          nullif(p_payload->>'doc_date','')::date,
          nullif(p_payload->>'counterparty',''),
          nullif(p_payload->>'manager',''),
          nullif(p_payload->>'total','')::numeric,
          coalesce(nullif(p_payload->>'currency',''), 'UAH'),
          nullif(p_payload->>'note',''),
          p_payload, uid)
  on conflict (doc_id) do update set
    doc_type = excluded.doc_type, doc_date = excluded.doc_date,
    counterparty = excluded.counterparty, manager = excluded.manager,
    total = excluded.total, currency = excluded.currency, note = excluded.note,
    raw = excluded.raw, updated_at = now(), sent_by = excluded.sent_by;

  -- позиції завжди перезаписуються цілком: документ приходить як єдине ціле
  delete from public.doc_item_1c where doc_id = v_doc;
  for it in select * from jsonb_array_elements(v_items) loop
    i := i + 1;
    if nullif(trim(coalesce(it->>'item_name','')), '') is null then
      raise exception 'item_name is required in item %', i;
    end if;
    insert into public.doc_item_1c (doc_id, line_no, item_code, item_name, unit, qty, price, amount, raw)
    values (v_doc,
            coalesce(nullif(it->>'line_no','')::integer, i),
            nullif(it->>'item_code',''),
            it->>'item_name',
            nullif(it->>'unit',''),
            coalesce(nullif(it->>'qty','')::numeric, 1),
            nullif(it->>'price','')::numeric,
            nullif(it->>'amount','')::numeric,
            it);
    n_items := n_items + 1;
  end loop;

  -- сирий документ лишаємо в архіві
  insert into public.inbox_1c (doc_type, doc_id, payload, status, sent_by)
  values (v_type, v_doc, p_payload, 'processed', uid);

  return jsonb_build_object(
    'ok', true,
    'doc_id', v_doc,
    'action', case when existed then 'updated' else 'created' end,
    'items', n_items,
    'received_at', now()
  );
end $$;

revoke all on function public.ingest_1c_doc(jsonb) from public, anon;
grant execute on function public.ingest_1c_doc(jsonb) to authenticated;

-- ---- 3. Перевірка свого документа (для розробника інтеграції) -----------
-- Повертає лише факт і кількість позицій, самих даних не віддає.
create or replace function public.ingest_1c_status(p_doc_id text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid    uuid := auth.uid();
  r_role text;
  d      public.doc_1c%rowtype;
  n      integer;
begin
  if uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  select role into r_role from public.profiles where id = uid;
  if r_role not in ('service','admin') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into d from public.doc_1c where doc_id = p_doc_id;
  if not found then
    return jsonb_build_object('found', false, 'doc_id', p_doc_id);
  end if;
  select count(*) into n from public.doc_item_1c where doc_id = p_doc_id;
  return jsonb_build_object('found', true, 'doc_id', d.doc_id, 'doc_type', d.doc_type,
                            'items', n, 'received_at', d.received_at, 'updated_at', d.updated_at);
end $$;

revoke all on function public.ingest_1c_status(text) from public, anon;
grant execute on function public.ingest_1c_status(text) to authenticated;
