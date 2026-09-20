-- ============================================================================
-- Каталог АКБ з ціною за штуку (20.09.2026)
--
-- Навіщо: ставка $/кВт·год розраховувалась на великі СЕС. На малих станціях
-- 6–10 кВт з батареєю 16 кВт·год вона дає 5 467 $ за накопичення, тоді як
-- специфікація 1С по SE-F16-С показує 94 210,50 грн за шафу (≈ 2 100 $).
-- Тому для моделей з каталогу ціна береться за штуку: закупка × націнка.
-- Ставка $/кВт·год лишається як запасний варіант, коли модель не обрана.
--
-- Ціни постачальника й націнку бачить лише комерційна функція (staff).
-- Менеджер отримує з battery_catalog() тільки перелік моделей та ємність.
-- ============================================================================
create table if not exists public.battery_models (
  model_id   text primary key,
  brand      text not null,
  model      text not null,
  kwh        numeric(8,2) not null,            -- ємність одного блока
  voltage    text not null default 'lv',       -- lv | hv (для підпису в КП)
  price_usd  numeric(12,2) not null,           -- ціна постачальника за 1 шт
  vat_in     boolean not null default true,    -- чи включено ПДВ у price_usd
  markup_k   numeric(6,3) not null default 1.10,
  max_units  integer default 32,
  active     boolean not null default true,
  sort       integer default 100,
  source     text,
  updated_at timestamptz default now(),
  updated_by uuid references public.profiles(id) on delete set null
);
alter table public.battery_models enable row level security;

drop policy if exists battery_models_staff_read on public.battery_models;
create policy battery_models_staff_read on public.battery_models for select using (public.is_staff());
drop policy if exists battery_models_admin_write on public.battery_models;
create policy battery_models_admin_write on public.battery_models for all
  using (public.is_admin()) with check (public.is_admin());

-- Перелік моделей для калькулятора: без цін
create or replace function public.battery_catalog()
returns table (model_id text, brand text, model text, kwh numeric, voltage text, max_units integer, sort integer)
language sql stable security definer set search_path = public as $$
  select model_id, brand, model, kwh, voltage, max_units, sort
  from public.battery_models
  where active and auth.uid() is not null
  order by sort, kwh;
$$;
revoke all on function public.battery_catalog() from public, anon;
grant execute on function public.battery_catalog() to authenticated;

-- Кінцева ціна однієї шафи для КП (з ПДВ). Використовує calculate_quote.
create or replace function public.battery_unit_price(p_model text)
returns numeric language sql stable security definer set search_path = public as $$
  select round(price_usd * (case when vat_in then 1 else 1.2 end) * markup_k, 2)
  from public.battery_models where model_id = p_model and active;
$$;
revoke all on function public.battery_unit_price(text) from public, anon;

insert into public.battery_models (model_id, brand, model, kwh, voltage, price_usd, vat_in, markup_k, max_units, sort, source) values
  ('deye-se-f16', 'Deye', 'SE-F16 / SE-F16 C', 16.08, 'lv', 1900, true, 1.10, 32, 10,
   'Закупка зі слів комерційної функції 20.09.2026. Звірено зі специфікаціями 1С: 94 210,50 грн за шт (Гарбуз, Згодько).'),
  ('deye-rw-f16', 'Deye', 'RW-F16 (настінна)', 16.08, 'lv', 1900, true, 1.10, 16, 20,
   'Ціна прийнята як у SE-F16 — уточнити в комерційної функції.')
on conflict (model_id) do nothing;
