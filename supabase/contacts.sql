-- 緊急連絡先（当日・締切後のご予約の相談先）
-- 電話番号はこのファイルに書かない（公開リポジトリのため）。値は SQL Editor で直接入れる：
--   update public.wa_settings set contacts = '[{"name":"名前","tel":"090-0000-0000"}]' where id = 1;
-- wa_settings はログインしたスタッフしか読めないので、管理画面にだけ表示される
alter table public.wa_settings add column if not exists contacts jsonb not null default '[]';
