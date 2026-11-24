-- ウォルドーフ・アストリア大阪 × スタークラフト 予約メールの自動送信（Resend）
-- schema.sql のあとに、SQL Editor に全文を貼って「Run」（何度実行しても壊れません）
--
-- 送るメール
--   received  … お客様へ「ご予約リクエストを受け付けました」（予約が入った時）
--   notify    … スタッフへ「新しい予約が入りました」（mail_notify に宛先がある時だけ）
--   confirmed … お客様へ「ご予約が確定しました」（管理画面で「確定」にした時。同じ予約に2通は送らない）
--   cancelled … お客様へ「ご予約はキャンセルとなりました」（管理画面で「キャンセル」にした時）
-- お客様のメールは、予約ページで選んだ言語（日本語／英語）で送ります。
--
-- Resend の API キーは Vault に保存する（このファイルには書かない）：
--   select vault.create_secret('re_xxxxxxxx', 'resend_api_key');
-- キーが無い間は送信せず、wa_mail に「no_key」と記録するだけ。予約の受付は止まりません。

create extension if not exists pg_net;

-- ── 設定 ──────────────────────────────────────────────────
alter table public.wa_settings
  add column if not exists mail_enabled     boolean not null default true,
  add column if not exists mail_from        text not null default 'Waldorf Astoria Osaka x StarCraft <onboarding@resend.dev>',
  add column if not exists mail_reply_to    text not null default '',  -- お客様が返信した時の宛先
  add column if not exists mail_notify      text not null default '',  -- 新規予約の通知先（カンマ区切りで複数可）
  add column if not exists mail_redirect_to text not null default '',  -- テスト用：入れると全メールをこの宛先に送る
  add column if not exists site_url         text not null default 'https://aueyamauc-alt.github.io/waldorf-starcraft/';

-- ── 送信記録 ────────────────────────────────────────────────
create table if not exists public.wa_mail (
  id         bigint generated always as identity primary key,
  ref        text references public.wa_bookings(ref) on delete cascade,
  at         timestamptz not null default now(),
  kind       text not null,
  to_addr    text not null,
  subject    text not null,
  request_id bigint,
  note       text not null default ''
);
create index if not exists wa_mail_ref on public.wa_mail (ref, at);

-- ── 部品 ────────────────────────────────────────────────────
create or replace function public.wa_h(t text) returns text
language sql immutable as $$
  select replace(replace(replace(replace(coalesce(t, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;');
$$;

create or replace function public.wa_fdate(d date, en boolean) returns text
language sql immutable as $$
  select case when en
    then (array['Sun','Mon','Tue','Wed','Thu','Fri','Sat'])[extract(dow from d)::int + 1] || ', '
         || extract(day from d)::int || ' '
         || (array['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'])[extract(month from d)::int] || ' '
         || extract(year from d)::int
    else extract(year from d)::int || '年' || extract(month from d)::int || '月' || extract(day from d)::int || '日（'
         || (array['日','月','火','水','木','金','土'])[extract(dow from d)::int + 1] || '）'
  end;
$$;

create or replace function public.wa_yen(n int) returns text
language sql immutable as $$
  select case when n is null then '—' else '¥' || to_char(n, 'FM999,999,999') end;
$$;

-- ── 送信（Resend API） ──────────────────────────────────────
create or replace function public.wa_send_mail(p_ref text, p_kind text, p_to text, p_subject text, p_html text, p_text text)
returns void language plpgsql security definer set search_path = public as $$
declare
  s     public.wa_settings;
  v_key text;
  v_to  text := p_to;
  v_sub text := p_subject;
  v_id  bigint;
  v_body jsonb;
begin
  select * into s from public.wa_settings where id = 1;
  if not s.mail_enabled or coalesce(trim(p_to), '') = '' then return; end if;
  if s.mail_redirect_to <> '' then
    v_sub := '[TEST → ' || p_to || '] ' || p_subject;
    v_to  := s.mail_redirect_to;
  end if;

  begin
    select decrypted_secret into v_key from vault.decrypted_secrets where name = 'resend_api_key' limit 1;
  exception when others then v_key := null;
  end;
  if v_key is null then
    insert into public.wa_mail (ref, kind, to_addr, subject, note) values (p_ref, p_kind, v_to, v_sub, 'no_key');
    return;
  end if;

  v_body := jsonb_build_object(
    'from', s.mail_from,
    'to', (select jsonb_agg(trim(x)) from unnest(string_to_array(v_to, ',')) x where trim(x) <> ''),
    'subject', v_sub, 'html', p_html, 'text', p_text);
  if s.mail_reply_to <> '' then v_body := v_body || jsonb_build_object('reply_to', s.mail_reply_to); end if;

  -- pg_net はトランザクションが確定してから送る（予約の保存が失敗したらメールも出ない）
  select net.http_post(
    url := 'https://api.resend.com/emails',
    body := v_body,
    headers := jsonb_build_object('Authorization', 'Bearer ' || v_key, 'Content-Type', 'application/json')
  ) into v_id;

  insert into public.wa_mail (ref, kind, to_addr, subject, request_id) values (p_ref, p_kind, v_to, v_sub, v_id);
  insert into public.wa_log (ref, who, action, detail) values (p_ref, 'system', 'mail', p_kind || ' → ' || p_to);
exception when others then
  begin
    insert into public.wa_mail (ref, kind, to_addr, subject, note) values (p_ref, p_kind, coalesce(v_to, ''), coalesce(v_sub, ''), left(sqlerrm, 300));
  exception when others then null;
  end;
end $$;

-- ── 文面 ────────────────────────────────────────────────────
create or replace function public.wa_mail_booking(b public.wa_bookings, p_kind text)
returns void language plpgsql security definer set search_path = public as $$
declare
  s      public.wa_settings;
  en     boolean := (b.lang = 'en' and p_kind <> 'notify');
  t_plan text; t_pier text; t_opts text; t_items text;
  rows   text[][];
  head   text; intro text; outro text; sub text; tag text;
  html   text := ''; txt text := '';
  i      int;
  sign   text;
  piers  text;
begin
  select * into s from public.wa_settings where id = 1;

  t_plan := case when en then case b.plan when 'p60' then 'Private Cruise — 60 min' when 'p90' then 'Private Cruise — 90 min'
                                          when 'dtb90' then 'Dotonbori Cruise — 90 min' else b.plan_name end
                 else b.plan_name end;
  t_pier := case
    when b.type = 'pier_request' then
      (case when en then 'Requested — Board: ' else '希望 — 乗船：' end) || coalesce(nullif(b.req_from, ''), '—')
      || (case when en then ' / Disembark: ' else '／下船：' end) || coalesce(nullif(b.req_to, ''), '—')
    when b.pier = 'dtb' then case when en then 'To be advised' else '別途ご案内' end
    when en then case b.pier when 'dojimahama' then 'Dojimahama Pier' when 'ichiba' then 'Central Wholesale Market Pier' else b.pier_name end
    else b.pier_name end;
  t_opts := (select string_agg(case o when 'wine' then case when en then 'Wine' else 'ワイン' end
                                      when 'unagi' then case when en then 'Unagi by Shibato' else '柴藤の鰻' end
                                      else o end, case when en then ', ' else '、' end)
             from unnest(b.options) o);
  t_items := (select string_agg(
                case when en then coalesce(case x ->> 'id'
                    when 'ran' then 'Osaka Mamushi — Ran' when 'sakura' then 'Osaka Mamushi — Sakura' when 'kiku' then 'Osaka Mamushi — Kiku'
                    when 'mini' then 'Mini Mamushi' when 'yawata5' then 'Yawata-maki (5 pcs)' when 'yawata3' then 'Yawata-maki (3 pcs)'
                    when 'uzakuL' then 'Uzaku (large)' when 'uzakuS' then 'Uzaku (small)' end, x ->> 'name')
                else x ->> 'name' end || ' ×' || (x ->> 'qty'), ' / ')
              from jsonb_array_elements(b.unagi_items) x);

  rows := array[
    array[case when en then 'Reference' else '受付番号' end, b.ref],
    array[case when en then 'Date' else '乗船日' end, public.wa_fdate(b.date, en)],
    array[case when en then 'Time' else '時間' end,
          to_char(b.time, 'HH24:MI') || case when en then ' departure → ' else ' 出航 → ' end || to_char(b.end_time, 'HH24:MI')
          || case when en then ' return (approx.)' else ' 下船予定' end],
    array[case when en then 'Cruise' else 'プラン' end, t_plan],
    array[case when en then 'Pier' else '船着場' end, t_pier],
    array[case when en then 'Guests' else '人数' end, b.guests || case when en then '' else '名' end],
    array[case when en then 'Options' else 'オプション' end, coalesce(t_opts, case when en then 'None' else 'なし' end)]
  ];
  if t_items is not null then
    rows := rows || array[array[case when en then 'Unagi order' else '鰻のご注文' end, t_items]];
  end if;
  rows := rows || array[
    array[case when en then 'Total (as shown)' else '合計（目安）' end,
          public.wa_yen(b.price_total) || case when b.price_note <> '' then case when en then ' + options TBC' else ' ' || b.price_note end else '' end],
    array[case when en then 'Name' else 'お名前' end, b.name || case when en then '' else ' 様' end],
    array[case when en then 'Room' else '部屋番号' end, coalesce(nullif(b.room, ''), '—')]
  ];
  if b.note <> '' then
    rows := rows || array[array[case when en then 'Requests' else 'ご要望' end, b.note]];
  end if;
  if p_kind = 'notify' then
    rows := rows || array[array['メール', b.email], array['電話', b.tel]];
  end if;

  piers := s.site_url || case when en then '#en' else '' end;

  if p_kind = 'received' then
    tag := case when en then 'Request received' else 'ご予約リクエスト受付' end;
    head := case when en then 'Thank you — we have received your request' else 'ご予約リクエストを承りました' end;
    intro := case when en
      then 'Dear ' || b.name || E',\n\nThank you for your cruise request. Our staff will check availability and send you a separate email to confirm your reservation.\nPlease note that your reservation is not confirmed yet.'
      else b.name || E' 様\n\nこのたびはクルーズをお申し込みいただき、ありがとうございます。\n以下の内容でご予約リクエストを承りました。スタッフが空き状況を確認のうえ、あらためて「ご予約確定」のメールをお送りいたします。\nこの時点ではまだご予約は確定しておりませんので、ご了承ください。' end;
    outro := case when en
      then E'Details of fees and payment will be provided by our staff.\nCruises may be cancelled due to river levels or weather; we will contact you if this affects your booking.'
      else E'料金・お支払い方法の詳細は、スタッフよりご案内いたします。\n河川の水位や天候により欠航となる場合がございます。その際はスタッフよりご連絡いたします。' end;
  elsif p_kind = 'confirmed' then
    tag := case when en then 'Reservation confirmed' else 'ご予約確定' end;
    head := case when en then 'Your cruise is confirmed' else 'ご予約が確定しました' end;
    intro := case when en
      then 'Dear ' || b.name || E',\n\nWe are pleased to confirm your reservation as follows. We look forward to welcoming you on board.'
      else b.name || E' 様\n\nお待たせいたしました。以下の内容でご予約が確定いたしました。\n当日のお越しを心よりお待ちしております。' end;
    outro := case
      when b.pier = 'dtb' or b.type = 'pier_request' then case when en
        then E'Our staff will contact you separately with your boarding and disembarking points.\nPlease arrive at the pier at least 10 minutes before departure.'
        else E'乗船・下船場所は、スタッフより別途ご案内いたします。\n当日はご出発の10分前までに船着場へお越しください。' end
      else case when en
        then 'Please arrive at ' || t_pier || E' at least 10 minutes before departure.\nPhotos and a map of the pier: ' || piers
        else '当日はご出発の10分前までに「' || t_pier || E'」へお越しください。\n船着場の写真・地図：' || piers end
    end || case when en
        then E'\nCruises may be cancelled due to river levels or weather; we will contact you if this affects your booking.'
        else E'\n河川の水位や天候により欠航となる場合がございます。その際はスタッフよりご連絡いたします。' end;
  elsif p_kind = 'cancelled' then
    tag := case when en then 'Reservation cancelled' else 'ご予約キャンセル' end;
    head := case when en then 'Your reservation has been cancelled' else 'ご予約はキャンセルとなりました' end;
    intro := case when en
      then 'Dear ' || b.name || E',\n\nThe following reservation has been cancelled.'
      else b.name || E' 様\n\n以下のご予約はキャンセルとなりました。' end;
    outro := case when en
      then 'If you have any questions, please contact us quoting your reference number.'
      else 'ご不明な点がございましたら、受付番号を添えてお問い合わせください。' end;
  elsif p_kind = 'notify' then
    tag := '新規予約';
    head := '新しい予約リクエストが入りました';
    intro := case when b.type = 'pier_request' then 'その他の船着場のリクエストです。運航可否を確認してください。' else '内容を確認し、管理画面で「確定」にしてください（お客様に確定メールが届きます）。' end;
    outro := '管理画面：' || s.site_url || 'staff.html';
  else
    return;
  end if;

  if p_kind <> 'notify' then
    outro := outro || case
      when s.mail_reply_to <> '' then case when en then E'\n\nFor enquiries, simply reply to this email.' else E'\n\nお問い合わせは、このメールにご返信ください。' end
      else '' end
      || case when en then E'\nIf you did not make this request, please disregard this email.' else E'\nこのメールにお心当たりのない場合は、お手数ですが破棄してください。' end;
  end if;

  sign := case when en then 'Waldorf Astoria Osaka × StarCraft — Private River Cruise' else 'ウォルドーフ・アストリア大阪 × スタークラフト　プライベートクルーズ' end;
  sub := case when p_kind = 'notify'
    then '【新規予約】' || public.wa_fdate(b.date, false) || ' ' || to_char(b.time, 'HH24:MI') || ' ' || b.plan_name || ' ' || b.name || '様 ' || b.guests || '名（' || b.ref || '）'
    when en then tag || ': ' || public.wa_fdate(b.date, true) || ' ' || to_char(b.time, 'HH24:MI') || ' (' || b.ref || ')'
    else '【' || tag || '】' || public.wa_fdate(b.date, false) || ' ' || to_char(b.time, 'HH24:MI') || ' ' || b.plan_name || '（' || b.ref || '）' end;

  -- テキスト版
  txt := intro || E'\n\n';
  for i in 1 .. array_length(rows, 1) loop
    txt := txt || '■ ' || rows[i][1] || E'\n  ' || replace(rows[i][2], E'\n', E'\n  ') || E'\n';
  end loop;
  txt := txt || E'\n' || outro || E'\n\n――――――――――\n' || sign || E'\n';

  -- HTML版
  for i in 1 .. array_length(rows, 1) loop
    html := html || '<tr><th style="text-align:left;vertical-align:top;padding:10px 16px 10px 0;border-bottom:1px solid #e6e2da;color:#8a8476;font-weight:400;font-size:12px;white-space:nowrap">'
         || public.wa_h(rows[i][1]) || '</th><td style="padding:10px 0;border-bottom:1px solid #e6e2da;font-size:14px;color:#1d2433">'
         || replace(public.wa_h(rows[i][2]), E'\n', '<br>') || '</td></tr>';
  end loop;
  html := '<!doctype html><html><body style="margin:0;padding:0;background:#f4f1ec">'
    || '<div style="max-width:560px;margin:0 auto;padding:32px 20px;font-family:''Helvetica Neue'',Arial,''Hiragino Sans'',''Noto Sans JP'',sans-serif;color:#1d2433">'
    || '<div style="font-size:11px;letter-spacing:.28em;color:#8a8476">WALDORF ASTORIA OSAKA × STARCRAFT</div>'
    || '<div style="background:#fff;margin-top:14px;padding:28px 26px;border-top:3px solid #1d2433">'
    || '<div style="display:inline-block;font-size:11px;letter-spacing:.12em;padding:3px 10px;border:1px solid #b89b5e;color:#8c6f33">' || public.wa_h(tag) || '</div>'
    || '<h1 style="font-size:20px;font-weight:500;margin:14px 0 16px;line-height:1.5">' || public.wa_h(head) || '</h1>'
    || '<p style="font-size:14px;line-height:1.9;margin:0 0 20px">' || replace(public.wa_h(intro), E'\n', '<br>') || '</p>'
    || '<table style="width:100%;border-collapse:collapse;border-top:1px solid #e6e2da">' || html || '</table>'
    || '<p style="font-size:13px;line-height:1.9;margin:20px 0 0;color:#4a5060">' || replace(public.wa_h(outro), E'\n', '<br>') || '</p>'
    || '</div><div style="font-size:11px;color:#8a8476;margin-top:16px;line-height:1.8">' || public.wa_h(sign) || '</div></div></body></html>';

  perform public.wa_send_mail(b.ref,
    p_kind,
    case when p_kind = 'notify' then s.mail_notify else b.email end,
    sub, html, txt);
end $$;

-- ── きっかけ（予約が入った／状態が変わった） ─────────────────────
create or replace function public.wa_mail_trg() returns trigger
language plpgsql security definer set search_path = public as $$
declare s public.wa_settings;
begin
  begin
    select * into s from public.wa_settings where id = 1;
    if tg_op = 'INSERT' then
      perform public.wa_mail_booking(new, 'received');
      if s.mail_notify <> '' then perform public.wa_mail_booking(new, 'notify'); end if;
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
drop trigger if exists wa_mail on public.wa_bookings;
create trigger wa_mail after insert or update of status on public.wa_bookings
  for each row execute function public.wa_mail_trg();

-- ── 管理画面用：その予約の送信記録と結果 ───────────────────────────
create or replace function public.wa_mail_status(p_ref text)
returns table (at timestamptz, kind text, to_addr text, subject text, result text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.wa_is_staff() then return; end if;
  return query
    select m.at, m.kind, m.to_addr, m.subject,
      case
        when m.note = 'no_key' then '未送信（送信設定がまだです）'
        when m.note <> '' then 'エラー：' || m.note
        when r.id is null then '送信済み'
        when r.status_code between 200 and 299 then '送信済み'
        else 'エラー：' || coalesce(r.status_code::text, '') || ' ' || left(coalesce(r.error_msg, r.content, ''), 160)
      end
    from public.wa_mail m
    left join net._http_response r on r.id = m.request_id
    where m.ref = p_ref
    order by m.at;
end $$;

-- ── 権限 ───────────────────────────────────────────────────
alter table public.wa_mail enable row level security;
drop policy if exists wa_mail_read on public.wa_mail;
create policy wa_mail_read on public.wa_mail for select to authenticated using (public.wa_is_staff());
revoke all on public.wa_mail from anon;
revoke insert, update, delete on public.wa_mail from authenticated;
grant select on public.wa_mail to authenticated;

revoke all on function public.wa_send_mail(text, text, text, text, text, text) from public, anon, authenticated;
revoke all on function public.wa_mail_booking(public.wa_bookings, text) from public, anon, authenticated;
revoke all on function public.wa_mail_trg() from public, anon, authenticated;
revoke all on function public.wa_mail_status(text) from public, anon;
grant execute on function public.wa_mail_status(text) to authenticated;
