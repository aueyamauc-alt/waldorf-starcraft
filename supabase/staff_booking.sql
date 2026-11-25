-- 管理画面からの予約登録（電話・フロントで受けた予約など）
-- schema.sql・mail.sql の後に、SQL Editor に全文を貼って「Run」（何度実行しても壊れません）

-- ── どこから入った予約か ──────────────────────────────────────
alter table public.wa_bookings add column if not exists source text not null default 'web';
do $$ begin
  alter table public.wa_bookings add constraint wa_bookings_source check (source in ('web','staff'));
exception when duplicate_object then null;
end $$;

-- ── スタッフが予約を入れる ──────────────────────────────────────
-- お客様の予約ページとの違い
--   ・締切（lead_days）なし。当日〜1年先まで入れられる
--   ・出航時刻は自由（5分単位まで）
--   ・メール・電話は空でもよい（お名前だけ必須）
--   ・最初から「確定」にできる。お客様へのメールは送るかどうかを選べる
--   ・時間が重なるときは 'taken' を返す。重なりを承知で入れるときは force = true
create or replace function public.wa_staff_create_booking(p jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare
  s        public.wa_settings;
  v_who    text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_date   date;
  v_time   time;
  v_min    int;
  v_end    time;
  v_ref    text;
  v_status text := case when p ->> 'status' = 'confirmed' then 'confirmed' else 'new' end;
  v_today  date := (now() at time zone 'Asia/Tokyo')::date;
  v_items  jsonb := coalesce(p -> 'unagi_items', '[]'::jsonb);
  v_email  text := lower(trim(coalesce(p ->> 'email', '')));
  v_clash  json;
begin
  if not public.wa_is_staff() then
    return json_build_object('ok', false, 'error', 'forbidden');
  end if;
  select * into s from public.wa_settings where id = 1;

  begin
    v_date := (p ->> 'date')::date;
    v_time := (p ->> 'time')::time;
    v_min  := (p ->> 'minutes')::int;
  exception when others then
    return json_build_object('ok', false, 'error', 'invalid', 'field', 'date');
  end;
  if v_date is null or v_time is null then return json_build_object('ok', false, 'error', 'invalid', 'field', 'date'); end if;
  if v_min is null or v_min not between 30 and 240 then return json_build_object('ok', false, 'error', 'invalid', 'field', 'minutes'); end if;
  if v_time + make_interval(mins => v_min) < v_time then return json_build_object('ok', false, 'error', 'invalid', 'field', 'time'); end if; -- 日付をまたぐ
  v_end := v_time + make_interval(mins => v_min);
  if v_date < v_today or v_date > v_today + 366 then return json_build_object('ok', false, 'error', 'date'); end if;
  if coalesce(trim(p ->> 'name'), '') = '' then return json_build_object('ok', false, 'error', 'invalid', 'field', 'name'); end if;
  if v_email <> '' and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return json_build_object('ok', false, 'error', 'invalid', 'field', 'email'); end if;
  if coalesce((p ->> 'guests')::int, 0) not between 1 and 8 then return json_build_object('ok', false, 'error', 'invalid', 'field', 'guests'); end if;
  if jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) > 20 then return json_build_object('ok', false, 'error', 'invalid', 'field', 'unagi'); end if;

  perform pg_advisory_xact_lock(hashtext('wa_' || v_date::text));
  select json_build_object('ref', b.ref, 'name', b.name, 'time', to_char(b.time, 'HH24:MI'), 'end_time', to_char(b.end_time, 'HH24:MI'), 'status', b.status)
    into v_clash
  from public.wa_bookings b
  where b.date = v_date and b.status <> 'cancelled'
    and b.time - make_interval(mins => s.turnover_min) < v_end
    and b.end_time + make_interval(mins => s.turnover_min) > v_time
  order by b.time limit 1;
  if v_clash is not null and coalesce((p ->> 'force')::boolean, false) is not true then
    return json_build_object('ok', false, 'error', 'taken', 'clash', v_clash, 'turnover_min', s.turnover_min);
  end if;

  loop
    v_ref := 'WA-' || to_char(now() at time zone 'Asia/Tokyo', 'YYMMDD') || '-'
             || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 4));
    exit when not exists (select 1 from public.wa_bookings where ref = v_ref);
  end loop;

  -- お客様へのメールを送るか（メールのトリガーがこの値を見る。このトランザクションの中だけ有効）
  perform set_config('wa.staff_mail', case when coalesce((p ->> 'send_mail')::boolean, false) and v_email <> '' then '1' else '0' end, true);

  insert into public.wa_bookings (
    ref, type, plan, plan_name, minutes, date, time, end_time, pier, pier_name, req_from, req_to,
    guests, options, unagi_items, price_plan, price_total, price_note,
    name, room, email, tel, checkin, checkout, note, lang, status, memo, source, updated_by
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
    left(trim(p ->> 'name'), 120), left(coalesce(p ->> 'room', ''), 20), left(v_email, 200), left(coalesce(p ->> 'tel', ''), 40),
    nullif(p ->> 'checkin', '')::date, nullif(p ->> 'checkout', '')::date,
    left(coalesce(p ->> 'note', ''), 2000), case when p ->> 'lang' = 'en' then 'en' else 'ja' end,
    v_status, left(coalesce(p ->> 'memo', ''), 2000), 'staff', v_who
  );
  insert into public.wa_log (ref, who, action, detail)
    values (v_ref, v_who, 'created', '管理画面から登録' || case when v_status = 'confirmed' then '（確定）' else '' end
                                     || case when v_clash is not null then '／時間の重なりを承知で登録' else '' end);
  return json_build_object('ok', true, 'ref', v_ref);
end $$;

-- ── メールのきっかけ（管理画面から入れた予約に対応） ───────────────────
create or replace function public.wa_mail_trg() returns trigger
language plpgsql security definer set search_path = public as $$
declare s public.wa_settings;
begin
  begin
    select * into s from public.wa_settings where id = 1;
    if tg_op = 'INSERT' then
      if new.source = 'staff' then
        -- スタッフが入れた予約：スタッフ通知は出さない。お客様へは「送る」を選んだときだけ
        if coalesce(current_setting('wa.staff_mail', true), '') = '1' then
          perform public.wa_mail_booking(new, case when new.status = 'confirmed' then 'confirmed' else 'received' end);
        end if;
      else
        perform public.wa_mail_booking(new, 'received');
        if s.mail_notify <> '' then perform public.wa_mail_booking(new, 'notify'); end if;
      end if;
    elsif new.status is distinct from old.status then
      if new.status = 'confirmed' and not exists (
           select 1 from public.wa_mail m
           where m.ref = new.ref and m.kind = 'confirmed'
             and m.at > coalesce((select max(c.at) from public.wa_mail c where c.ref = new.ref and c.kind = 'cancelled'), '-infinity')) then
        perform public.wa_mail_booking(new, 'confirmed');
      elsif new.status = 'cancelled' then
        perform public.wa_mail_booking(new, 'cancelled');
      end if;
    end if;
  exception when others then
    null;  -- メールの不具合で予約の受付・状態変更を止めない
  end;
  return null;
end $$;
revoke all on function public.wa_mail_trg() from public, anon, authenticated;

-- ── 権限 ───────────────────────────────────────────────────
revoke all on function public.wa_staff_create_booking(jsonb) from public, anon;
grant execute on function public.wa_staff_create_booking(jsonb) to authenticated;
