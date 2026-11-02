// Foster Central · comunicado por e-mail para os profissionais cadastrados (Resend).
// POST {token, comunicado}: chamado de dentro do banco (net.http_post) com o token de privado.config.
// Cada pessoa recebe cada comunicado uma vez só (registro em privado.comunicados_enviados).
// Segredo: RESEND_API_KEY. Remetente: domínio fostercalc.com.br verificado no Resend.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const APP = "https://central.engfoster.com.br/";
const REMETENTE = "Wilson · Foster Central <avisos@fostercalc.com.br>";
const RESPONDER_PARA = "comercial@fosterconstrucoes.com.br";
const WHATS = "https://wa.me/5524992096103";
const esc = (s: unknown) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

function htmlPerfil(d: any) {
  const ola = d.nome ? `Olá, ${esc(String(d.nome).split(" ")[0])}!` : "Olá!";
  const falta: string[] = [];
  if (!d.nome) falta.push("Seu nome e WhatsApp");
  if (d.falta_cidade) falta.push("A cidade onde você atende");
  if (d.falta_area) falta.push("A sua área (elétrica, pintura, engenharia, projetos…)");
  falta.push("Algumas fotos de obras suas (o cliente confia muito mais)");
  return `<!doctype html><html lang="pt-BR"><body style="margin:0;background:#F5EFE6;font-family:Arial,sans-serif;color:#1F2328">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#F5EFE6;padding:24px 0"><tr><td align="center">
<table role="presentation" width="560" cellpadding="0" cellspacing="0" style="max-width:560px;width:100%;background:#ffffff;border-radius:12px;overflow:hidden">
<tr><td style="background:#1F2328;padding:18px 24px;border-bottom:4px solid #D00000;color:#ffffff;font-size:18px;font-weight:bold;letter-spacing:1px">FOSTER CENTRAL</td></tr>
<tr><td style="padding:24px;font-size:15px;line-height:1.55">
<p style="margin:0 0 12px">${ola} Aqui é o Wilson, da Foster Central.</p>
<p style="margin:0 0 12px">Obrigado por estar com a gente desde o começo. Estou preparando a divulgação da plataforma e quero que os primeiros pedidos de clientes cheguem para quem já está cadastrado, ou seja, você.</p>
<p style="margin:0 0 12px"><b>O que mudou:</b> agora cada pedido vai só para os profissionais da região do cliente. Você recebe aviso de serviço perto de onde atende e não gasta crédito com cliente de longe.</p>
<p style="margin:0 0 8px">Para entrar nessa lista, complete no seu perfil (leva 1 minuto):</p>
<ul style="margin:0 0 16px;padding-left:20px">${falta.map((f) => `<li style="margin:3px 0">${esc(f)}</li>`).join("")}</ul>
<a href="${APP}?completar=perfil" style="display:inline-block;background:#D00000;color:#ffffff;text-decoration:none;font-weight:bold;font-size:15px;padding:12px 22px;border-radius:8px">Completar meu perfil</a>
<p style="margin:8px 0 0;font-size:13px;color:#4A4F55">Entre com este e-mail. Esqueceu a senha? Na tela de entrada, toque em <b>Esqueci minha senha</b>.</p>
<p style="margin:18px 0 0;background:#F5EFE6;padding:12px 14px;border-radius:8px">🎁 Quem fizer a verificação (pelo MEI/CNPJ em 10 segundos ou com uma selfie segurando o documento) ganha o <b>selo de verificado</b> e <b>+5 créditos</b>.</p>
<p style="margin:16px 0 0">Qualquer dúvida, é só responder este e-mail ou <a href="${WHATS}" style="color:#D00000;font-weight:bold">me chamar no WhatsApp</a>.</p>
<p style="margin:16px 0 0">Abraço,<br><b>Wilson Foster</b><br><span style="color:#4A4F55">Foster Central</span></p>
</td></tr>
<tr><td style="padding:16px 24px;border-top:1px solid #E5E0D8;font-size:12px;color:#6B7076;line-height:1.5">
Você recebeu este e-mail porque tem cadastro de profissional na Foster Central (central.engfoster.com.br). Foster Engenharia &amp; Construção.
</td></tr></table></td></tr></table></body></html>`;
}

const COMUNICADOS: Record<string, { assunto: (d: any) => string; html: (d: any) => string }> = {
  "completar-perfil-2026-11": {
    assunto: (d) => d.nome ? `${String(d.nome).split(" ")[0]}, os pedidos agora chegam pela sua região` : "Os pedidos da Foster Central agora chegam pela sua região",
    html: htmlPerfil,
  },
};

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("ok");
  let corpo: any = null; try { corpo = await req.json(); } catch { return new Response("ignorado"); }
  const com = COMUNICADOS[String(corpo?.comunicado || "")];
  if (!com) return new Response("comunicado desconhecido", { status: 400 });
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const chave = (Deno.env.get("RESEND_API_KEY") || "").trim();
  if (!chave) { console.log(JSON.stringify({ diag: "sem_RESEND_API_KEY" })); return new Response("sem chave", { status: 500 }); }
  const r = await sb.rpc("comunicado_destinatarios", { p_token: String(corpo?.token ?? ""), p_comunicado: corpo.comunicado });
  if (r.error) { console.log(JSON.stringify({ diag: "destinatarios", erro: r.error.message })); return new Response("recusado", { status: 401 }); }
  const lista = (r.data as any[]) || [];
  const emails = lista.map((d) => ({ from: REMETENTE, to: [d.email], reply_to: RESPONDER_PARA, subject: com.assunto(d), html: com.html(d) }));
  let enviados = 0; const falhas: string[] = [];
  for (let i = 0; i < emails.length; i += 100) {
    const lote = emails.slice(i, i + 100);
    const resp = await fetch("https://api.resend.com/emails/batch", {
      method: "POST", headers: { Authorization: `Bearer ${chave}`, "Content-Type": "application/json" }, body: JSON.stringify(lote) });
    if (resp.ok) enviados += lote.length; else falhas.push(`${resp.status} ${(await resp.text()).slice(0, 200)}`);
  }
  console.log(JSON.stringify({ comunicado: corpo.comunicado, destinatarios: lista.length, enviados, falhas }));
  return new Response(JSON.stringify({ destinatarios: lista.length, enviados, falhas }), { headers: { "Content-Type": "application/json" } });
});
