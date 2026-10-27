-- ============================================================================
-- Технічний акаунт для 1С (27.10.2026)
--
-- Призначення: 1С сама надсилає JSON у Supabase. Supabase нікуди не ходить
-- і нічого в 1С не питає — тільки приймає.
--
-- Принцип: окрема роль 'service'. Такий акаунт не бачить ні цін, ні ставок,
-- ні журналу КП, ні профілів інших людей. Єдине, що він уміє — викликати
-- ingest_1c() і покласти JSON у приймальну таблицю inbox_1c.
-- Розбір payload у робочі таблиці — окремим кроком, уже під контролем адміна.
-- ============================================================================

-- ---- 1. Нова роль --------------------------------------------------------
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check
  check (role in ('manager','admin','head','service'));
alter table public.pending_profiles drop constraint if exists pending_profiles_role_check;
alter table public.pending_profiles add constraint pending_profiles_role_check
  check (role in ('manager','admin','head','service'));

-- Профіль підтягнеться автоматично, щойно адмін створить користувача з цією поштою
insert into public.pending_profiles (email, full_name, phone, filial, position, role) values
  ('integration.1c@pa.ua', 'Інтеграція 1С', null, 'Вінниця', 'Технічний акаунт', 'service')
on conflict (email) do update set
  full_name = excluded.full_name, position = excluded.position, role = excluded.role;

-- ---- 2. Приймальна таблиця ----------------------------------------------
create table if not exists public.inbox_1c (
  id           bigserial primary key,
  received_at  timestamptz not null default now(),
  source       text not null default '1c',
  doc_type     text,                       -- вид документа: spec | invoice | price | ...
  doc_id       text,                       -- номер у 1С; якщо повторити — оновиться, не задвоїться
  payload      jsonb not null,
  status       text not null default 'new' check (status in ('new','processed','error')),
  processed_at timestamptz,
  error        text,
  sent_by      uuid references public.profiles(id) on delete set null
);
create index if not exists inbox_1c_status_idx on public.inbox_1c (status, received_at desc);
create index if not exists inbox_1c_doc_idx    on public.inbox_1c (source, doc_type, doc_id);

alter table public.inbox_1c enable row level security;
-- Напряму таблицю не чіпає ніхто, крім адміна. 1С пише тільки через RPC.
drop policy if exists inbox_1c_admin on public.inbox_1c;
create policy inbox_1c_admin on public.inbox_1c for all
  using (public.is_admin()) with check (public.is_admin());

-- ---- 3. Точка входу для 1С ----------------------------------------------
create or replace function public.ingest_1c(p_doc_type text, p_doc_id text, p_payload jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid     uuid := auth.uid();
  r_role  text;
  v_type  text := nullif(trim(coalesce(p_doc_type, '')), '');
  v_docid text := nullif(trim(coalesce(p_doc_id, '')), '');
  new_id  bigint;
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
    raise exception 'payload too large';
  end if;

  -- Повторне надсилання того самого документа оновлює рядок, а не множить його
  if v_docid is not null then
    update public.inbox_1c
       set payload = p_payload, received_at = now(), status = 'new',
           processed_at = null, error = null, sent_by = uid
     where source = '1c' and doc_type is not distinct from v_type and doc_id = v_docid
     returning id into new_id;
  end if;

  if new_id is null then
    insert into public.inbox_1c (doc_type, doc_id, payload, sent_by)
    values (v_type, v_docid, p_payload, uid)
    returning id into new_id;
  end if;

  return jsonb_build_object('ok', true, 'id', new_id, 'doc_id', v_docid, 'received_at', now());
end $$;

revoke all on function public.ingest_1c(text, text, jsonb) from public, anon;
grant execute on function public.ingest_1c(text, text, jsonb) to authenticated;

-- ---- 4. Перегляд для адміна ---------------------------------------------
create or replace function public.inbox_1c_recent(p_limit integer default 50)
returns table (id bigint, received_at timestamptz, doc_type text, doc_id text,
               status text, bytes integer, preview text)
language sql stable security definer set search_path = public as $$
  select id, received_at, doc_type, doc_id, status,
         pg_column_size(payload) as bytes,
         left(payload::text, 300) as preview
  from public.inbox_1c
  where public.is_admin()
  order by received_at desc
  limit greatest(1, least(coalesce(p_limit, 50), 500));
$$;
revoke all on function public.inbox_1c_recent(integer) from public, anon;
grant execute on function public.inbox_1c_recent(integer) to authenticated;
