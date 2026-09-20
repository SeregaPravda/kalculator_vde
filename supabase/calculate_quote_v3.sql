-- ============================================================================
-- calculate_quote v3 (20.09.2026)
--   Додає battery_model: якщо менеджер обрав модель АКБ з каталогу, накопичення
--   рахується за штуками (кількість × ціна шафи), а не ставкою $/кВт·год.
--   Причина: ставка розрахована на великі СЕС і на малій станції 6–10 кВт
--   з батареєю 16 кВт·год давала 5 467 $ замість реальних ≈ 2 100 $.
--   Без обраної моделі поведінка та сама, що у v2: ставка за класом LV/HV.
-- ============================================================================
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
  inv_kw     numeric := coalesce((p->>'inverter_ac_kw')::numeric, 0);
  bcls       text := lower(coalesce(nullif(p->>'battery_class', ''), 'auto'));
  bmod       text := nullif(trim(coalesce(p->>'battery_model', '')), '');
  vatm       text := lower(coalesce(nullif(p->>'vat_mode', ''), 'with'));
  pcat       text; bcat text; balt text;
  rate_a     numeric := 0; rate_b numeric := 0; rate_alt numeric := 0;
  pv_usd     numeric := 0; bat_usd numeric := 0;
  gross      numeric := 0; alt_gross numeric := null;
  total_usd  numeric := 0; alt_usd numeric := null;
  m          public.battery_models%rowtype;
  b_units    integer := null; b_unit_usd numeric := null;
  u_id       text := p->>'uze_id';
  u_qty      integer := coalesce((p->>'uze_qty')::integer, 0);
  u_total    numeric := (p->>'uze_total_eur')::numeric;
  u_log      numeric;
  kp_no      text := nullif(trim(coalesce(p->>'kp_number', '')), '');
  res        jsonb;
begin
  if uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  adm := public.is_admin();
  if bcls not in ('auto', 'lv', 'hv') then bcls := 'auto'; end if;
  if vatm not in ('with', 'without')  then vatm := 'with'; end if;

  -- ---- СЕС: PV + накопичення
  if st in ('network','hybrid') and kwp > 0 then
    if pl not in ('roof','ground') then
      raise exception 'placement must be roof|ground';
    end if;
    pcat := case when kwp <= 30 then 'small' when kwp < 100 then 'medium' when kwp < 300 then 'large' else 'xl' end;
    select rate_usd_per_kwp into rate_a from public.pv_prices
      where system_type = st and placement = pl and power_segment = pcat;
    if rate_a is null then
      raise exception 'no pv price for %/%/%', st, pl, pcat;
    end if;
    pv_usd := kwp * rate_a;

    if st = 'hybrid' and kwh > 0 then
      if bmod is not null then
        select * into m from public.battery_models where model_id = bmod and active;
      end if;

      if m.model_id is not null and m.kwh > 0 then
        -- ---- ціна за штуку: кількість блоків округлюємо вгору під потрібну ємність
        b_units    := greatest(1, ceil(kwh / m.kwh)::integer);
        if m.max_units is not null and b_units > m.max_units then b_units := m.max_units; end if;
        b_unit_usd := round(m.price_usd * (case when m.vat_in then 1 else 1.2 end) * m.markup_k, 2);
        bat_usd    := b_units * b_unit_usd;
        kwh        := round(b_units * m.kwh, 2);
        bcat       := m.voltage;
      else
        -- ---- запасний варіант: ставка $/кВт·год за класом
        bmod := null;
        bcat := case when bcls in ('lv','hv') then bcls
                     when inv_kw < 50 then 'lv' else 'hv' end;
        balt := case when bcat = 'lv' then 'hv' else 'lv' end;
        select rate_usd_per_kwh into rate_b from public.battery_prices where capacity_segment = bcat;
        if rate_b is null then
          raise exception 'no battery price for %', bcat;
        end if;
        bat_usd := kwh * rate_b;
        select rate_usd_per_kwh into rate_alt from public.battery_prices where capacity_segment = balt;
        if rate_alt is not null then alt_gross := round(pv_usd + kwh * rate_alt); end if;
      end if;
    else
      kwh := 0;
    end if;
    gross := round(pv_usd + bat_usd);
  else
    kwp := 0; kwh := 0;
  end if;

  total_usd := case when vatm = 'without' then round(gross / 1.2) else gross end;
  alt_usd   := case when alt_gross is null then null
                    when vatm = 'without' then round(alt_gross / 1.2) else alt_gross end;
  u_log     := case when u_total is null then null
                    when vatm = 'without' then round(u_total * 1.2, 2) else u_total end;

  -- ---- лог: суму пишемо завжди З ПДВ, щоб аналітика лишалась порівнянною
  if do_log then
    if kp_no is null then kp_no := public.next_kp_number(); end if;
    insert into public.kp_log (manager_id, system_type, placement, installed_dc_kwp, battery_kwh,
                               total_price_usd, uze_id, uze_qty, uze_total_eur,
                               client_name, city, kp_number, params)
    values (uid, coalesce(st, '?'), pl, nullif(kwp, 0), nullif(kwh, 0),
            gross, u_id, nullif(u_qty, 0), u_log,
            p->>'client_name', p->>'city', kp_no,
            coalesce(p->'params', '{}'::jsonb) || jsonb_build_object(
              'vat_mode', vatm, 'battery_class', coalesce(bcat, bcls),
              'battery_model', bmod, 'battery_units', b_units, 'quoted_total_usd', total_usd));
  end if;

  res := jsonb_build_object(
    'total_price_usd', total_usd,
    'total_with_vat',  gross,
    'pv_kwp', kwp, 'battery_kwh', kwh,
    'vat_included', (vatm = 'with'),
    'vat_mode', vatm,
    'battery_segment', bcat,
    'battery_model', bmod,
    'battery_model_name', case when bmod is null then null else m.brand || ' ' || m.model end,
    'battery_units', b_units,
    'alt_battery_segment', balt,
    'alt_total_usd', alt_usd,
    'is_admin', adm,
    'logged', do_log,
    'kp_number', kp_no
  );
  -- Ставки й закупівельні ціни бачить тільки адмін
  if adm then
    res := res || jsonb_build_object('breakdown', jsonb_build_object(
      'power_segment', pcat, 'rate_usd_per_kwp', rate_a, 'pv_price_usd', round(pv_usd),
      'battery_segment', bcat, 'rate_usd_per_kwh', rate_b, 'battery_price_usd', round(bat_usd),
      'battery_unit_usd', b_unit_usd, 'battery_units', b_units
    ));
  end if;
  return res;
end $$;

revoke all on function public.calculate_quote(jsonb, boolean) from public, anon;
grant execute on function public.calculate_quote(jsonb, boolean) to authenticated;
