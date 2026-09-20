-- ============================================================================
-- Керівник філії бачить тільки менеджерів своєї філії (20.09.2026).
-- Виняток — керівник з розвитку регіонів (посада містить «регіон»): усі філії.
-- Обмеження серверне: і зведення kp_stats, і читання журналу kp_log.
-- ============================================================================
create or replace function public.kp_scope_ok(target_filial text)
returns boolean language sql stable security definer set search_path = public as $$
  select case
    when public.is_admin() then true
    else exists (
      select 1 from public.profiles me
      where me.id = auth.uid()
        and (me.role <> 'head'
             or coalesce(me.position, '') ~* 'регіон'
             or me.filial is not distinct from target_filial))
  end;
$$;
revoke all on function public.kp_scope_ok(text) from public, anon;
grant execute on function public.kp_scope_ok(text) to authenticated;

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
  where public.is_staff() and pr.role = 'manager' and public.kp_scope_ok(pr.filial)
  group by pr.id, pr.full_name, pr.filial
  order by count(k.id) desc, pr.full_name
$$;
-- Журнал КП: свої рядки, адмін — усе, керівник філії — лише менеджери своєї філії
drop policy if exists kp_log_staff_select on public.kp_log;
create policy kp_log_staff_select on public.kp_log for select using (
  manager_id = auth.uid()
  or (public.is_staff()
      and public.kp_scope_ok((select p.filial from public.profiles p where p.id = kp_log.manager_id)))
);
