// Foster Central · aviso de pedido novo por e-mail (Resend).
// POST {chamado_id, token}: chamado pelo gatilho do banco a cada pedido novo; o token é conferido no banco.
// GET ?sair=<id>&a=<assinatura>: descadastro pelo link do e-mail.
// Segredo: RESEND_API_KEY. Remetente: domínio fostercalc.com.br verificado no Resend.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const APP = "https://central.engfoster.com.br/";
const FUNCAO = "https://prxasqrilvqhenvmmeov.supabase.co/functions/v1/notificar-pedido";
const REMETENTE = "Foster Central <avisos@fostercalc.com.br>";
const RESPONDER_PARA = "comercial@fosterconstrucoes.com.br";

const esc = (s: unknown) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
const pagina = (titulo: string, texto: string) => new Response(
  `<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${esc(titulo)}</title></head>
<body style="margin:0;font-family:Arial,sans-serif;background:#F5EFE6;color:#1F2328"><div style="max-width:480px;margin:60px auto;padding:28px;background:#fff;border-radius:12px;border-top:5px solid #D00000">
<h1 style="font-size:22px;margin:0 0 10px">${esc(titulo)}</h1><p style="font-size:15px;line-height:1.5;margin:0 0 18px">${esc(texto)}</p>
<a href="${APP}" style="color:#D00000;font-weight:bold">Abrir a Foster Central</a></div></body></html>`,
  { status: 200, headers: { "Content-Type": "text/html; charset=utf-8" } });

function emailHtml(nome: string, p: any, linkSair: string) {
  const primeiro = esc((nome || "").split(" ")[0] || "profissional");
  const creditos = `${p.custo} crédito${p.custo > 1 ? "s" : ""}`;
  return `<!doctype html><html lang="pt-BR"><body style="margin:0;background:#F5EFE6;font-family:Arial,sans-serif;color:#1F2328">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#F5EFE6;padding:24px 0"><tr><td align="center">
<table role="presentation" width="560" cellpadding="0" cellspacing="0" style="max-width:560px;width:100%;background:#ffffff;border-radius:12px;overflow:hidden">
<tr><td style="background:#1F2328;padding:18px 24px;border-bottom:4px solid #D00000;color:#ffffff;font-size:18px;font-weight:bold;letter-spacing:1px">FOSTER CENTRAL</td></tr>
<tr><td style="padding:24px">
<p style="margin:0 0 12px;font-size:15px">Olá, ${primeiro}! Chegou um pedido novo na sua área:</p>
<p style="margin:0 0 4px;font-size:22px;font-weight:bold">${esc(p.servico)}</p>
<p style="margin:0 0 14px;font-size:15px;color:#4A4F55">${esc(p.bairro || "Região não informada")}</p>
<p style="margin:0 0 20px;font-size:15px;line-height:1.5;background:#F5EFE6;padding:12px 14px;border-radius:8px">${esc(p.descricao)}${String(p.descricao || "").length >= 220 ? "…" : ""}</p>
<a href="${APP}" style="display:inline-block;background:#D00000;color:#ffffff;text-decoration:none;font-weight:bold;font-size:15px;padding:12px 22px;border-radius:8px">Ver pedido e desbloquear o contato</a>
<p style="margin:16px 0 0;font-size:13px;color:#4A4F55">O contato do cliente custa ${creditos}. Quem responde primeiro costuma fechar o serviço.</p>
</td></tr>
<tr><td style="padding:16px 24px;border-top:1px solid #E5E0D8;font-size:12px;color:#6B7076;line-height:1.5">
Você recebe este aviso porque é profissional cadastrado na Foster Central. No máximo um aviso a cada 3 horas.<br>
<a href="${linkSair}" style="color:#6B7076">Não quero mais receber avisos de pedidos</a> · Foster Engenharia &amp; Construção
</td></tr></table></td></tr></table></body></html>`;
}

Deno.serve(async (req) => {
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const url = new URL(req.url);

  if (req.method === "GET") {
    const id = url.searchParams.get("sair"), a = url.searchParams.get("a");
    if (!id || !a) return pagina("Link incompleto", "Abra o link de descadastro direto do e-mail.");
    const r = await sb.rpc("sair_dos_avisos", { p_id: id, p_assinatura: a });
    return r.data ? pagina("Pronto", "Você não vai mais receber avisos de pedidos por e-mail. Para voltar a receber, ative de novo no seu painel da Foster Central.")
                  : pagina("Link inválido", "Não encontramos esse cadastro. Fale com a gente pelo WhatsApp (24) 99209-6103.");
  }
  if (req.method !== "POST") return new Response("ok");

  let corpo: any = null;
  try { corpo = await req.json(); } catch { return new Response("ignorado"); }
  const r = await sb.rpc("preparar_aviso", { p_chamado_id: corpo?.chamado_id, p_token: String(corpo?.token ?? "") });
  if (r.error) { console.log(JSON.stringify({ diag: "preparar_aviso", erro: r.error.message })); return new Response("recusado", { status: 401 }); }
  const { pedido, destinatarios } = r.data as any;
  if (!pedido || !destinatarios?.length) { console.log(JSON.stringify({ chamado: corpo?.chamado_id, enviados: 0 })); return new Response("ninguém a avisar"); }

  const chave = (Deno.env.get("RESEND_API_KEY") || "").trim();
  if (!chave) { console.log(JSON.stringify({ diag: "sem_RESEND_API_KEY" })); return new Response("sem chave", { status: 500 }); }

  const emails = destinatarios.map((d: any) => {
    const sair = `${FUNCAO}?sair=${encodeURIComponent(d.id)}&a=${encodeURIComponent(d.sair)}`;
    return {
      from: REMETENTE, to: [d.email], reply_to: RESPONDER_PARA,
      subject: `Pedido novo: ${pedido.servico}${pedido.bairro ? " · " + pedido.bairro : ""}`,
      html: emailHtml(d.nome, pedido, sair),
      headers: { "List-Unsubscribe": `<${sair}>` },
    };
  });
  let enviados = 0;
  for (let i = 0; i < emails.length; i += 100) {
    const lote = emails.slice(i, i + 100);
    const resp = await fetch("https://api.resend.com/emails/batch", {
      method: "POST", headers: { Authorization: `Bearer ${chave}`, "Content-Type": "application/json" }, body: JSON.stringify(lote),
    });
    if (resp.ok) enviados += lote.length;
    else console.log(JSON.stringify({ diag: "resend", status: resp.status, corpo: (await resp.text()).slice(0, 300) }));
  }
  console.log(JSON.stringify({ chamado: pedido.id, categoria: pedido.categoria, destinatarios: emails.length, enviados }));
  return new Response(`enviados ${enviados}`);
});
