-- =========================================================
-- Foster Central · segurança e correções (2026-10-13)
-- Contatos dos clientes só saem por função, depois do desbloqueio pago;
-- custo calculado no banco; cadastro pelo gatilho com os dados do formulário;
-- funções do painel admin; tabela de clientes.
-- =========================================================

-- ---------- chamados: colunas que o app já envia ----------
alter table public.chamados add column if not exists categoria text;
alter table public.chamados add column if not exists cliente_id uuid references auth.users(id) on delete set null;
alter table public.chamados add constraint chamados_tamanhos check (
  char_length(nome_cliente) <= 120 and char_length(telefone_cliente) <= 30 and char_length(servico) <= 120
  and char_length(coalesce(bairro, '')) <= 120 and char_length(descricao) <= 3000 and char_length(coalesce(categoria, '')) <= 40
) not valid;

-- ---------- chamados: quem lê o quê ----------
-- leitura pública só das colunas sem contato; nome e telefone do cliente apenas pelas funções abaixo
revoke all on public.chamados from anon, authenticated;
grant select (id, servico, categoria, bairro, descricao, status, criado_em) on public.chamados to anon, authenticated;
grant insert (nome_cliente, telefone_cliente, servico, categoria, bairro, descricao, status, cliente_id) on public.chamados to anon, authenticated;

drop policy if exists "prof_read_chamados" on public.chamados;
drop policy if exists "public_read_chamados" on public.chamados;
drop policy if exists "update_auth" on public.chamados;
drop policy if exists "insert_anon" on public.chamados;
drop policy if exists "select_auth" on public.chamados;
create policy "chamados_leitura" on public.chamados for select to anon, authenticated using (true);
create policy "chamados_novo_pedido" on public.chamados for insert to anon, authenticated
  with check (status = 'novo' and (cliente_id is null or cliente_id = auth.uid()));

-- o app não usa realtime; fora da publicação, nenhuma mudança vaza o contato
do $$ begin
  if exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'chamados') then
    alter publication supabase_realtime drop table public.chamados;
  end if;
end $$;

-- ---------- desbloqueios e transações: só pelas funções ----------
drop policy if exists "prof insere desbloqueio" on public.desbloqueios;
drop policy if exists "transacoes_insert_own" on public.transacoes_credito;
revoke insert, update, delete on public.desbloqueios, public.transacoes_credito from anon, authenticated;
create unique index if not exists desbloqueios_prof_chamado on public.desbloqueios (prof_id, chamado_id);

-- ---------- avaliações: ninguém apaga pelo app ----------
drop policy if exists "admin deleta" on public.avaliacoes;
drop policy if exists "prof pode avaliar" on public.avaliacoes;
revoke update, delete on public.avaliacoes from anon, authenticated;
alter table public.avaliacoes add constraint avaliacoes_tamanho check (char_length(coalesce(comentario, '')) <= 1000) not valid;

-- ---------- clientes ----------
create table if not exists public.clientes (
  id uuid primary key references auth.users(id) on delete cascade,
  nome text not null,
  telefone text,
  cidade text,
  email text,
  criado_em timestamptz default now()
);
alter table public.clientes enable row level security;
drop policy if exists "clientes_le_proprio" on public.clientes;
drop policy if exists "clientes_edita_proprio" on public.clientes;
create policy "clientes_le_proprio" on public.clientes for select to authenticated using (auth.uid() = id);
create policy "clientes_edita_proprio" on public.clientes for update to authenticated using (auth.uid() = id) with check (auth.uid() = id);
revoke insert, delete on public.clientes from anon, authenticated;

-- ---------- cadastro: o gatilho grava com os dados do formulário ----------
create or replace function public.handle_new_profissional()
returns trigger language plpgsql security definer set search_path = public as $$
declare m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
begin
  if m->>'tipo' = 'cliente' then
    insert into public.clientes (id, nome, telefone, cidade, email)
    values (new.id, coalesce(nullif(m->>'nome', ''), 'Cliente'), m->>'telefone', m->>'cidade', new.email)
    on conflict (id) do nothing;
  else
    insert into public.profissionais (id, nome, telefone, categoria, especialidades, saldo_creditos)
    values (new.id, coalesce(nullif(m->>'nome', ''), 'Profissional'), coalesce(m->>'telefone', ''),
            nullif(m->>'categoria', ''), nullif(m->>'especialidades', ''), 10)
    on conflict (id) do nothing;
  end if;
  return new;
end $$;

-- ---------- custo do contato, decidido no banco ----------
create or replace function public.custo_chamado(p_categoria text)
returns integer language sql immutable set search_path = public as $$
  select case p_categoria
    when 'engenharia' then 3 when 'arquitetura' then 3 when 'gestao' then 3
    when 'tecnico' then 2 when 'civil' then 2 when 'eletrica' then 2 when 'hidraulica' then 2
    when 'obraSeca' then 2 when 'estrutura' then 2 when 'cobertura' then 2
    when 'acabamento' then 1 when 'esquadrias' then 1 when 'complementar' then 1
    else 1 end
$$;

-- ---------- desbloqueio: debita e devolve o contato ----------
drop function if exists public.desbloquear_chamado(bigint, integer);
create or replace function public.desbloquear_chamado(p_chamado_id bigint)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_saldo integer;
  v_custo integer;
  c public.chamados%rowtype;
begin
  if v_uid is null then return json_build_object('ok', false, 'erro', 'nao_autenticado'); end if;
  select saldo_creditos into v_saldo from public.profissionais where id = v_uid for update;
  if not found then return json_build_object('ok', false, 'erro', 'nao_profissional'); end if;
  select * into c from public.chamados where id = p_chamado_id;
  if not found then return json_build_object('ok', false, 'erro', 'chamado_inexistente'); end if;

  if exists (select 1 from public.desbloqueios where prof_id = v_uid and chamado_id = p_chamado_id) then
    return json_build_object('ok', true, 'ja_desbloqueado', true, 'nome', c.nome_cliente, 'telefone', c.telefone_cliente, 'saldo', v_saldo);
  end if;

  v_custo := public.custo_chamado(c.categoria);
  if v_saldo < v_custo then
    return json_build_object('ok', false, 'erro', 'saldo_insuficiente', 'saldo', v_saldo, 'custo', v_custo);
  end if;

  update public.profissionais set saldo_creditos = saldo_creditos - v_custo where id = v_uid;
  insert into public.desbloqueios (prof_id, chamado_id) values (v_uid, p_chamado_id);
  insert into public.transacoes_credito (profissional_id, valor, tipo, referencia_chamado) values (v_uid, -v_custo, 'desbloqueio', p_chamado_id);
  update public.chamados set desbloqueado_por = coalesce(desbloqueado_por, v_uid) where id = p_chamado_id;

  return json_build_object('ok', true, 'nome', c.nome_cliente, 'telefone', c.telefone_cliente, 'saldo', v_saldo - v_custo, 'custo', v_custo);
end $$;

-- contatos que o profissional logado já pagou
create or replace function public.contatos_desbloqueados()
returns table (chamado_id bigint, nome_cliente text, telefone_cliente text)
language sql stable security definer set search_path = public as $$
  select c.id, c.nome_cliente, c.telefone_cliente
  from public.desbloqueios d join public.chamados c on c.id = d.chamado_id
  where d.prof_id = auth.uid()
$$;

-- pedidos do cliente logado: pelo vínculo da conta ou pelo telefone cadastrado
create or replace function public.meus_pedidos()
returns table (id bigint, servico text, bairro text, descricao text, status text, criado_em timestamptz)
language sql stable security definer set search_path = public as $$
  with eu as (select regexp_replace(coalesce(telefone, ''), '\D', '', 'g') tel from public.clientes where id = auth.uid())
  select c.id, c.servico, c.bairro, c.descricao, c.status, c.criado_em
  from public.chamados c
  where auth.uid() is not null and (
    c.cliente_id = auth.uid()
    or exists (select 1 from eu where length(eu.tel) >= 10 and regexp_replace(c.telefone_cliente, '\D', '', 'g') = eu.tel))
  order by c.criado_em desc
$$;

-- ---------- painel admin ----------
create or replace function public.e_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from public.profissionais where id = auth.uid()), false)
$$;

create or replace function public.admin_chamados()
returns setof public.chamados language plpgsql stable security definer set search_path = public as $$
begin
  if not public.e_admin() then raise exception 'acesso negado'; end if;
  return query select * from public.chamados order by criado_em desc;
end $$;

create or replace function public.admin_adicionar_creditos(p_prof_id uuid, p_qtd integer)
returns json language plpgsql security definer set search_path = public as $$
declare v_saldo integer;
begin
  if not public.e_admin() then raise exception 'acesso negado'; end if;
  if p_qtd is null or p_qtd < 1 or p_qtd > 1000 then raise exception 'quantidade inválida'; end if;
  update public.profissionais set saldo_creditos = saldo_creditos + p_qtd where id = p_prof_id returning saldo_creditos into v_saldo;
  if not found then raise exception 'profissional não encontrado'; end if;
  insert into public.transacoes_credito (profissional_id, valor, tipo) values (p_prof_id, p_qtd, 'bonus');
  return json_build_object('ok', true, 'saldo', v_saldo);
end $$;

create or replace function public.admin_tornar_admin(p_prof_id uuid)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not public.e_admin() then raise exception 'acesso negado'; end if;
  update public.profissionais set is_admin = true where id = p_prof_id;
  if not found then raise exception 'profissional não encontrado'; end if;
  return json_build_object('ok', true);
end $$;

create or replace function public.admin_excluir_profissional(p_prof_id uuid)
returns json language plpgsql security definer set search_path = public, auth as $$
begin
  if not public.e_admin() then raise exception 'acesso negado'; end if;
  if p_prof_id = auth.uid() then raise exception 'não é possível excluir a própria conta'; end if;
  delete from public.desbloqueios where prof_id = p_prof_id;
  delete from public.avaliacoes where prof_id = p_prof_id;
  update public.chamados set desbloqueado_por = null where desbloqueado_por = p_prof_id;
  delete from public.profissionais where id = p_prof_id;
  delete from auth.users where id = p_prof_id;
  return json_build_object('ok', true);
end $$;

-- ---------- quem pode chamar ----------
revoke execute on function public.desbloquear_chamado(bigint), public.contatos_desbloqueados(), public.meus_pedidos(),
  public.e_admin(), public.admin_chamados(), public.admin_adicionar_creditos(uuid, integer),
  public.admin_tornar_admin(uuid), public.admin_excluir_profissional(uuid), public.handle_new_profissional()
  from public, anon;
grant execute on function public.desbloquear_chamado(bigint), public.contatos_desbloqueados(), public.meus_pedidos(),
  public.e_admin(), public.admin_chamados(), public.admin_adicionar_creditos(uuid, integer),
  public.admin_tornar_admin(uuid), public.admin_excluir_profissional(uuid)
  to authenticated;
revoke execute on function public.adicionar_creditos(integer) from public, anon, authenticated;
