-- ウォルドーフ・アストリア大阪 × スタークラフト 予約管理
-- Supabase の SQL Editor に全文を貼って「Run」を一度押すだけ（何度実行しても壊れません）

-- ── 設定（1行だけ） ──────────────────────────────────────────
create table if not exists public.wa_settings (
  id            int primary key default 1 check (id = 1),
  turnover_min  int not null default 30 check (turnover_min between 0 and 180), -- 便と便の間に空ける時間（分）
  lead_days     int not null default 4  check (lead_days between 0 and 30)      -- 何日前までオンライン予約を受けるか
);
insert into public.wa_settings (id) values (1) on conflict (id) do nothing;

-- ── スタッフ（ここに登録したメールアドレスだけが管理画面を使える） ──
create table if not exists public.wa_staff (
  email    text primary key check (email = lower(email)),
  name     text not null default '',
  org      text not null default 'company' check (org in ('hotel','company')), -- hotel＝ホテル / company＝弊社
  added_at timestamptz not null default now()
);

create or replace function public.wa_is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.wa_staff where email = lower(coalesce(auth.jwt() ->> 'email', '')));
$$;

create or replace function public.wa_me() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('email', email, 'name', name, 'org', org)
  from public.wa_staff where email = lower(coalesce(auth.jwt() ->> 'email', ''));
$$;

-- ── 予約 ────────────────────────────────────────────────────
create table if not exists public.wa_bookings (
  ref          text primary key,                         -- WA-YYMMDD-XXXX
  created_at   timestamptz not null default now(),
  type         text not null check (type in ('reservation','pier_request')), -- pier_request＝その他の船着場のリクエスト
  plan         text not null,
  plan_name    text not null,
  minutes      int  not null check (minutes between 30 and 240),
  date         date not null,
  time         time not null,
  end_time     time not null,
  pier         text,
  pier_name    text not null default '',
  req_from     text not null default '',
  req_to       text not null default '',
  guests       int  not null check (guests between 1 and 8),
  options      text[] not null default '{}',
  unagi_items  jsonb not null default '[]',               -- [{id,name,qty,price}]
  price_plan   int,
  price_total  int,                                       -- お客様画面に表示された合計（税込・円）
  price_note   text not null default '',
  name         text not null,
  room         text not null default '',
  email        text not null,
  tel          text not null,
  checkin      date,
  checkout     date,
  note         text not null default '',
  lang         text not null default 'ja',
  status       text not null default 'new' check (status in ('new','confirmed','done','cancelled')),
  memo         text not null default '',
  updated_at   timestamptz not null default now(),
  updated_by   text not null default 'guest'
);
create index if not exists wa_bookings_date on public.wa_bookings (date, time);
create index if not exists wa_bookings_status on public.wa_bookings (status);

-- ── 変更履歴 ────────────────────────────────────────────────
create table if not exists public.wa_log (
  id      bigint generated always as identity primary key,
  ref     text not null references public.wa_bookings(ref) on delete cascade,
  at      timestamptz not null default now(),
  who     text not null,
  action  text not null,
  detail  text not null default ''
);
create index if not exists wa_log_ref on public.wa_log (ref, at);

create or replace function public.wa_touch() returns trigger
language plpgsql security definer set search_path = public as $$
declare who text := coalesce(auth.jwt() ->> 'email', 'system');
begin
  new.updated_at := now();
  new.updated_by := who;
  if new.status is distinct from old.status then
    insert into public.wa_log (ref, who, action, detail) values (new.ref, who, 'status', old.status || ' → ' || new.status);
  end if;
  if new.memo is distinct from old.memo then
    insert into public.wa_log (ref, who, action, detail) values (new.ref, who, 'memo', left(new.memo, 300));
  end if;
  return new;
end $$;
drop trigger if exists wa_touch on public.wa_bookings;
create trigger wa_touch before update on public.wa_bookings for each row execute function public.wa_touch();

-- スタッフが変えてよいのは 状態・メモ だけ（他の列はお客様の申込内容のまま）
create or replace function public.wa_guard() returns trigger
language plpgsql as $$
begin
  if (to_jsonb(new) - 'status' - 'memo' - 'updated_at' - 'updated_by')
     is distinct from (to_jsonb(old) - 'status' - 'memo' - 'updated_at' - 'updated_by') then
    raise exception '状態とメモ以外は変更できません';
  end if;
  return new;
end $$;
drop trigger if exists wa_guard on public.wa_bookings;
create trigger wa_guard before update on public.wa_bookings for each row execute function public.wa_guard();

-- ── 空き確認（予約ページから。個人情報は返さない） ─────────────────
-- 返すのは「船がふさがっている時間帯」（前後に turnover_min を足したもの）
create or replace function public.wa_busy(p_from date, p_to date)
returns table (date date, busy_from time, busy_to time)
language sql stable security definer set search_path = public as $$
  select b.date,
         (b.time - make_interval(mins => s.turnover_min))::time,
         (b.end_time + make_interval(mins => s.turnover_min))::time
  from public.wa_bookings b, public.wa_settings s
  where b.status <> 'cancelled'
    and b.date between p_from and least(p_to, p_from + 200)
  order by 1, 2;
$$;

-- ── お客様の申込（予約ページから。テーブルへは直接書かせない） ─────────
create or replace function public.wa_create_booking(p jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare
  s        public.wa_settings;
  v_date   date;
  v_time   time;
  v_min    int;
  v_end    time;
  v_ref    text;
  v_today  date := (now() at time zone 'Asia/Tokyo')::date;
  v_items  jsonb := coalesce(p -> 'unagi_items', '[]'::jsonb);
begin
  -- ボット対策（画面に見えない入力欄に何か入っていたら、受けたふりをして捨てる）
  if coalesce(p ->> 'hp', '') <> '' then
    return json_build_object('ok', true, 'ref', 'WA-000000-0000');
  end if;

  select * into s from public.wa_settings where id = 1;
  begin
    v_date := (p ->> 'date')::date;
    v_time := (p ->> 'time')::time;
    v_min  := (p ->> 'minutes')::int;
  exception when others then
    return json_build_object('ok', false, 'error', 'invalid');
  end;
  if v_date is null or v_time is null or v_min is null or v_min not between 30 and 240 then
    return json_build_object('ok', false, 'error', 'invalid');
  end if;
  v_end := v_time + make_interval(mins => v_min);

  if v_date < v_today + s.lead_days or v_date > v_today + 366 then
    return json_build_object('ok', false, 'error', 'date');
  end if;
  if coalesce(trim(p ->> 'name'), '') = '' or coalesce(p ->> 'email', '') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'
     or coalesce(trim(p ->> 'tel'), '') = '' then
    return json_build_object('ok', false, 'error', 'invalid');
  end if;
  if coalesce((p ->> 'guests')::int, 0) not between 1 and 8 then
    return json_build_object('ok', false, 'error', 'invalid');
  end if;
  if jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) > 20 then
    return json_build_object('ok', false, 'error', 'invalid');
  end if;

  -- 船は1隻：同じ日に時間が重なる予約（前後の準備時間を含む）があれば受けない
  perform pg_advisory_xact_lock(hashtext('wa_' || v_date::text));
  if exists (
    select 1 from public.wa_bookings b
    where b.date = v_date and b.status <> 'cancelled'
      and b.time - make_interval(mins => s.turnover_min) < v_end
      and b.end_time + make_interval(mins => s.turnover_min) > v_time
  ) then
    return json_build_object('ok', false, 'error', 'taken');
  end if;

  loop
    v_ref := 'WA-' || to_char(now() at time zone 'Asia/Tokyo', 'YYMMDD') || '-'
             || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 4));
    exit when not exists (select 1 from public.wa_bookings where ref = v_ref);
  end loop;

  insert into public.wa_bookings (
    ref, type, plan, plan_name, minutes, date, time, end_time, pier, pier_name, req_from, req_to,
    guests, options, unagi_items, price_plan, price_total, price_note,
    name, room, email, tel, checkin, checkout, note, lang
  ) values (
    v_ref,
    case when p ->> 'type' = 'pier_request' then 'pier_request' else 'reservation' end,
    left(coalesce(p ->> 'plan', ''), 40), left(coalesce(p ->> 'plan_name', ''), 120), v_min,
    v_date, v_time, v_end,
    nullif(left(coalesce(p ->> 'pier', ''), 40), ''), left(coalesce(p ->> 'pier_name', ''), 120),
    left(coalesce(p ->> 'req_from', ''), 200), left(coalesce(p ->> 'req_to', ''), 200),
    (p ->> 'guests')::int,
    coalesce(array(select left(x, 40) from jsonb_array_elements_text(coalesce(p -> 'options', '[]'::jsonb)) x limit 10), '{}'),
    v_items,
    nullif(p ->> 'price_plan', '')::int, nullif(p ->> 'price_total', '')::int, left(coalesce(p ->> 'price_note', ''), 60),
    left(trim(p ->> 'name'), 120), left(coalesce(p ->> 'room', ''), 20), lower(left(p ->> 'email', 200)), left(p ->> 'tel', 40),
    nullif(p ->> 'checkin', '')::date, nullif(p ->> 'checkout', '')::date,
    left(coalesce(p ->> 'note', ''), 2000), case when p ->> 'lang' = 'en' then 'en' else 'ja' end
  );
  insert into public.wa_log (ref, who, action, detail) values (v_ref, 'guest', 'created', '');
  return json_build_object('ok', true, 'ref', v_ref);
end $$;

-- ── 権限 ───────────────────────────────────────────────────
alter table public.wa_settings enable row level security;
alter table public.wa_staff    enable row level security;
alter table public.wa_bookings enable row level security;
alter table public.wa_log      enable row level security;

drop policy if exists wa_settings_read on public.wa_settings;
create policy wa_settings_read on public.wa_settings for select to authenticated using (public.wa_is_staff());
drop policy if exists wa_staff_read on public.wa_staff;
create policy wa_staff_read on public.wa_staff for select to authenticated using (public.wa_is_staff());
drop policy if exists wa_bookings_read on public.wa_bookings;
create policy wa_bookings_read on public.wa_bookings for select to authenticated using (public.wa_is_staff());
drop policy if exists wa_bookings_update on public.wa_bookings;
create policy wa_bookings_update on public.wa_bookings for update to authenticated
  using (public.wa_is_staff()) with check (public.wa_is_staff());
drop policy if exists wa_log_read on public.wa_log;
create policy wa_log_read on public.wa_log for select to authenticated using (public.wa_is_staff());

revoke all on public.wa_settings, public.wa_staff, public.wa_bookings, public.wa_log from anon;
revoke insert, delete on public.wa_bookings from authenticated;
revoke insert, update, delete on public.wa_log, public.wa_staff, public.wa_settings from authenticated;
grant select, update on public.wa_bookings to authenticated;
grant select on public.wa_log, public.wa_staff, public.wa_settings to authenticated;

revoke all on function public.wa_create_booking(jsonb), public.wa_busy(date, date), public.wa_is_staff(), public.wa_me() from public;
grant execute on function public.wa_create_booking(jsonb) to anon, authenticated;
grant execute on function public.wa_busy(date, date)      to anon, authenticated;
grant execute on function public.wa_is_staff()            to authenticated;
grant execute on function public.wa_me()                  to authenticated;

-- ── スタッフ登録（例：メールアドレスと名前・所属を書き換えて実行） ─────────
-- insert into public.wa_staff (email, name, org) values ('you@example.com', '担当者名', 'company');
-- insert into public.wa_staff (email, name, org) values ('concierge@example.com', 'ホテル コンシェルジュ', 'hotel');
