/* 予約データの保存先（Supabase）
   Supabase の Project Settings → API（または Connect）にある
   「Project URL」と「Publishable key（anon public key）」を貼る。
   null のままだと、予約ページは送信せず（デモ）、管理画面はサンプルデータで表示する。
   ※ Publishable key は公開してよい鍵。service_role / secret key は絶対に貼らないこと。 */
window.WA_BACKEND = null;
// 例：window.WA_BACKEND = { url: "https://xxxxxxxx.supabase.co", key: "sb_publishable_xxxxxxxx" };
