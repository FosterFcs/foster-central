// Foster Central · confere o CNPJ do profissional na base pública da Receita e aplica o selo "MEI/CNPJ ativo".
// POST {cnpj} com o token do profissional logado. O selo só sai se:
//   - o CNPJ estiver com situação cadastral ATIVA, e
//   - o nome do perfil aparecer na razão social ou no quadro de sócios.
// Consulta BrasilAPI e, se falhar, publica.cnpj.ws. Grava pela função registrar_cnpj (chave de serviço).
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const resposta = (corpo: unknown, status = 200) =>
  new Response(JSON.stringify(corpo), { status, headers: { ...CORS, "Content-Type": "application/json" } });

const normalizar = (s: unknown) =>
  String(s ?? "").normalize("NFD").replace(/[̀-ͯ]/g, "").toUpperCase().replace(/[^A-Z ]/g, " ").replace(/\s+/g, " ").trim();
const LIGACOES = new Set(["DA", "DE", "DO", "DAS", "DOS", "E"]);

function cnpjValido(c: string) {
  if (c.length !== 14 || /^(\d)\1+$/.test(c)) return false;
  const calc = (n: number) => { let s = 0, p = n - 7; for (let i = 0; i < n; i++) { s += Number(c[i]) * p--; if (p < 2) p = 9; } const r = s % 11; return r < 2 ? 0 : 11 - r; };
  return calc(12) === Number(c[12]) && calc(13) === Number(c[13]);
}

type Consulta = { ativa: boolean; razao: string; fantasia: string; socios: string[]; situacao: string };

async function consultar(cnpj: string): Promise<Consulta | null> {
  const tentativas: Array<() => Promise<Consulta | null>> = [
    async () => {
      const r = await fetch(`https://brasilapi.com.br/api/cnpj/v1/${cnpj}`, { headers: { "User-Agent": "FosterCentral/1.0" } });
      if (!r.ok) return null;
      const d = await r.json();
      const sit = String(d.descricao_situacao_cadastral ?? d.situacao_cadastral ?? "");
      return { ativa: /ATIVA/i.test(sit), situacao: sit, razao: d.razao_social ?? "", fantasia: d.nome_fantasia ?? "",
               socios: (d.qsa ?? []).map((s: any) => s.nome_socio ?? s.nome ?? "") };
    },
    async () => {
      const r = await fetch(`https://publica.cnpj.ws/cnpj/${cnpj}`, { headers: { "User-Agent": "FosterCentral/1.0" } });
      if (!r.ok) return null;
      const d = await r.json();
      const sit = String(d.estabelecimento?.situacao_cadastral ?? "");
      return { ativa: /ATIVA/i.test(sit), situacao: sit, razao: d.razao_social ?? "", fantasia: d.estabelecimento?.nome_fantasia ?? "",
               socios: (d.socios ?? []).map((s: any) => s.nome ?? "") };
    },
  ];
  for (const t of tentativas) {
    try { const c = await t(); if (c) return c; } catch (e) { console.log(JSON.stringify({ diag: "consulta_falhou", erro: String(e) })); }
  }
  return null;
}

// nome do perfil confere se o primeiro e o último nome aparecem na razão social ou em algum sócio
function nomeConfere(nomePerfil: string, c: Consulta) {
  const partes = normalizar(nomePerfil).split(" ").filter((p) => p.length > 1 && !LIGACOES.has(p));
  if (partes.length < 2) return false;
  const primeiro = partes[0], ultimo = partes[partes.length - 1];
  return [c.razao, ...c.socios].some((alvo) => {
    const palavras = new Set(normalizar(alvo).split(" "));
    return palavras.has(primeiro) && palavras.has(ultimo);
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return resposta({ ok: false, erro: "metodo" }, 405);

  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const { data: u, error: eu } = await admin.auth.getUser(token);
  if (eu || !u?.user) return resposta({ ok: false, erro: "nao_autenticado" }, 401);

  let corpo: any = {};
  try { corpo = await req.json(); } catch { /* vazio */ }
  const cnpj = String(corpo?.cnpj ?? "").replace(/\D/g, "");
  if (!cnpjValido(cnpj)) return resposta({ ok: false, erro: "cnpj_invalido" });

  const { data: prof } = await admin.from("profissionais").select("id,nome,selo_mei,cnpj,cnpj_verificado_em").eq("id", u.user.id).maybeSingle();
  if (!prof) return resposta({ ok: false, erro: "nao_profissional" });
  if (prof.selo_mei && prof.cnpj === cnpj) return resposta({ ok: true, selo: true, ja_verificado: true });
  // freio: uma consulta por minuto por profissional
  if (prof.cnpj_verificado_em && Date.now() - new Date(prof.cnpj_verificado_em).getTime() < 60_000) {
    return resposta({ ok: false, erro: "aguarde" });
  }

  const c = await consultar(cnpj);
  if (!c) return resposta({ ok: false, erro: "receita_indisponivel" });

  const confere = nomeConfere(prof.nome, c);
  const ok = c.ativa && confere;
  const { data: r, error: er } = await admin.rpc("registrar_cnpj", { p_prof: prof.id, p_cnpj: cnpj, p_razao: c.razao, p_ok: ok });
  if (er) { console.log(JSON.stringify({ diag: "registrar_cnpj", erro: er.message })); return resposta({ ok: false, erro: "falha" }, 500); }
  if (r && r.ok === false) return resposta(r);
  console.log(JSON.stringify({ prof: prof.id, ativa: c.ativa, confere, selo: ok }));
  return resposta({ ok: true, selo: ok, bonus: r?.bonus ?? 0, razao: c.razao, situacao: c.situacao,
                    motivo: ok ? null : (!c.ativa ? "inativo" : "nome_nao_confere") });
});
