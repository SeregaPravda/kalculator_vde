/* Спільний шар: клієнт Supabase, перевірка сесії та ролі, навігація.
   Підключати після supabase-js (CDN) і config.js. */
/* global supabase, CONFIG */

const sb = supabase.createClient(CONFIG.SUPABASE_URL, CONFIG.SUPABASE_ANON_KEY);
const ROLE_LABEL = { manager: "Менеджер", admin: "Адмін" };

const esc = s => String(s == null ? "" : s)
  .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

function configured() {
  return CONFIG.SUPABASE_URL && !/XXXX/.test(CONFIG.SUPABASE_URL) && CONFIG.SUPABASE_ANON_KEY && CONFIG.SUPABASE_ANON_KEY !== "XXXX";
}

async function getSessionProfile() {
  const { data: { session } } = await sb.auth.getSession();
  if (!session) return null;
  const { data: profile } = await sb.from("profiles").select("*").eq("id", session.user.id).maybeSingle();
  return { session, profile: profile || null };
}

/** Гарантує вхід (і роль, якщо задана). Повертає {session, profile} або null після редиректу. */
async function requireAuth(role) {
  if (!configured()) {
    document.body.innerHTML = '<div class="wrap"><div class="alert warn">Сайт не налаштовано: заповніть js/config.js (Project URL і anon key з Supabase).</div></div>';
    return null;
  }
  const a = await getSessionProfile();
  if (!a) { location.replace("index.html"); return null; }
  if (!a.profile) {
    document.body.innerHTML = '<div class="wrap"><div class="alert warn">Для вашого акаунта ще не створено профіль. Зверніться до адміністратора.</div>' +
      '<p><a href="#" id="lo">Вийти</a></p></div>';
    document.getElementById("lo").onclick = async e => { e.preventDefault(); await sb.auth.signOut(); location.replace("index.html"); };
    return null;
  }
  if (role === "admin" && a.profile.role !== "admin") { location.replace("calculator.html"); return null; }
  renderNav(a.profile);
  sb.auth.onAuthStateChange(ev => { if (ev === "SIGNED_OUT") location.replace("index.html"); });
  return a;
}

function renderNav(profile) {
  const el = document.getElementById("nav"); if (!el) return;
  const page = (location.pathname.split("/").pop() || "calculator.html");
  const links = [["calculator.html", "Калькулятор"]];
  if (profile.role === "admin")
    links.push(["admin-prices.html", "Ціни"], ["admin-dashboard.html", "Лічильник КП"], ["admin-users.html", "Користувачі"]);
  el.innerHTML = `<div class="nav">
    <div class="logo">Група компаній «<span>ПРОМАВТОМАТИКА</span>»</div>
    <div class="links">${links.map(l => `<a href="${l[0]}" class="${page === l[0] ? "on" : ""}">${l[1]}</a>`).join("")}</div>
    <div class="who">${esc(profile.full_name || profile.email)} <span class="badge ${profile.role}">${ROLE_LABEL[profile.role]}</span>
      <a href="#" id="logoutBtn">Вийти</a></div></div>`;
  document.getElementById("logoutBtn").onclick = async e => {
    e.preventDefault(); await sb.auth.signOut(); location.replace("index.html");
  };
}

const fmtDate = iso => { const d = new Date(iso);
  return String(d.getDate()).padStart(2, "0") + "." + String(d.getMonth() + 1).padStart(2, "0") + "." + d.getFullYear() +
         " " + String(d.getHours()).padStart(2, "0") + ":" + String(d.getMinutes()).padStart(2, "0"); };
const nf = (n, d = 0) => (n == null || isNaN(n)) ? "—"
  : Number(n).toLocaleString("uk-UA", { minimumFractionDigits: d, maximumFractionDigits: d }).replace(/ /g, " ");
