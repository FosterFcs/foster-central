-- =========================================================
-- Foster Central · aviso por e-mail de pedido novo (2026-10-13)
-- Pedido novo -> gatilho chama a função notificar-pedido -> e-mail (Resend) aos profissionais da categoria.
-- No máximo 1 aviso a cada 3 horas por profissional; descadastro por link no e-mail ou no painel.
-- =========================================================

create extension if not exists pg_net with schema extensions;

alter table public.profissionais add column if not exists recebe_avisos boolean not null default true;
alter table public.profissionais add column if not exists ultimo_aviso timestamptz;

-- segredo interno entre o banco e a função (gerado aqui, ninguém de fora lê)
create schema if not exists privado;
revoke all on schema privado from public, anon, authenticated;
create table if not exists privado.config (chave text primary key, valor text not null);
insert into privado.config (chave, valor) values ('aviso_token', gen_random_uuid()::text) on conflict (chave) do nothing;
revoke all on privado.config from public, anon, authenticated;

-- pedido novo: chama a função de aviso sem atrasar o envio do pedido
create or replace function public.avisar_pedido_novo()
returns trigger language plpgsql security definer set search_path = public, privado, extensions as $$
begin
  if new.categoria is null then return new; end if;
  perform net.http_post(
    url := 'https://prxasqrilvqhenvmmeov.supabase.co/functions/v1/notificar-pedido',
    headers := jsonb_build_object('Content-Type', 'application/json'),
    body := jsonb_build_object('chamado_id', new.id, 'token', (select valor from privado.config where chave = 'aviso_token'))
  );
  return new;
exception when others then
  return new;   -- aviso nunca impede o pedido de ser gravado
end $$;
drop trigger if exists chamados_avisar_pedido_novo on public.chamados;
create trigger chamados_avisar_pedido_novo after insert on public.chamados
  for each row execute function public.avisar_pedido_novo();

-- usado só pela função: confere o segredo, devolve o pedido e quem avisar, e marca o horário do aviso
create or replace function public.preparar_aviso(p_chamado_id bigint, p_token text)
returns json language plpgsql security definer set search_path = public, privado, auth as $$
declare c public.chamados%rowtype; v_dest json;
begin
  if p_token is distinct from (select valor from privado.config where chave = 'aviso_token') then
    raise exception 'token inválido';
  end if;
  select * into c from public.chamados where id = p_chamado_id;
  if not found or c.categoria is null then return json_build_object('pedido', null, 'destinatarios', '[]'::json); end if;
  with alvo as (
    update public.profissionais p set ultimo_aviso = now()
      from auth.users u
     where u.id = p.id and u.email_confirmed_at is not null and u.email is not null
       and p.recebe_avisos and p.categoria = c.categoria
       and (p.ultimo_aviso is null or p.ultimo_aviso < now() - interval '3 hours')
    returning p.id, p.nome, u.email)
  -- assinatura do link de descadastro: não fica gravada em coluna nenhuma (a tabela de profissionais é de leitura pública)
  select coalesce(json_agg(json_build_object('id', id, 'nome', nome, 'email', email,
           'sair', md5(id::text || (select valor from privado.config where chave = 'aviso_token')))), '[]'::json) into v_dest from alvo;
  return json_build_object(
    'pedido', json_build_object('id', c.id, 'servico', c.servico, 'categoria', c.categoria, 'bairro', c.bairro,
                                'descricao', left(c.descricao, 220), 'custo', public.custo_chamado(c.categoria)),
    'destinatarios', v_dest);
end $$;

-- descadastro pelo link do e-mail
create or replace function public.sair_dos_avisos(p_id uuid, p_assinatura text)
returns boolean language sql security definer set search_path = public, privado as $$
  with x as (update public.profissionais set recebe_avisos = false
              where id = p_id and p_assinatura = md5(p_id::text || (select valor from privado.config where chave = 'aviso_token'))
             returning 1)
  select exists (select 1 from x)
$$;

revoke execute on function public.avisar_pedido_novo(), public.preparar_aviso(bigint, text), public.sair_dos_avisos(uuid, text) from public, anon, authenticated;
grant execute on function public.preparar_aviso(bigint, text), public.sair_dos_avisos(uuid, text) to service_role;
