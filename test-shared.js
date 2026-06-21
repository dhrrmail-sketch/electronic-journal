(() => {
const TEST_BETA_VERSION = "2.0.0-beta.25";
const LANG_KEY = "teacher-journal-language";
const CLOUD_CONFIG_KEY = "teacher-journal-cloud-config-v1";
const CLOUD_SESSION_KEY = "teacher-journal-cloud-session-v1";
const JOURNAL_STORAGE_KEY = "teacher-journal-v2";
const EMAILJS_KEY = "teacher-journal-emailjs-v1";
const TEST_MAIL_TEMPLATES_KEY = "teacher-journal-test-mail-templates-v1";
const TEST_PUBLIC_URL_KEY = "teacher-journal-test-public-url-v1";

const $ = id => document.getElementById(id);
const esc = (value = "") => String(value).replace(/[&<>"']/g, char => ({
  "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#039;"
}[char]));

function readJson(key, fallback = null) {
  try { return JSON.parse(localStorage.getItem(key)) ?? fallback; }
  catch { return fallback; }
}

function decodeTestLinkData() {
  const encoded = new URLSearchParams(location.search).get("test");
  if (!encoded) return {};
  try {
    const base64 = encoded.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - encoded.length % 4) % 4);
    return JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(base64), char => char.charCodeAt(0))));
  } catch { return {}; }
}
function cloudConfig() {
  const saved = readJson(CLOUD_CONFIG_KEY, {});
  if (saved?.url && saved?.key) return saved;
  const packed = decodeTestLinkData(), params = new URLSearchParams(location.search);
  const url = packed.project || params.get("project"), key = packed.key || params.get("key");
  return url && key ? { url, key } : {};
}
function cloudSession() { return readJson(CLOUD_SESSION_KEY, null); }
function cloudReady() {
  const config = cloudConfig();
  return /^https:\/\/[a-z0-9.-]+\.supabase\.co\/?$/i.test(config.url || "") &&
    String(config.key || "").length > 20;
}

async function refreshSession() {
  const config = cloudConfig(), session = cloudSession();
  if (!session?.refresh_token) throw new Error("Войдите в облако через журнал.");
  const response = await fetch(config.url.replace(/\/$/, "") + "/auth/v1/token?grant_type=refresh_token", {
    method: "POST",
    headers: { apikey: config.key, "Content-Type": "application/json" },
    body: JSON.stringify({ refresh_token: session.refresh_token })
  });
  const data = await response.json();
  if (!response.ok) throw new Error(data.message || "Сессия истекла.");
  const next = {
    access_token: data.access_token,
    refresh_token: data.refresh_token,
    user: data.user,
    expires_at: Date.now() + Math.max(30, (data.expires_in || 3600) - 30) * 1000
  };
  localStorage.setItem(CLOUD_SESSION_KEY, JSON.stringify(next));
  return next;
}

async function api(path, options = {}, auth = true, retry = true) {
  const config = cloudConfig();
  if (!cloudReady()) throw new Error("Сначала настройте облако в журнале.");
  let session = cloudSession();
  if (auth && session?.expires_at <= Date.now()) session = await refreshSession();
  const headers = {
    apikey: config.key,
    "Content-Type": "application/json",
    ...(options.headers || {})
  };
  if (auth && session?.access_token) headers.Authorization = `Bearer ${session.access_token}`;
  if (!auth) headers.Authorization = `Bearer ${config.key}`;
  const response = await fetch(config.url.replace(/\/$/, "") + path, { ...options, headers });
  if (response.status === 401 && auth && retry && session?.refresh_token) {
    await refreshSession();
    return api(path, options, auth, false);
  }
  const text = await response.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch { data = text; }
  if (!response.ok) {
    const parts = [
      data?.message,
      data?.details,
      data?.hint,
      data?.code ? `Код: ${data.code}` : "",
      typeof data === "string" ? data : ""
    ].filter(Boolean);
    throw new Error(parts.join(" — ") || `Ошибка сервера HTTP ${response.status}`);
  }
  return data;
}

function toast(text, tone = "") {
  const el = $("toast");
  if (!el) return;
  el.textContent = text;
  el.className = `toast show ${tone}`;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => el.className = "toast", 3500);
}

function isoLocal(date = new Date()) {
  const shifted = new Date(date.getTime() - date.getTimezoneOffset() * 60000);
  return shifted.toISOString().slice(0, 16);
}

function formatDateTime(value) {
  if (!value) return "—";
  const locale={ru:"ru-RU",kk:"kk-KZ",en:"en-US",ar:"ar-SA"}[localStorage.getItem(LANG_KEY)]||"ru-RU";
  return new Intl.DateTimeFormat(locale, {
    dateStyle: "medium", timeStyle: "short"
  }).format(new Date(value));
}

function randomToken() {
  return crypto.randomUUID();
}

function normalizeAnswers(value) {
  return [...new Set(Array.isArray(value) ? value : [value].filter(Boolean))].sort();
}

function journalStudents() {
  const state = readJson(JOURNAL_STORAGE_KEY, {});
  return {
    state,
    students: Array.isArray(state.students) ? state.students : [],
    groups: Array.isArray(state.groups) ? state.groups : []
  };
}

function testBaseUrl() {
  const saved = String(localStorage.getItem(TEST_PUBLIC_URL_KEY) || "").trim();
  if (saved) return new URL(saved).href;
  return new URL("./take-test.html", location.href).href;
}
function studentTestLink(token) {
  const config = cloudConfig(), url = new URL(testBaseUrl());
  const payload = JSON.stringify({
    token,
    project: config.url || "",
    key: config.key || "",
    lang: localStorage.getItem(LANG_KEY) || "ru"
  });
  const bytes = new TextEncoder().encode(payload);
  const encoded = btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
  url.searchParams.set("test", encoded);
  return url.href;
}
function testLinkData() {
  const packed = decodeTestLinkData(), params = new URLSearchParams(location.search);
  return {
    token: packed.token || params.get("token") || "",
    lang: packed.lang || params.get("lang") || ""
  };
}

window.TestBeta = {
  version: TEST_BETA_VERSION,
  $, esc, readJson, cloudConfig, cloudSession, cloudReady, api, toast,
  isoLocal, formatDateTime, randomToken, normalizeAnswers, journalStudents,
  testBaseUrl, studentTestLink, testLinkData, EMAILJS_KEY, JOURNAL_STORAGE_KEY, LANG_KEY,
  TEST_MAIL_TEMPLATES_KEY, TEST_PUBLIC_URL_KEY
};
})();
