-- 運用機能：運休・ブロック設定／欠航時の一斉連絡
-- schema.sql・mail.sql・staff_booking.sql の後に、SQL Editor に全文を貼って「Run」（何度実行しても壊れません）

-- ── 運休・ブロック（点検日・他の貸切など、予約を受けない日時） ─────────────
create table if not exists public.wa_blocks (
  id          bigint generated always as identity primary key,
  date        date not null,
  all_day     boolean not null default true,
  from_t      time,
  to_t        time,
  reason      text not null default '',
  created_by  text not null default '',
  created_at  timestamptz not null default now(),
  check (all_day or (from_t is not null and to_t is not null and to_t > from_t))
);
create index if not exists wa_blocks_date on public.wa_blocks (date);

alter table public.wa_blocks enable row level security;
drop policy if exists wa_blocks_read on public.wa_blocks;
create policy wa_blocks_read on public.wa_blocks for select to authenticated using (public.wa_is_staff());
revoke all on public.wa_blocks from anon;
revoke insert, update, delete on public.wa_blocks from authenticated;
grant select on public.wa_blocks to authenticated;

-- スタッフがブロックを追加
create or replace function public.wa_block_add(p jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare
  v_who text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_d   date; v_all boolean; v_f time; v_t time; v_id bigint;
begin
  if not public.wa_is_staff() then return json_build_object('ok', false, 'error', 'forbidden'); end if;
  begin
    v_d   := (p ->> 'date')::date;
    v_all := coalesce((p ->> 'all_day')::boolean, true);
    v_f   := nullif(p ->> 'from_t', '')::time;
    v_t   := nullif(p ->> 'to_t', '')::time;
  exception when others then return json_build_object('ok', false, 'error', 'invalid'); end;
  if v_d is null then return json_build_object('ok', false, 'error', 'invalid'); end if;
  if not v_all and (v_f is null or v_t is null or v_t <= v_f) then return json_build_object('ok', false, 'error', 'invalid'); end if;
  insert into public.wa_blocks (date, all_day, from_t, to_t, reason, created_by)
  values (v_d, v_all, case when v_all then null else v_f end, case when v_all then null else v_t end, left(coalesce(p ->> 'reason', ''), 200), v_who)
  returning id into v_id;
  return json_build_object('ok', true, 'id', v_id);
end $$;

-- スタッフがブロックを解除
create or replace function public.wa_block_del(p_id bigint) returns json
language plpgsql security definer set search_path = public as $$
begin
  if not public.wa_is_staff() then return json_build_object('ok', false, 'error', 'forbidden'); end if;
  delete from public.wa_blocks where id = p_id;
  return json_build_object('ok', true);
end $$;

-- 空き確認（予約ページ）：予約に加えてブロックもふさがっている時間として返す（理由は返さない）
create or replace function public.wa_busy(p_from date, p_to date)
returns table (date date, busy_from time, busy_to time)
language sql stable security definer set search_path = public as $$
  select * from (
    select b.date,
           (b.time - make_interval(mins => s.turnover_min))::time,
           (b.end_time + make_interval(mins => s.turnover_min))::time
    from public.wa_bookings b, public.wa_settings s
    where b.status <> 'cancelled'
      and b.date between p_from and least(p_to, p_from + 200)
    union all
    select k.date,
           case when k.all_day then time '00:00' else k.from_t end,
           case when k.all_day then time '23:59:59' else k.to_t end
    from public.wa_blocks k
    where k.date between p_from and least(p_to, p_from + 200)
  ) x
  order by 1, 2;
$$;

-- 予約ページからの申込は、ブロックした日時には入れさせない（画面で選べないようにしているが念のため）
-- 管理画面からの登録（source = 'staff'）は画面で警告を出したうえで入れられる
create or replace function public.wa_block_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(new.source, 'web') = 'web' and exists (
    select 1 from public.wa_blocks k
    where k.date = new.date and (k.all_day or (k.from_t < new.end_time and k.to_t > new.time))
  ) then
    raise exception 'blocked';
  end if;
  return new;
end $$;
drop trigger if exists wa_block_guard on public.wa_bookings;
create trigger wa_block_guard before insert on public.wa_bookings for each row execute function public.wa_block_guard();

-- ── 欠航・運航変更の一斉連絡 ─────────────────────────────────────
-- 選んだ予約のお客様へ、スタッフが書いた文面でメールを送る（お客様の言語で日本語／英語を出し分け）
-- 文面の {name} {date} {time} はお客様ごとに置き換える
-- p_cancel = true なら、あわせて状態を「キャンセル」にする（通常のキャンセルメールは重ねて送らない）
create or replace function public.wa_notice(p_refs text[], p_subject_ja text, p_body_ja text, p_subject_en text, p_body_en text, p_cancel boolean)
returns json
language plpgsql security definer set search_path = public as $$
declare
  v_who  text := lower(coalesce(auth.jwt() ->> 'email', ''));
  b      public.wa_bookings;
  en     boolean;
  v_sub  text; v_body text; v_html text; v_sign text;
  n_sent int := 0; n_skip int := 0; n_cx int := 0;
begin
  if not public.wa_is_staff() then return json_build_object('ok', false, 'error', 'forbidden'); end if;
  if coalesce(array_length(p_refs, 1), 0) = 0 or array_length(p_refs, 1) > 50 then return json_build_object('ok', false, 'error', 'invalid'); end if;

  perform set_config('wa.skip_cancel_mail', '1', true);

  for b in select * from public.wa_bookings where ref = any(p_refs) order by date, time loop
    en := b.lang = 'en';
    if coalesce(trim(b.email), '') = '' then
      n_skip := n_skip + 1;
    else
      v_sub  := case when en then coalesce(nullif(p_subject_en, ''), p_subject_ja) else p_subject_ja end;
      v_body := case when en then coalesce(nullif(p_body_en, ''), p_body_ja) else p_body_ja end;
      v_sub  := replace(replace(replace(v_sub,  '{name}', b.name), '{date}', public.wa_fdate(b.date, en)), '{time}', to_char(b.time, 'HH24:MI'));
      v_body := replace(replace(replace(v_body, '{name}', b.name), '{date}', public.wa_fdate(b.date, en)), '{time}', to_char(b.time, 'HH24:MI'));
      v_sign := case when en then 'Waldorf Astoria Osaka × StarCraft — Private River Cruise' else 'ウォルドーフ・アストリア大阪 × スタークラフト　プライベートクルーズ' end;
      v_html := '<!doctype html><html><body style="margin:0;padding:0;background:#f4f1ec">'
        || '<div style="max-width:560px;margin:0 auto;padding:32px 20px;font-family:''Helvetica Neue'',Arial,''Hiragino Sans'',''Noto Sans JP'',sans-serif;color:#1d2433">'
        || '<div style="font-size:11px;letter-spacing:.28em;color:#8a8476">WALDORF ASTORIA OSAKA × STARCRAFT</div>'
        || '<div style="background:#fff;margin-top:14px;padding:28px 26px;border-top:3px solid #1d2433">'
        || '<div style="display:inline-block;font-size:11px;letter-spacing:.12em;padding:3px 10px;border:1px solid #b89b5e;color:#8c6f33">'
        || case when en then 'NOTICE' else '運航のお知らせ' end || '</div>'
        || '<h1 style="font-size:19px;font-weight:500;margin:14px 0 16px;line-height:1.5">' || public.wa_h(v_sub) || '</h1>'
        || '<p style="font-size:14px;line-height:1.95;margin:0">' || replace(public.wa_h(v_body), chr(10), '<br>') || '</p>'
        || '<p style="font-size:12px;color:#8a8476;margin:22px 0 0">' || case when en then 'Booking reference: ' else '予約番号：' end || public.wa_h(b.ref) || '</p>'
        || '</div><div style="font-size:11px;color:#8a8476;margin-top:16px;line-height:1.8">' || public.wa_h(v_sign) || '</div></div></body></html>';
      perform public.wa_send_mail(b.ref, 'notice', b.email, v_sub,
        v_html, v_body || (chr(10)||chr(10)) || case when en then 'Booking reference: ' else '予約番号：' end || b.ref || (chr(10)||'――――――――――'||chr(10)) || v_sign || chr(10));
      n_sent := n_sent + 1;
    end if;
    insert into public.wa_log (ref, who, action, detail) values (b.ref, v_who, 'notice', left(p_subject_ja, 200));
    if p_cancel and b.status <> 'cancelled' then
      update public.wa_bookings set status = 'cancelled' where ref = b.ref;
      n_cx := n_cx + 1;
    end if;
  end loop;
  return json_build_object('ok', true, 'sent', n_sent, 'skipped', n_skip, 'cancelled', n_cx);
end $$;

-- メールのきっかけ：一斉連絡でキャンセルにしたときは、通常のキャンセルメールを重ねて送らない
create or replace function public.wa_mail_trg() returns trigger
language plpgsql security definer set search_path = public as $$
declare s public.wa_settings;
begin
  begin
    select * into s from public.wa_settings where id = 1;
    if tg_op = 'INSERT' then
      if new.source = 'staff' then
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
      elsif new.status = 'cancelled' and coalesce(current_setting('wa.skip_cancel_mail', true), '') <> '1' then
        perform public.wa_mail_booking(new, 'cancelled');
      end if;
    end if;
  exception when others then
    null;
  end;
  return null;
end $$;

-- ── 権限 ───────────────────────────────────────────────────
revoke all on function public.wa_block_add(jsonb), public.wa_block_del(bigint), public.wa_block_guard(),
  public.wa_notice(text[], text, text, text, text, boolean), public.wa_mail_trg() from public, anon;
revoke all on function public.wa_block_guard(), public.wa_mail_trg() from authenticated;
grant execute on function public.wa_block_add(jsonb), public.wa_block_del(bigint),
  public.wa_notice(text[], text, text, text, text, boolean) to authenticated;
revoke all on function public.wa_busy(date, date) from public;
grant execute on function public.wa_busy(date, date) to anon, authenticated;
