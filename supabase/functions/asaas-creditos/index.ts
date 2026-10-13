// Foster Central · recebe os avisos do Asaas e credita os pacotes de créditos.
// Autenticação: cabeçalho 'asaas-access-token' igual ao segredo ASAAS_WEBHOOK_TOKEN (sem JWT).
// Segredos: ASAAS_WEBHOOK_TOKEN, ASAAS_API_KEY (para ler o e-mail do cliente no Asaas).
// O Asaas manda para este endereço os pagamentos de todos os produtos: só os links abaixo creditam.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

// id do link de pagamento (final de asaas.com/c/<id>) -> pacote
const PACOTES: Record<string, { creditos: number; valor: number }> = {
  "eqgs12tszbk96gti": { creditos: 5, valor: 9.9 },
  "1t31qz20dxatkyfv": { creditos: 15, valor: 24.9 },
  "yqeb9y2wx36ystu7": { creditos: 30, valor: 44.9 },
  "hlh6e4p61i29rfru": { creditos: 60, valor: 79.9 },
};
const CREDITAR = new Set(["PAYMENT_CONFIRMED", "PAYMENT_RECEIVED"]);
const ESTORNAR = new Set(["PAYMENT_REFUNDED", "PAYMENT_CHARGEBACK_REQUESTED"]);
const ok = (msg = "ok") => new Response(msg, { status: 200 });
const limpar = (s: string) => s.trim().replace(/^["']+|["']+$/g, "").trim();
function iguais(a: string, b: string) {
  if (a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}
async function emailDoCliente(cliente: string): Promise<string | null> {
  const chave = limpar(Deno.env.get("ASAAS_API_KEY") || "");
  if (!chave || !cliente) return null;
  const r = await fetch(`https://api.asaas.com/v3/customers/${encodeURIComponent(cliente)}`, {
    headers: { access_token: chave, "User-Agent": "FosterCentral" },
  });
  if (!r.ok) { console.log(JSON.stringify({ diag: "api_cliente", status: r.status })); return null; }
  const c = await r.json();
  return (c?.email || "").trim() || null;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return ok();
  const esperado = limpar(Deno.env.get("ASAAS_WEBHOOK_TOKEN") || "");
  const recebido = limpar(req.headers.get("asaas-access-token") || "");
  if (!esperado || !iguais(recebido, esperado)) {
    console.log(JSON.stringify({ diag: "token_recusado", segredoExiste: !!esperado, tamSegredo: esperado.length, tamRecebido: recebido.length }));
    return new Response("unauthorized", { status: 401 });
  }
  let ev: any = null;
  try { ev = await req.json(); } catch { return ok("ignorado"); }
  const p = ev?.payment;
  if (!ev?.event || !p?.id) return ok("ignorado");

  const pacote = p.paymentLink ? PACOTES[p.paymentLink] : undefined;
  if (!pacote) return ok("outro produto");                 // pagamento de outro produto (Foster Calc etc.)
  if (!CREDITAR.has(ev.event) && !ESTORNAR.has(ev.event)) return ok("ignorado");

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  try {
    if (ESTORNAR.has(ev.event)) {
      const r = await sb.rpc("estornar_pagamento", { p_pagamento_id: p.id });
      console.log(JSON.stringify({ evento: ev.event, pagamento: p.id, resultado: r.data, erro: r.error?.message }));
      return r.error ? new Response("erro", { status: 500 }) : ok(String(r.data));
    }
    const email = await emailDoCliente(p.customer);
    if (!email) {
      console.log(JSON.stringify({ diag: "sem_email", pagamento: p.id }));
      return new Response("sem email", { status: 500 });   // o Asaas tenta de novo depois
    }
    const valor = Number(p.originalValue ?? p.value ?? 0);
    const r = await sb.rpc("creditar_pagamento", { p_pagamento_id: p.id, p_email: email, p_creditos: pacote.creditos,
      p_valor: valor, p_link: p.paymentLink, p_forma: p.billingType ?? null });
    console.log(JSON.stringify({ evento: ev.event, pagamento: p.id, creditos: pacote.creditos, valor, resultado: r.data, erro: r.error?.message }));
    return r.error ? new Response("erro", { status: 500 }) : ok(String(r.data));
  } catch (e) {
    console.error(String(e));
    return new Response("erro", { status: 500 });
  }
});
