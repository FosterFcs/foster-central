-- =========================================================
-- Foster Central · portfólio, selos por uso e respaldo em conflitos (2026-10-29)
-- 1) Portfólio de fotos de obras (bucket público, até 12 fotos por profissional).
-- 2) CNPJ conferido automaticamente (função verificar-cnpj grava pelo service_role).
-- 3) Selos por uso: Bem avaliado, Experiente, Perfil completo — calculados, ninguém liga à mão.
-- 4) Verificação simplificada: CPF + uma selfie segurando o documento. +5 créditos na 1ª verificação.
-- 5) Respaldo: orçamento com aceite digital do cliente, reclamação vai direto ao profissional,
--    regra automática de suspensão, denúncia de fraude é a única coisa que chega ao admin,
--    aceite dos termos gravado com a versão.
-- =========================================================

-- ---------- profissionais / clientes / chamados: colunas novas ----------
alter table public.profissionais
  add column if not exists cnpj text,
  add column if not exists cnpj_razao text,
  add column if not exists cnpj_verificado_em timestamptz,
  add column if not exists bonus_verificacao boolean not null default false,
  add column if not exists suspenso boolean not null default false,
  add column if not exists suspenso_motivo text,
  add column if not exists termos_versao text;
create unique index if not exists profissionais_cnpj_unico on public.profissionais (cnpj) where selo_mei;
alter table public.clientes add column if not exists termos_versao text, add column if not exists aceite_termos_em timestamptz;
alter table public.chamados add column if not exists termos_versao text;

-- a versão dos termos aceita fica gravada em cada pedido
create or replace function public.versao_termos() returns text language sql immutable as $$ select '2026-10-29'::text $$;
create or replace function public.carimbar_termos_pedido()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.aceite_termos then new.termos_versao := public.versao_termos(); end if;
  return new;
end $$;
drop trigger if exists chamados_carimbar_termos on public.chamados;
create trigger chamados_carimbar_termos before insert on public.chamados for each row execute function public.carimbar_termos_pedido();

-- cadastro: grava o aceite dos termos que o formulário enviou
create or replace function public.handle_new_profissional()
returns trigger language plpgsql security definer set search_path = public as $$
declare m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
        v_aceite boolean := coalesce(m->>'aceite_termos', '') <> '';
begin
  if m->>'tipo' = 'cliente' then
    insert into public.clientes (id, nome, telefone, cidade, email, termos_versao, aceite_termos_em)
    values (new.id, coalesce(nullif(m->>'nome', ''), 'Cliente'), m->>'telefone', m->>'cidade', new.email,
            case when v_aceite then left(m->>'aceite_termos', 20) end, case when v_aceite then now() end)
    on conflict (id) do nothing;
  else
    insert into public.profissionais (id, nome, telefone, categoria, especialidades, saldo_creditos, termos_versao, aceite_termos_em)
    values (new.id, coalesce(nullif(m->>'nome', ''), 'Profissional'), coalesce(m->>'telefone', ''),
            nullif(m->>'categoria', ''), nullif(m->>'especialidades', ''), 10,
            case when v_aceite then left(m->>'aceite_termos', 20) end, case when v_aceite then now() end)
    on conflict (id) do nothing;
  end if;
  return new;
end $$;

-- ---------- portfólio ----------
create table if not exists public.portfolio (
  id bigint generated always as identity primary key,
  prof_id uuid not null references public.profissionais(id) on delete cascade,
  caminho text not null unique,
  legenda text check (char_length(coalesce(legenda, '')) <= 140),
  criado_em timestamptz not null default now()
);
create index if not exists portfolio_prof on public.portfolio (prof_id, criado_em desc);
alter table public.portfolio enable row level security;
drop policy if exists "portfolio_leitura" on public.portfolio;
drop policy if exists "portfolio_adiciona_proprio" on public.portfolio;
drop policy if exists "portfolio_edita_proprio" on public.portfolio;
drop policy if exists "portfolio_apaga_proprio" on public.portfolio;
create policy "portfolio_leitura" on public.portfolio for select to anon, authenticated using (true);
create policy "portfolio_adiciona_proprio" on public.portfolio for insert to authenticated
  with check (prof_id = auth.uid() and caminho like auth.uid()::text || '/%');
create policy "portfolio_edita_proprio" on public.portfolio for update to authenticated using (prof_id = auth.uid()) with check (prof_id = auth.uid());
create policy "portfolio_apaga_proprio" on public.portfolio for delete to authenticated using (prof_id = auth.uid() or public.e_admin());
revoke all on public.portfolio from anon, authenticated;
grant select on public.portfolio to anon, authenticated;
grant insert (prof_id, caminho, legenda), update (legenda), delete on public.portfolio to authenticated;

create or replace function public.limite_portfolio()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from public.portfolio where prof_id = new.prof_id) >= 12 then
    raise exception 'limite_portfolio' using hint = 'Máximo de 12 fotos no portfólio.';
  end if;
  return new;
end $$;
drop trigger if exists portfolio_limite on public.portfolio;
create trigger portfolio_limite before insert on public.portfolio for each row execute function public.limite_portfolio();

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('portfolio', 'portfolio', true, 3145728, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;
drop policy if exists "portfolio_envia_propria" on storage.objects;
drop policy if exists "portfolio_lista_propria" on storage.objects;
drop policy if exists "portfolio_apaga_propria" on storage.objects;
create policy "portfolio_envia_propria" on storage.objects for insert to authenticated
  with check (bucket_id = 'portfolio' and (storage.foldername(name))[1] = auth.uid()::text
              and (select count(*) from storage.objects o where o.bucket_id = 'portfolio' and (storage.foldername(o.name))[1] = auth.uid()::text) < 12);
create policy "portfolio_lista_propria" on storage.objects for select to authenticated
  using (bucket_id = 'portfolio' and ((storage.foldername(name))[1] = auth.uid()::text or public.e_admin()));
create policy "portfolio_apaga_propria" on storage.objects for delete to authenticated
  using (bucket_id = 'portfolio' and ((storage.foldername(name))[1] = auth.uid()::text or public.e_admin()));

-- ---------- ocorrências: reclamação direta, denúncia, prazos ----------
alter table public.ocorrencias drop constraint if exists ocorrencias_status_check;
alter table public.ocorrencias add constraint ocorrencias_status_check
  check (status in ('aberta', 'resolvida', 'recusada', 'aguardando_profissional', 'respondida', 'nao_resolvida'));
alter table public.ocorrencias drop constraint if exists ocorrencias_motivo_check;
alter table public.ocorrencias add constraint ocorrencias_motivo_check
  check (motivo in ('telefone_invalido', 'nao_responde', 'pedido_falso', 'ja_contratou', 'servico_ruim', 'nao_compareceu',
                    'cobranca_indevida', 'outro', 'perfil_falso', 'golpe', 'ameaca'));
alter table public.ocorrencias
  add column if not exists tipo text not null default 'reporte',
  add column if not exists resposta_prof text check (char_length(coalesce(resposta_prof, '')) <= 1500),
  add column if not exists respondido_em timestamptz,
  add column if not exists concluido_em timestamptz;
do $$ begin
  alter table public.ocorrencias add constraint ocorrencias_tipo_check check (tipo in ('reporte', 'reclamacao', 'denuncia'));
exception when duplicate_object then null; end $$;
update public.ocorrencias set tipo = 'reclamacao', status = 'aguardando_profissional' where autor_tipo = 'cliente' and tipo = 'reporte' and status = 'aberta';
-- reclamação e denúncia sobre o mesmo profissional/pedido podem coexistir
drop index if exists public.ocorrencias_uma_por_contato;
create unique index if not exists ocorrencias_uma_por_tipo on public.ocorrencias (autor_id, chamado_id, coalesce(prof_id, '00000000-0000-0000-0000-000000000000'::uuid), tipo);

-- regra objetiva e automática (está nos Termos): 3 reclamações sem solução ou sem resposta em 180 dias
create or replace function public.prof_bloqueado(p_prof uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select suspenso from public.profissionais where id = p_prof), false)
      or (select count(*) from public.ocorrencias o
           where o.prof_id = p_prof and o.tipo = 'reclamacao' and o.criado_em > now() - interval '180 days'
             and (o.status = 'nao_resolvida' or (o.status = 'aguardando_profissional' and o.criado_em < now() - interval '7 days'))) >= 3
$$;

-- ---------- orçamentos com aceite digital ----------
create table if not exists public.orcamentos (
  id uuid primary key default gen_random_uuid(),
  chamado_id bigint references public.chamados(id) on delete set null,
  prof_id uuid references public.profissionais(id) on delete cascade,
  cliente_nome text check (char_length(coalesce(cliente_nome, '')) <= 120),
  servico text check (char_length(coalesce(servico, '')) <= 160),
  itens jsonb not null,
  total numeric(12,2) not null default 0,
  prazo text check (char_length(coalesce(prazo, '')) <= 80),
  pagamento text check (char_length(coalesce(pagamento, '')) <= 160),
  validade_dias integer not null default 15 check (validade_dias between 1 and 90),
  obs text check (char_length(coalesce(obs, '')) <= 800),
  criado_em timestamptz not null default now(),
  aceito_em timestamptz,
  aceito_nome text
);
create index if not exists orcamentos_prof on public.orcamentos (prof_id, criado_em desc);
create index if not exists orcamentos_chamado on public.orcamentos (chamado_id);
alter table public.orcamentos enable row level security;
revoke all on public.orcamentos from anon, authenticated;

create or replace function public.salvar_orcamento(p_chamado_id bigint, p_cliente text, p_servico text, p_itens jsonb,
  p_prazo text, p_pagamento text, p_validade integer, p_obs text)
returns json language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_id uuid; v_itens jsonb; v_total numeric;
begin
  if v_uid is null or not exists (select 1 from public.profissionais where id = v_uid) then
    return json_build_object('ok', false, 'erro', 'nao_profissional');
  end if;
  if p_chamado_id is not null and not exists (select 1 from public.desbloqueios where prof_id = v_uid and chamado_id = p_chamado_id) then
    return json_build_object('ok', false, 'erro', 'sem_desbloqueio');
  end if;
  if jsonb_typeof(p_itens) <> 'array' or jsonb_array_length(p_itens) = 0 or jsonb_array_length(p_itens) > 40 then
    return json_build_object('ok', false, 'erro', 'itens_invalidos');
  end if;
  select jsonb_agg(jsonb_build_object('desc', left(coalesce(i->>'desc', ''), 200),
                                      'valor', round(greatest(coalesce((i->>'valor')::numeric, 0), 0), 2))),
         sum(round(greatest(coalesce((i->>'valor')::numeric, 0), 0), 2))
    into v_itens, v_total from jsonb_array_elements(p_itens) i;
  insert into public.orcamentos (chamado_id, prof_id, cliente_nome, servico, itens, total, prazo, pagamento, validade_dias, obs)
  values (p_chamado_id, v_uid, left(nullif(trim(p_cliente), ''), 120), left(nullif(trim(p_servico), ''), 160), v_itens, coalesce(v_total, 0),
          left(nullif(trim(p_prazo), ''), 80), left(nullif(trim(p_pagamento), ''), 160), least(greatest(coalesce(p_validade, 15), 1), 90),
          left(nullif(trim(p_obs), ''), 800))
  returning id into v_id;
  return json_build_object('ok', true, 'id', v_id, 'total', v_total);
exception when invalid_text_representation then
  return json_build_object('ok', false, 'erro', 'itens_invalidos');
end $$;

-- link do orçamento (público para quem tem o link: o id é imprevisível)
create or replace function public.ver_orcamento(p_id uuid)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object('id', o.id, 'cliente_nome', o.cliente_nome, 'servico', o.servico, 'itens', o.itens, 'total', o.total,
    'prazo', o.prazo, 'pagamento', o.pagamento, 'validade_dias', o.validade_dias, 'obs', o.obs, 'criado_em', o.criado_em,
    'valido_ate', o.criado_em + make_interval(days => o.validade_dias), 'expirado', now() > o.criado_em + make_interval(days => o.validade_dias),
    'aceito_em', o.aceito_em, 'aceito_nome', o.aceito_nome, 'pede_telefone', o.chamado_id is not null,
    'bairro', c.bairro, 'chamado_id', o.chamado_id,
    'prof', json_build_object('id', p.id, 'nome', p.nome, 'telefone', p.telefone, 'categoria', p.categoria, 'cidade', p.cidade,
      'selo_identidade', p.selo_identidade, 'selo_registro', p.selo_registro, 'registro_tipo', case when p.selo_registro then p.registro_tipo end,
      'registro_numero', case when p.selo_registro then p.registro_numero end,
      'selo_mei', p.selo_mei, 'cnpj', case when p.selo_mei then p.cnpj end, 'cnpj_razao', case when p.selo_mei then p.cnpj_razao end, 'emite_nf', p.emite_nf))
  from public.orcamentos o join public.profissionais p on p.id = o.prof_id left join public.chamados c on c.id = o.chamado_id
  where o.id = p_id
$$;

-- aceite do cliente: nome + 4 últimos dígitos do telefone do pedido (prova de que foi o cliente)
create or replace function public.aceitar_orcamento(p_id uuid, p_nome text, p_tel_final text default null)
returns json language plpgsql security definer set search_path = public as $$
declare o public.orcamentos%rowtype; v_tel text;
begin
  select * into o from public.orcamentos where id = p_id for update;
  if not found then return json_build_object('ok', false, 'erro', 'orcamento_inexistente'); end if;
  if o.aceito_em is not null then return json_build_object('ok', false, 'erro', 'ja_aceito'); end if;
  if now() > o.criado_em + make_interval(days => o.validade_dias) then return json_build_object('ok', false, 'erro', 'orcamento_expirado'); end if;
  if char_length(coalesce(trim(p_nome), '')) < 5 or position(' ' in trim(p_nome)) = 0 then return json_build_object('ok', false, 'erro', 'nome_completo'); end if;
  if o.chamado_id is not null then
    select regexp_replace(telefone_cliente, '\D', '', 'g') into v_tel from public.chamados where id = o.chamado_id;
    if right(coalesce(v_tel, ''), 4) is distinct from right(regexp_replace(coalesce(p_tel_final, ''), '\D', '', 'g'), 4)
       or char_length(regexp_replace(coalesce(p_tel_final, ''), '\D', '', 'g')) < 4 then
      return json_build_object('ok', false, 'erro', 'telefone_nao_confere');
    end if;
  end if;
  update public.orcamentos set aceito_em = now(), aceito_nome = left(trim(p_nome), 120) where id = p_id;
  return json_build_object('ok', true, 'aceito_em', now());
end $$;

create or replace function public.meus_orcamentos()
returns setof json language sql stable security definer set search_path = public as $$
  select json_build_object('id', o.id, 'chamado_id', o.chamado_id, 'cliente_nome', o.cliente_nome, 'servico', o.servico, 'total', o.total,
    'criado_em', o.criado_em, 'aceito_em', o.aceito_em, 'aceito_nome', o.aceito_nome,
    'expirado', now() > o.criado_em + make_interval(days => o.validade_dias))
  from public.orcamentos o where o.prof_id = auth.uid() order by o.criado_em desc limit 100
$$;

-- ---------- perfis públicos com selos por uso ----------
drop function if exists public.perfis_publicos(uuid);
create or replace function public.perfis_publicos(p_id uuid default null)
returns table (id uuid, nome text, telefone text, categoria text, especialidades text, cidade text, bio text,
               registro_tipo text, selo_identidade boolean, selo_registro boolean, selo_mei boolean, emite_nf boolean,
               membro_desde timestamptz, nota_media numeric, total_avaliacoes integer, contatos integer,
               fotos integer, bem_avaliado boolean, experiente boolean, perfil_completo boolean,
               cnpj text, cnpj_razao text, reclamacoes integer, reclamacoes_respondidas integer)
language sql stable security definer set search_path = public as $$
  with base as (
    select p.*,
      (select round(avg(coalesce(a.nota, a.estrelas))::numeric, 1) from public.avaliacoes a where a.prof_id = p.id and coalesce(a.nota, a.estrelas) between 1 and 5) nota,
      (select count(*) from public.avaliacoes a where a.prof_id = p.id and coalesce(a.nota, a.estrelas) between 1 and 5)::int n_av,
      (select count(*) from public.desbloqueios d where d.prof_id = p.id)::int n_contatos,
      (select count(*) from public.portfolio f where f.prof_id = p.id)::int n_fotos,
      (select count(*) from public.ocorrencias o where o.prof_id = p.id and o.tipo = 'reclamacao' and o.criado_em > now() - interval '180 days')::int n_rec,
      (select count(*) from public.ocorrencias o where o.prof_id = p.id and o.tipo = 'reclamacao' and o.criado_em > now() - interval '180 days' and o.respondido_em is not null)::int n_resp
    from public.profissionais p
    where (p_id is null or p.id = p_id)
      and coalesce(trim(p.nome), '') <> '' and p.nome <> 'Profissional' and p.categoria is not null and coalesce(p.especialidades, '') <> ''
      and not public.prof_bloqueado(p.id))
  select b.id, b.nome, b.telefone, b.categoria::text, b.especialidades::text, b.cidade, b.bio,
         case when b.selo_registro then b.registro_tipo end,
         b.selo_identidade, b.selo_registro, b.selo_mei, b.emite_nf, b.criado_em, b.nota, b.n_av, b.n_contatos,
         b.n_fotos,
         (b.n_av >= 3 and b.nota >= 4.5),
         (b.n_contatos >= 10),
         (coalesce(b.cidade, '') <> '' and char_length(coalesce(b.bio, '')) >= 40 and b.n_fotos >= 3),
         case when b.selo_mei then b.cnpj end, case when b.selo_mei then b.cnpj_razao end,
         b.n_rec, b.n_resp
  from base b
  order by (b.selo_identidade::int + b.selo_registro::int + b.selo_mei::int) desc,
           (b.n_av >= 3 and b.nota >= 4.5) desc, b.nota desc nulls last, b.n_fotos desc, b.criado_em
$$;

-- ---------- minha conta: campos novos ----------
create or replace function public.minha_conta()
returns json language plpgsql stable security definer set search_path = public, auth as $$
declare p public.profissionais%rowtype; c public.clientes%rowtype; v_uid uuid := auth.uid();
begin
  if v_uid is null then return null; end if;
  select * into p from public.profissionais where id = v_uid;
  if found then
    return json_build_object('tipo', 'profissional', 'id', p.id, 'nome', p.nome, 'telefone', p.telefone, 'categoria', p.categoria,
      'especialidades', p.especialidades, 'saldo_creditos', p.saldo_creditos, 'is_admin', coalesce(p.is_admin, false),
      'recebe_avisos', p.recebe_avisos, 'cidade', p.cidade, 'bio', p.bio, 'registro_tipo', p.registro_tipo,
      'registro_numero', p.registro_numero, 'documento', p.documento, 'emite_nf', p.emite_nf,
      'selo_identidade', p.selo_identidade, 'selo_registro', p.selo_registro, 'selo_mei', p.selo_mei,
      'cnpj', p.cnpj, 'cnpj_razao', p.cnpj_razao, 'bonus_verificacao', p.bonus_verificacao,
      'verificacao_status', p.verificacao_status, 'verificacao_motivo', p.verificacao_motivo,
      'aceite_termos_em', p.aceite_termos_em, 'criado_em', p.criado_em,
      'suspenso', public.prof_bloqueado(p.id), 'suspenso_motivo', p.suspenso_motivo,
      'fotos', (select count(*) from public.portfolio f where f.prof_id = p.id),
      'reclamacoes_pendentes', (select count(*) from public.ocorrencias o where o.prof_id = p.id and o.tipo = 'reclamacao' and o.status = 'aguardando_profissional'),
      'email', (select email from auth.users where id = v_uid));
  end if;
  select * into c from public.clientes where id = v_uid;
  if found then
    return json_build_object('tipo', 'cliente', 'id', c.id, 'nome', c.nome, 'telefone', c.telefone, 'cidade', c.cidade, 'email', c.email);
  end if;
  return json_build_object('tipo', 'desconhecido', 'id', v_uid);
end $$;

-- ---------- desbloqueio: perfil suspenso não pega pedido novo ----------
create or replace function public.desbloquear_chamado(p_chamado_id bigint)
returns json language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_saldo integer; v_custo integer; v_n integer; c public.chamados%rowtype;
begin
  if v_uid is null then return json_build_object('ok', false, 'erro', 'nao_autenticado'); end if;
  select saldo_creditos into v_saldo from public.profissionais where id = v_uid for update;
  if not found then return json_build_object('ok', false, 'erro', 'nao_profissional'); end if;
  select * into c from public.chamados where id = p_chamado_id for update;
  if not found then return json_build_object('ok', false, 'erro', 'chamado_inexistente'); end if;
  if exists (select 1 from public.desbloqueios where prof_id = v_uid and chamado_id = p_chamado_id) then
    return json_build_object('ok', true, 'ja_desbloqueado', true, 'nome', c.nome_cliente, 'telefone', c.telefone_cliente, 'saldo', v_saldo);
  end if;
  if public.prof_bloqueado(v_uid) then return json_build_object('ok', false, 'erro', 'perfil_suspenso'); end if;
  if c.status <> 'novo' or c.criado_em < now() - interval '30 days' then
    return json_build_object('ok', false, 'erro', 'pedido_encerrado');
  end if;
  select count(*) into v_n from public.desbloqueios where chamado_id = p_chamado_id;
  if v_n >= 3 then return json_build_object('ok', false, 'erro', 'vagas_esgotadas'); end if;
  v_custo := public.custo_chamado(c.categoria);
  if v_saldo < v_custo then
    return json_build_object('ok', false, 'erro', 'saldo_insuficiente', 'saldo', v_saldo, 'custo', v_custo);
  end if;
  update public.profissionais set saldo_creditos = saldo_creditos - v_custo where id = v_uid;
  insert into public.desbloqueios (prof_id, chamado_id) values (v_uid, p_chamado_id);
  insert into public.transacoes_credito (profissional_id, valor, tipo, referencia_chamado) values (v_uid, -v_custo, 'desbloqueio', p_chamado_id);
  update public.chamados set desbloqueado_por = coalesce(desbloqueado_por, v_uid) where id = p_chamado_id;
  return json_build_object('ok', true, 'nome', c.nome_cliente, 'telefone', c.telefone_cliente, 'saldo', v_saldo - v_custo, 'custo', v_custo,
                           'vagas_restantes', 2 - v_n);
end $$;

-- ---------- pedidos do cliente: reclamação e orçamentos de cada profissional ----------
drop function if exists public.meus_pedidos() cascade;
create or replace function public.meus_pedidos()
returns table (id bigint, servico text, bairro text, descricao text, status text, criado_em timestamptz, interessados json)
language sql stable security definer set search_path = public as $$
  with eu as (select regexp_replace(coalesce(telefone, ''), '\D', '', 'g') tel from public.clientes where id = auth.uid()),
  meus as (
    select c.* from public.chamados c
    where auth.uid() is not null and (
      c.cliente_id = auth.uid()
      or exists (select 1 from eu where length(eu.tel) >= 10 and regexp_replace(c.telefone_cliente, '\D', '', 'g') = eu.tel)))
  select m.id, m.servico, m.bairro, m.descricao, m.status, m.criado_em,
    coalesce((select json_agg(json_build_object(
        'id', p.id, 'nome', p.nome, 'telefone', p.telefone, 'categoria', p.categoria,
        'selo_identidade', p.selo_identidade, 'selo_registro', p.selo_registro, 'selo_mei', p.selo_mei,
        'registro_tipo', case when p.selo_registro then p.registro_tipo end,
        'nota', (select round(avg(coalesce(a.nota, a.estrelas))::numeric, 1) from public.avaliacoes a where a.prof_id = p.id),
        'total_avaliacoes', (select count(*) from public.avaliacoes a where a.prof_id = p.id),
        'fotos', (select count(*) from public.portfolio f where f.prof_id = p.id),
        'ja_avaliei', exists (select 1 from public.avaliacoes a where a.prof_id = p.id and a.chamado_id = m.id),
        'reclamacao', (select json_build_object('id', o.id, 'status', o.status, 'resposta_prof', o.resposta_prof, 'respondido_em', o.respondido_em, 'criado_em', o.criado_em)
                         from public.ocorrencias o where o.autor_id = auth.uid() and o.chamado_id = m.id and o.prof_id = p.id and o.tipo = 'reclamacao' order by o.id desc limit 1),
        'denunciei', exists (select 1 from public.ocorrencias o where o.autor_id = auth.uid() and o.chamado_id = m.id and o.prof_id = p.id and o.tipo = 'denuncia'),
        'orcamentos', (select coalesce(json_agg(json_build_object('id', ob.id, 'total', ob.total, 'criado_em', ob.criado_em, 'aceito_em', ob.aceito_em) order by ob.criado_em), '[]'::json)
                         from public.orcamentos ob where ob.chamado_id = m.id and ob.prof_id = p.id),
        'quando', d.criado_em) order by d.criado_em)
      from public.desbloqueios d join public.profissionais p on p.id = d.prof_id where d.chamado_id = m.id), '[]'::json)
  from meus m
  order by m.criado_em desc
$$;

create or replace function public.pedido_do_cliente(p_chamado_id bigint)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.meus_pedidos() m where m.id = p_chamado_id)
$$;

create or replace function public.encerrar_pedido(p_chamado_id bigint, p_status text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if p_status not in ('atendido', 'cancelado') then return json_build_object('ok', false, 'erro', 'status_invalido'); end if;
  if not public.pedido_do_cliente(p_chamado_id) then return json_build_object('ok', false, 'erro', 'nao_e_seu'); end if;
  update public.chamados set status = p_status where id = p_chamado_id and status = 'novo';
  return json_build_object('ok', true);
end $$;

create or replace function public.avaliar_profissional(p_chamado_id bigint, p_prof_id uuid, p_nota integer, p_comentario text default null)
returns json language plpgsql security definer set search_path = public as $$
declare v_nome text;
begin
  if auth.uid() is null then return json_build_object('ok', false, 'erro', 'nao_autenticado'); end if;
  if p_nota is null or p_nota < 1 or p_nota > 5 then return json_build_object('ok', false, 'erro', 'nota_invalida'); end if;
  if not public.pedido_do_cliente(p_chamado_id) then return json_build_object('ok', false, 'erro', 'nao_e_seu'); end if;
  if not exists (select 1 from public.desbloqueios where chamado_id = p_chamado_id and prof_id = p_prof_id) then
    return json_build_object('ok', false, 'erro', 'profissional_nao_atendeu');
  end if;
  if exists (select 1 from public.avaliacoes where chamado_id = p_chamado_id and prof_id = p_prof_id) then
    return json_build_object('ok', false, 'erro', 'ja_avaliado');
  end if;
  select coalesce((select nome from public.clientes where id = auth.uid()), (select nome_cliente from public.chamados where id = p_chamado_id)) into v_nome;
  insert into public.avaliacoes (prof_id, chamado_id, nota, comentario, cliente_nome, verificada)
  values (p_prof_id, p_chamado_id, p_nota, left(nullif(trim(p_comentario), ''), 1000), split_part(coalesce(v_nome, ''), ' ', 1), true);
  return json_build_object('ok', true);
end $$;

-- ---------- reclamação: vai direto ao profissional, que tem 7 dias para responder ----------
create or replace function public.reclamar_profissional(p_chamado_id bigint, p_prof_id uuid, p_motivo text, p_descricao text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return json_build_object('ok', false, 'erro', 'nao_autenticado'); end if;
  if p_motivo not in ('servico_ruim', 'nao_compareceu', 'cobranca_indevida', 'outro') then return json_build_object('ok', false, 'erro', 'motivo_invalido'); end if;
  if char_length(coalesce(trim(p_descricao), '')) < 10 then return json_build_object('ok', false, 'erro', 'descreva'); end if;
  if not public.pedido_do_cliente(p_chamado_id) then return json_build_object('ok', false, 'erro', 'nao_e_seu'); end if;
  if not exists (select 1 from public.desbloqueios where chamado_id = p_chamado_id and prof_id = p_prof_id) then
    return json_build_object('ok', false, 'erro', 'profissional_nao_atendeu');
  end if;
  if exists (select 1 from public.ocorrencias where autor_id = auth.uid() and chamado_id = p_chamado_id and prof_id = p_prof_id and tipo = 'reclamacao') then
    return json_build_object('ok', false, 'erro', 'ja_reclamou');
  end if;
  insert into public.ocorrencias (autor_id, autor_tipo, tipo, chamado_id, prof_id, motivo, descricao, status)
  values (auth.uid(), 'cliente', 'reclamacao', p_chamado_id, p_prof_id, p_motivo, left(trim(p_descricao), 1500), 'aguardando_profissional');
  return json_build_object('ok', true);
end $$;

-- denúncia: única coisa que vai para a equipe (fatos objetivos: perfil falso, golpe, ameaça)
create or replace function public.denunciar_profissional(p_chamado_id bigint, p_prof_id uuid, p_motivo text, p_descricao text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return json_build_object('ok', false, 'erro', 'nao_autenticado'); end if;
  if p_motivo not in ('perfil_falso', 'golpe', 'ameaca') then return json_build_object('ok', false, 'erro', 'motivo_invalido'); end if;
  if char_length(coalesce(trim(p_descricao), '')) < 10 then return json_build_object('ok', false, 'erro', 'descreva'); end if;
  if not public.pedido_do_cliente(p_chamado_id) then return json_build_object('ok', false, 'erro', 'nao_e_seu'); end if;
  if not exists (select 1 from public.desbloqueios where chamado_id = p_chamado_id and prof_id = p_prof_id) then
    return json_build_object('ok', false, 'erro', 'profissional_nao_atendeu');
  end if;
  insert into public.ocorrencias (autor_id, autor_tipo, tipo, chamado_id, prof_id, motivo, descricao, status)
  values (auth.uid(), 'cliente', 'denuncia', p_chamado_id, p_prof_id, p_motivo, left(trim(p_descricao), 1500), 'aberta')
  on conflict do nothing;
  return json_build_object('ok', true);
end $$;

-- reclamações recebidas pelo profissional
create or replace function public.minhas_reclamacoes()
returns setof json language sql stable security definer set search_path = public as $$
  select json_build_object('id', o.id, 'motivo', o.motivo, 'descricao', o.descricao, 'status', o.status, 'criado_em', o.criado_em,
    'prazo', o.criado_em + interval '7 days', 'resposta_prof', o.resposta_prof, 'respondido_em', o.respondido_em,
    'chamado_id', o.chamado_id, 'servico', c.servico, 'cliente', split_part(coalesce(c.nome_cliente, ''), ' ', 1))
  from public.ocorrencias o left join public.chamados c on c.id = o.chamado_id
  where o.prof_id = auth.uid() and o.tipo = 'reclamacao'
  order by (o.status = 'aguardando_profissional') desc, o.criado_em desc
$$;

create or replace function public.responder_reclamacao(p_id bigint, p_resposta text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if char_length(coalesce(trim(p_resposta), '')) < 10 then return json_build_object('ok', false, 'erro', 'descreva'); end if;
  update public.ocorrencias set resposta_prof = left(trim(p_resposta), 1500), respondido_em = now(),
         status = case when status = 'aguardando_profissional' then 'respondida' else status end
   where id = p_id and prof_id = auth.uid() and tipo = 'reclamacao' and status in ('aguardando_profissional', 'respondida');
  if not found then return json_build_object('ok', false, 'erro', 'reclamacao_inexistente'); end if;
  return json_build_object('ok', true);
end $$;

-- cliente encerra a reclamação: resolvida ou não resolvida (só conta na regra quem não resolveu)
create or replace function public.concluir_reclamacao(p_id bigint, p_resolvida boolean)
returns json language plpgsql security definer set search_path = public as $$
begin
  update public.ocorrencias set status = case when p_resolvida then 'resolvida' else 'nao_resolvida' end, concluido_em = now(), resolvido_em = now()
   where id = p_id and autor_id = auth.uid() and tipo = 'reclamacao' and status in ('aguardando_profissional', 'respondida');
  if not found then return json_build_object('ok', false, 'erro', 'reclamacao_inexistente'); end if;
  return json_build_object('ok', true);
end $$;

-- relatório do atendimento (cliente): tudo o que foi registrado, para levar ao Procon / Juizado se precisar
create or replace function public.relatorio_pedido(p_chamado_id bigint)
returns json language plpgsql stable security definer set search_path = public as $$
declare c public.chamados%rowtype;
begin
  if not public.pedido_do_cliente(p_chamado_id) then return json_build_object('ok', false, 'erro', 'nao_e_seu'); end if;
  select * into c from public.chamados where id = p_chamado_id;
  return json_build_object('ok', true,
    'pedido', json_build_object('id', c.id, 'servico', c.servico, 'categoria', c.categoria, 'bairro', c.bairro, 'descricao', c.descricao,
                                'status', c.status, 'criado_em', c.criado_em, 'nome_cliente', c.nome_cliente, 'telefone_cliente', c.telefone_cliente,
                                'termos_versao', c.termos_versao),
    'profissionais', coalesce((select json_agg(json_build_object(
        'nome', p.nome, 'telefone', p.telefone, 'categoria', p.categoria, 'pegou_em', d.criado_em,
        'selo_identidade', p.selo_identidade, 'selo_registro', p.selo_registro,
        'registro', case when p.selo_registro then coalesce(p.registro_tipo, '') || ' ' || coalesce(p.registro_numero, '') end,
        'cnpj', case when p.selo_mei then p.cnpj end, 'cnpj_razao', case when p.selo_mei then p.cnpj_razao end,
        'orcamentos', (select coalesce(json_agg(json_build_object('id', o.id, 'total', o.total, 'itens', o.itens, 'prazo', o.prazo, 'pagamento', o.pagamento,
                         'criado_em', o.criado_em, 'aceito_em', o.aceito_em, 'aceito_nome', o.aceito_nome) order by o.criado_em), '[]'::json)
                       from public.orcamentos o where o.chamado_id = c.id and o.prof_id = p.id),
        'ocorrencias', (select coalesce(json_agg(json_build_object('tipo', oc.tipo, 'motivo', oc.motivo, 'descricao', oc.descricao, 'status', oc.status,
                         'criado_em', oc.criado_em, 'resposta_prof', oc.resposta_prof, 'respondido_em', oc.respondido_em, 'concluido_em', oc.concluido_em) order by oc.criado_em), '[]'::json)
                       from public.ocorrencias oc where oc.chamado_id = c.id and oc.prof_id = p.id and oc.autor_id = auth.uid()),
        'avaliacao', (select json_build_object('nota', coalesce(a.nota, a.estrelas), 'comentario', a.comentario, 'criado_em', a.criado_em)
                        from public.avaliacoes a where a.chamado_id = c.id and a.prof_id = p.id limit 1)) order by d.criado_em)
      from public.desbloqueios d join public.profissionais p on p.id = d.prof_id where d.chamado_id = c.id), '[]'::json),
    'gerado_em', now());
end $$;

-- ---------- verificação simplificada: CPF + uma selfie com o documento ----------
create or replace function public.enviar_verificacao(p_documento text, p_registro_tipo text, p_registro_numero text, p_emite_nf boolean, p_aceite boolean)
returns json language plpgsql security definer set search_path = public, storage as $$
declare v_uid uuid := auth.uid(); v_doc text := regexp_replace(coalesce(p_documento, ''), '\D', '', 'g'); v_status text;
begin
  if v_uid is null then return json_build_object('ok', false, 'erro', 'nao_autenticado'); end if;
  select verificacao_status into v_status from public.profissionais where id = v_uid;
  if not found then return json_build_object('ok', false, 'erro', 'nao_profissional'); end if;
  if v_status = 'aprovada' then return json_build_object('ok', false, 'erro', 'ja_aprovada'); end if;
  if not coalesce(p_aceite, false) then return json_build_object('ok', false, 'erro', 'aceite_termos'); end if;
  if length(v_doc) <> 11 then return json_build_object('ok', false, 'erro', 'documento_invalido'); end if;
  if not exists (select 1 from storage.objects where bucket_id = 'verificacoes' and name like v_uid::text || '/selfie%') then
    return json_build_object('ok', false, 'erro', 'faltam_fotos');
  end if;
  update public.profissionais set documento = v_doc,
         registro_tipo = nullif(left(trim(coalesce(p_registro_tipo, '')), 20), ''),
         registro_numero = nullif(left(trim(coalesce(p_registro_numero, '')), 40), ''),
         emite_nf = coalesce(p_emite_nf, false), verificacao_status = 'pendente', verificacao_motivo = null,
         verificacao_enviada_em = now(), aceite_termos_em = coalesce(aceite_termos_em, now())
   where id = v_uid;
  return json_build_object('ok', true);
end $$;

-- bônus de 5 créditos na primeira verificação (identidade ou CNPJ), uma vez por conta
create or replace function public.dar_bonus_verificacao(p_prof uuid)
returns integer language plpgsql security definer set search_path = public as $$
begin
  update public.profissionais set saldo_creditos = saldo_creditos + 5, bonus_verificacao = true where id = p_prof and not bonus_verificacao;
  if not found then return 0; end if;
  insert into public.transacoes_credito (profissional_id, valor, tipo) values (p_prof, 5, 'bonus');
  return 5;
end $$;

create or replace function public.admin_decidir_verificacao(p_prof_id uuid, p_identidade boolean, p_registro boolean, p_mei boolean, p_motivo text default null)
returns json language plpgsql security definer set search_path = public as $$
declare v_bonus integer := 0;
begin
  if not public.e_admin() then raise exception 'acesso negado'; end if;
  update public.profissionais set
    selo_identidade = coalesce(p_identidade, false),
    selo_registro = coalesce(p_registro, false) and registro_numero is not null,
    selo_mei = case when cnpj_verificado_em is not null then selo_mei else coalesce(p_mei, false) end,
    verificacao_status = case when coalesce(p_identidade, false) then 'aprovada' else 'recusada' end,
    verificacao_motivo = nullif(trim(coalesce(p_motivo, '')), ''),
    verificado_em = now()
  where id = p_prof_id;
  if not found then raise exception 'profissional não encontrado'; end if;
  if coalesce(p_identidade, false) then v_bonus := public.dar_bonus_verificacao(p_prof_id); end if;
  return json_build_object('ok', true, 'bonus', v_bonus);
end $$;

-- chamado só pela função verificar-cnpj (chave de serviço), depois de consultar a Receita
create or replace function public.registrar_cnpj(p_prof uuid, p_cnpj text, p_razao text, p_ok boolean)
returns json language plpgsql security definer set search_path = public as $$
declare v_cnpj text := regexp_replace(coalesce(p_cnpj, ''), '\D', '', 'g'); v_bonus integer := 0;
begin
  if length(v_cnpj) <> 14 then return json_build_object('ok', false, 'erro', 'cnpj_invalido'); end if;
  if not p_ok then
    update public.profissionais set cnpj = v_cnpj, cnpj_razao = left(p_razao, 160), selo_mei = false, cnpj_verificado_em = now() where id = p_prof;
    return json_build_object('ok', true, 'selo', false);
  end if;
  if exists (select 1 from public.profissionais where cnpj = v_cnpj and selo_mei and id <> p_prof) then
    return json_build_object('ok', false, 'erro', 'cnpj_em_uso');
  end if;
  update public.profissionais set cnpj = v_cnpj, cnpj_razao = left(p_razao, 160), selo_mei = true, cnpj_verificado_em = now() where id = p_prof;
  v_bonus := public.dar_bonus_verificacao(p_prof);
  return json_build_object('ok', true, 'selo', true, 'bonus', v_bonus);
end $$;

-- ---------- admin: só denúncias e reportes de contato pedem ação ----------
create or replace function public.admin_ocorrencias()
returns setof json language plpgsql stable security definer set search_path = public as $$
begin
  if not public.e_admin() then raise exception 'acesso negado'; end if;
  return query
    select json_build_object('id', o.id, 'tipo', o.tipo, 'autor_tipo', o.autor_tipo, 'motivo', o.motivo, 'descricao', o.descricao, 'status', o.status,
      'creditos_devolvidos', o.creditos_devolvidos, 'resposta', o.resposta, 'resposta_prof', o.resposta_prof, 'criado_em', o.criado_em,
      'chamado_id', o.chamado_id, 'servico', c.servico, 'cliente', c.nome_cliente, 'telefone_cliente', c.telefone_cliente,
      'prof_id', o.prof_id, 'prof_nome', p.nome, 'prof_telefone', p.telefone, 'prof_suspenso', coalesce(p.suspenso, false),
      'autor_nome', coalesce((select nome from public.clientes where id = o.autor_id), (select nome from public.profissionais where id = o.autor_id)))
    from public.ocorrencias o
    left join public.chamados c on c.id = o.chamado_id
    left join public.profissionais p on p.id = o.prof_id
    order by (o.status = 'aberta') desc, o.criado_em desc
    limit 300;
end $$;

create or replace function public.admin_resolver_ocorrencia(p_id bigint, p_devolver boolean, p_resposta text, p_status text default 'resolvida')
returns json language plpgsql security definer set search_path = public as $$
declare o public.ocorrencias%rowtype; v integer := 0;
begin
  if not public.e_admin() then raise exception 'acesso negado'; end if;
  if p_status not in ('resolvida', 'recusada') then raise exception 'status inválido'; end if;
  select * into o from public.ocorrencias where id = p_id for update;
  if not found then raise exception 'ocorrência não encontrada'; end if;
  if coalesce(p_devolver, false) and o.tipo = 'reporte' and o.prof_id is not null and o.chamado_id is not null then
    v := public.devolver_credito_contato(o.prof_id, o.chamado_id);
  end if;
  update public.ocorrencias set status = p_status, creditos_devolvidos = creditos_devolvidos + v,
         resposta = nullif(trim(coalesce(p_resposta, '')), ''), resolvido_em = now() where id = p_id;
  return json_build_object('ok', true, 'devolvido', v);
end $$;

create or replace function public.admin_suspender(p_prof_id uuid, p_suspender boolean, p_motivo text default null)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not public.e_admin() then raise exception 'acesso negado'; end if;
  update public.profissionais set suspenso = coalesce(p_suspender, false),
         suspenso_motivo = case when p_suspender then nullif(trim(coalesce(p_motivo, '')), '') end where id = p_prof_id;
  if not found then raise exception 'profissional não encontrado'; end if;
  return json_build_object('ok', true);
end $$;

create or replace function public.admin_profissionais()
returns setof json language plpgsql stable security definer set search_path = public, auth as $$
begin
  if not public.e_admin() then raise exception 'acesso negado'; end if;
  return query
    select json_build_object('id', p.id, 'nome', p.nome, 'telefone', p.telefone, 'categoria', p.categoria, 'especialidades', p.especialidades,
      'saldo_creditos', p.saldo_creditos, 'is_admin', p.is_admin, 'cidade', p.cidade, 'criado_em', p.criado_em,
      'email', u.email, 'documento', p.documento, 'registro_tipo', p.registro_tipo, 'registro_numero', p.registro_numero,
      'emite_nf', p.emite_nf, 'selo_identidade', p.selo_identidade, 'selo_registro', p.selo_registro, 'selo_mei', p.selo_mei,
      'cnpj', p.cnpj, 'cnpj_razao', p.cnpj_razao,
      'verificacao_status', p.verificacao_status, 'verificacao_motivo', p.verificacao_motivo, 'verificacao_enviada_em', p.verificacao_enviada_em,
      'suspenso', p.suspenso, 'bloqueado', public.prof_bloqueado(p.id), 'suspenso_motivo', p.suspenso_motivo,
      'fotos', (select count(*) from public.portfolio f where f.prof_id = p.id),
      'arquivos', (select coalesce(json_agg(o.name order by o.name), '[]'::json) from storage.objects o
                    where o.bucket_id = 'verificacoes' and o.name like p.id::text || '/%'))
    from public.profissionais p left join auth.users u on u.id = p.id
    order by (p.verificacao_status = 'pendente') desc, p.criado_em desc;
end $$;

-- ---------- quem pode chamar ----------
revoke execute on function public.carimbar_termos_pedido(), public.limite_portfolio(), public.handle_new_profissional(),
  public.prof_bloqueado(uuid), public.dar_bonus_verificacao(uuid), public.registrar_cnpj(uuid, text, text, boolean),
  public.salvar_orcamento(bigint, text, text, jsonb, text, text, integer, text), public.meus_orcamentos(),
  public.meus_pedidos(), public.pedido_do_cliente(bigint), public.reclamar_profissional(bigint, uuid, text, text),
  public.denunciar_profissional(bigint, uuid, text, text), public.minhas_reclamacoes(), public.responder_reclamacao(bigint, text),
  public.concluir_reclamacao(bigint, boolean), public.relatorio_pedido(bigint), public.admin_suspender(uuid, boolean, text),
  public.minha_conta(), public.desbloquear_chamado(bigint), public.enviar_verificacao(text, text, text, boolean, boolean),
  public.admin_decidir_verificacao(uuid, boolean, boolean, boolean, text), public.admin_ocorrencias(),
  public.admin_resolver_ocorrencia(bigint, boolean, text, text), public.admin_profissionais(),
  public.encerrar_pedido(bigint, text), public.avaliar_profissional(bigint, uuid, integer, text)
  from public, anon;
revoke execute on function public.prof_bloqueado(uuid), public.dar_bonus_verificacao(uuid), public.registrar_cnpj(uuid, text, text, boolean),
  public.pedido_do_cliente(bigint), public.carimbar_termos_pedido(), public.limite_portfolio(), public.handle_new_profissional()
  from authenticated;
grant execute on function public.registrar_cnpj(uuid, text, text, boolean) to service_role;
grant execute on function public.salvar_orcamento(bigint, text, text, jsonb, text, text, integer, text), public.meus_orcamentos(),
  public.meus_pedidos(), public.reclamar_profissional(bigint, uuid, text, text), public.denunciar_profissional(bigint, uuid, text, text),
  public.minhas_reclamacoes(), public.responder_reclamacao(bigint, text), public.concluir_reclamacao(bigint, boolean),
  public.relatorio_pedido(bigint), public.admin_suspender(uuid, boolean, text), public.minha_conta(), public.desbloquear_chamado(bigint),
  public.enviar_verificacao(text, text, text, boolean, boolean), public.admin_decidir_verificacao(uuid, boolean, boolean, boolean, text),
  public.admin_ocorrencias(), public.admin_resolver_ocorrencia(bigint, boolean, text, text), public.admin_profissionais(),
  public.encerrar_pedido(bigint, text), public.avaliar_profissional(bigint, uuid, integer, text)
  to authenticated;
grant execute on function public.ver_orcamento(uuid), public.aceitar_orcamento(uuid, text, text), public.perfis_publicos(uuid), public.versao_termos()
  to anon, authenticated;
