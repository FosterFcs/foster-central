-- =========================================================
-- Foster Central · credibilidade (2026-10-28)
-- 1) Profissional verificado: documento + selfie + registro (CREA/CAU/CFT/NR-10) num storage privado,
--    analisados pelo admin; selos que só o admin liga.
-- 2) Leads justos: no máximo 3 profissionais por pedido, pedidos com mais de 30 dias saem da lista,
--    devolução de crédito por contato inválido (automática quando 2 profissionais confirmam).
-- 3) Avaliações só de quem contratou: o cliente avalia, pelo pedido dele, quem pegou o contato.
-- 4) Ocorrências/mediação, perfil público com nota, excluir a própria conta (LGPD).
-- 5) Fecha o que não deve ser público (saldo, admin, documento) e o cadastro direto na tabela.
-- =========================================================

-- ---------- profissionais: campos novos ----------
alter table public.profissionais
  add column if not exists cidade text,
  add column if not exists bio text,
  add column if not exists registro_tipo text,
  add column if not exists registro_numero text,
  add column if not exists documento text,
  add column if not exists selo_identidade boolean not null default false,
  add column if not exists selo_registro boolean not null default false,
  add column if not exists selo_mei boolean not null default false,
  add column if not exists emite_nf boolean not null default false,
  add column if not exists verificacao_status text not null default 'nao_enviada',
  add column if not exists verificacao_motivo text,
  add column if not exists verificacao_enviada_em timestamptz,
  add column if not exists verificado_em timestamptz,
  add column if not exists aceite_termos_em timestamptz;

do $$ begin
  alter table public.profissionais add constraint profissionais_verificacao_status
    check (verificacao_status in ('nao_enviada', 'pendente', 'aprovada', 'recusada'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.profissionais add constraint profissionais_tamanhos_v2 check (
    char_length(coalesce(cidade, '')) <= 80 and char_length(coalesce(bio, '')) <= 600
    and char_length(coalesce(registro_tipo, '')) <= 20 and char_length(coalesce(registro_numero, '')) <= 40
    and char_length(coalesce(documento, '')) <= 20) not valid;
exception when duplicate_object then null; end $$;

-- ---------- profissionais: quem lê e grava o quê ----------
-- leitura pública só do que aparece no perfil; saldo, admin, documento e avisos só pelas funções
revoke all on public.profissionais from anon, authenticated;
grant select (id, nome, telefone, categoria, especialidades, criado_em, cidade, bio, registro_tipo,
              selo_identidade, selo_registro, selo_mei, emite_nf, verificacao_status) on public.profissionais to anon, authenticated;
-- o próprio profissional edita só os dados de perfil; documento e registro passam pela verificação
grant update (nome, telefone, categoria, especialidades, recebe_avisos, cidade, bio, emite_nf) on public.profissionais to authenticated;

-- a ficha só nasce pelo gatilho de cadastro (antes uma conta de cliente podia criar ficha com saldo à vontade)
drop policy if exists "profissionais_cadastro_proprio" on public.profissionais;
drop policy if exists "profissionais_edicao_propria_protegida" on public.profissionais;
drop policy if exists "profissionais_edicao_propria" on public.profissionais;
create policy "profissionais_edicao_propria" on public.profissionais for update to authenticated
  using (auth.uid() = id) with check (auth.uid() = id);

-- nome conferido no documento não muda sem nova verificação
create or replace function public.proteger_nome_verificado()
returns trigger language plpgsql set search_path = public as $$
begin
  if old.selo_identidade and new.nome is distinct from old.nome and current_user in ('authenticated', 'anon') then
    raise exception 'nome_verificado' using hint = 'Seu nome já foi conferido no documento. Para alterar, fale com o suporte.';
  end if;
  return new;
end $$;
drop trigger if exists profissionais_proteger_nome on public.profissionais;
create trigger profissionais_proteger_nome before update on public.profissionais
  for each row execute function public.proteger_nome_verificado();

-- ---------- chamados: aceite dos termos e freio de spam ----------
alter table public.chamados add column if not exists aceite_termos boolean not null default false;
grant insert (aceite_termos) on public.chamados to anon, authenticated;
do $$ begin
  alter table public.chamados add constraint chamados_status_v2 check (status in ('novo', 'atendido', 'cancelado', 'invalido')) not valid;
exception when duplicate_object then null; end $$;

create or replace function public.freio_pedidos()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_tel text := regexp_replace(coalesce(new.telefone_cliente, ''), '\D', '', 'g');
begin
  if length(v_tel) < 10 then raise exception 'telefone_invalido'; end if;
  if (select count(*) from public.chamados
       where regexp_replace(telefone_cliente, '\D', '', 'g') = v_tel and criado_em > now() - interval '24 hours') >= 3 then
    raise exception 'limite_pedidos' using hint = 'Limite de 3 pedidos por dia para o mesmo telefone.';
  end if;
  return new;
end $$;
drop trigger if exists chamados_freio on public.chamados;
create trigger chamados_freio before insert on public.chamados for each row execute function public.freio_pedidos();
revoke execute on function public.freio_pedidos(), public.proteger_nome_verificado() from public, anon, authenticated;

create index if not exists desbloqueios_chamado on public.desbloqueios (chamado_id);

-- ---------- avaliações: só pelo pedido, uma por profissional ----------
alter table public.avaliacoes add column if not exists cliente_nome text;
alter table public.avaliacoes add column if not exists verificada boolean not null default false;
drop policy if exists "public_insert_avaliacoes" on public.avaliacoes;
drop policy if exists "todos leem" on public.avaliacoes;
revoke all on public.avaliacoes from anon, authenticated;
grant select on public.avaliacoes to anon, authenticated;
create unique index if not exists avaliacoes_uma_por_pedido on public.avaliacoes (chamado_id, prof_id) where chamado_id is not null;
create index if not exists avaliacoes_prof on public.avaliacoes (prof_id);

-- outras sobras de permissão
revoke all on public.desbloqueios from anon;
revoke insert, update, delete, truncate, trigger, references on public.desbloqueios from authenticated;
revoke truncate, trigger, references on public.chamados, public.transacoes_credito, public.clientes from anon, authenticated;

-- ---------- ocorrências (contato inválido, mediação) ----------
create table if not exists public.ocorrencias (
  id bigint generated always as identity primary key,
  autor_id uuid references auth.users(id) on delete set null,
  autor_tipo text not null check (autor_tipo in ('profissional', 'cliente')),
  chamado_id bigint references public.chamados(id) on delete set null,
  prof_id uuid references public.profissionais(id) on delete set null,
  motivo text not null check (motivo in ('telefone_invalido', 'nao_responde', 'pedido_falso', 'ja_contratou', 'servico_ruim', 'nao_compareceu', 'cobranca_indevida', 'outro')),
  descricao text check (char_length(coalesce(descricao, '')) <= 1500),
  status text not null default 'aberta' check (status in ('aberta', 'resolvida', 'recusada')),
  creditos_devolvidos integer not null default 0,
  resposta text check (char_length(coalesce(resposta, '')) <= 1000),
  criado_em timestamptz not null default now(),
  resolvido_em timestamptz
);
create unique index if not exists ocorrencias_uma_por_contato on public.ocorrencias (autor_id, chamado_id, coalesce(prof_id, '00000000-0000-0000-0000-000000000000'::uuid));
alter table public.ocorrencias enable row level security;
drop policy if exists "ocorrencias_le_propria" on public.ocorrencias;
create policy "ocorrencias_le_propria" on public.ocorrencias for select to authenticated using (autor_id = auth.uid());
revoke all on public.ocorrencias from anon;
revoke insert, update, delete, truncate on public.ocorrencias from authenticated;

-- ---------- storage privado dos documentos ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('verificacoes', 'verificacoes', false, 6291456, array['image/jpeg', 'image/png', 'image/webp', 'application/pdf'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "verificacoes_envia_propria" on storage.objects;
drop policy if exists "verificacoes_troca_propria" on storage.objects;
drop policy if exists "verificacoes_le_propria_ou_admin" on storage.objects;
drop policy if exists "verificacoes_apaga_propria" on storage.objects;
create policy "verificacoes_envia_propria" on storage.objects for insert to authenticated
  with check (bucket_id = 'verificacoes' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "verificacoes_troca_propria" on storage.objects for update to authenticated
  using (bucket_id = 'verificacoes' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'verificacoes' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "verificacoes_le_propria_ou_admin" on storage.objects for select to authenticated
  using (bucket_id = 'verificacoes' and ((storage.foldername(name))[1] = auth.uid()::text or public.e_admin()));
create policy "verificacoes_apaga_propria" on storage.objects for delete to authenticated
  using (bucket_id = 'verificacoes' and ((storage.foldername(name))[1] = auth.uid()::text or public.e_admin()));

-- =========================================================
-- FUNÇÕES
-- =========================================================

-- quem está logado: profissional (com os dados privados dele) ou cliente
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
      'verificacao_status', p.verificacao_status, 'verificacao_motivo', p.verificacao_motivo,
      'aceite_termos_em', p.aceite_termos_em, 'criado_em', p.criado_em,
      'email', (select email from auth.users where id = v_uid));
  end if;
  select * into c from public.clientes where id = v_uid;
  if found then
    return json_build_object('tipo', 'cliente', 'id', c.id, 'nome', c.nome, 'telefone', c.telefone, 'cidade', c.cidade, 'email', c.email);
  end if;
  return json_build_object('tipo', 'desconhecido', 'id', v_uid);
end $$;

-- perfis públicos com nota, selos e quantos contatos já pegou
create or replace function public.perfis_publicos(p_id uuid default null)
returns table (id uuid, nome text, telefone text, categoria text, especialidades text, cidade text, bio text,
               registro_tipo text, selo_identidade boolean, selo_registro boolean, selo_mei boolean, emite_nf boolean,
               membro_desde timestamptz, nota_media numeric, total_avaliacoes integer, contatos integer)
language sql stable security definer set search_path = public as $$
  select p.id, p.nome, p.telefone, p.categoria::text, p.especialidades::text, p.cidade, p.bio,
         case when p.selo_registro then p.registro_tipo end,
         p.selo_identidade, p.selo_registro, p.selo_mei, p.emite_nf, p.criado_em,
         round(avg(coalesce(a.nota, a.estrelas))::numeric, 1), count(a.id)::int,
         (select count(*) from public.desbloqueios d where d.prof_id = p.id)::int
  from public.profissionais p
  left join public.avaliacoes a on a.prof_id = p.id and coalesce(a.nota, a.estrelas) between 1 and 5
  where (p_id is null or p.id = p_id)
    and coalesce(trim(p.nome), '') <> '' and p.nome <> 'Profissional' and p.categoria is not null and coalesce(p.especialidades, '') <> ''
  group by p.id
  order by (p.selo_identidade::int + p.selo_registro::int) desc, round(avg(coalesce(a.nota, a.estrelas))::numeric, 1) desc nulls last, p.criado_em
$$;

-- avaliações para a vitrine (só o primeiro nome de quem avaliou)
create or replace function public.avaliacoes_publicas(p_prof uuid default null, p_limite integer default 20)
returns table (id bigint, prof_id uuid, prof_nome text, nota integer, comentario text, cliente text, servico text, verificada boolean, criado_em timestamptz)
language sql stable security definer set search_path = public as $$
  select a.id, a.prof_id, p.nome, coalesce(a.nota, a.estrelas), coalesce(a.comentario, a.comentarios),
         split_part(coalesce(a.cliente_nome, ''), ' ', 1), c.servico, a.verificada, a.criado_em
  from public.avaliacoes a
  join public.profissionais p on p.id = a.prof_id
  left join public.chamados c on c.id = a.chamado_id
  where (p_prof is null or a.prof_id = p_prof) and coalesce(a.nota, a.estrelas) between 1 and 5
  order by a.criado_em desc
  limit least(greatest(coalesce(p_limite, 20), 1), 100)
$$;

create or replace function public.estatisticas_publicas()
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'profissionais', (select count(*) from public.profissionais where categoria is not null and coalesce(especialidades, '') <> ''),
    'verificados', (select count(*) from public.profissionais where selo_identidade),
    'pedidos', (select count(*) from public.chamados),
    'avaliacoes', (select count(*) from public.avaliacoes),
    'nota_media', (select round(avg(coalesce(nota, estrelas))::numeric, 1) from public.avaliacoes where coalesce(nota, estrelas) between 1 and 5))
$$;

-- pedidos para o painel do profissional: vagas, custo e (se já pagou) o contato
create or replace function public.pedidos_disponiveis()
returns table (id bigint, servico text, categoria text, bairro text, descricao text, status text, criado_em timestamptz,
               custo integer, vagas_restantes integer, desbloqueado boolean, nome_cliente text, telefone_cliente text,
               desbloqueado_em timestamptz, minha_ocorrencia text)
language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_cat text;
begin
  if v_uid is null then return; end if;
  select p.categoria into v_cat from public.profissionais p where p.id = v_uid;
  if not found then return; end if;
  return query
  with contagem as (select d.chamado_id, count(*)::int n from public.desbloqueios d group by d.chamado_id),
       meus as (select d.chamado_id, d.criado_em from public.desbloqueios d where d.prof_id = v_uid)
  select c.id, c.servico, c.categoria, c.bairro, c.descricao, c.status, c.criado_em,
         public.custo_chamado(c.categoria), greatest(3 - coalesce(k.n, 0), 0),
         m.chamado_id is not null,
         case when m.chamado_id is not null then c.nome_cliente end,
         case when m.chamado_id is not null then c.telefone_cliente end,
         m.criado_em,
         (select o.status || ':' || o.motivo from public.ocorrencias o where o.autor_id = v_uid and o.chamado_id = c.id order by o.id desc limit 1)
  from public.chamados c
  left join contagem k on k.chamado_id = c.id
  left join meus m on m.chamado_id = c.id
  where (m.chamado_id is not null and c.criado_em > now() - interval '120 days')
     or (c.status = 'novo' and c.criado_em > now() - interval '30 days' and coalesce(k.n, 0) < 3)
  order by (m.chamado_id is null) desc, (c.categoria = v_cat) desc nulls last, c.criado_em desc;
end $$;

-- desbloqueio com limite de 3 profissionais por pedido
drop function if exists public.desbloquear_chamado(bigint);
create or replace function public.desbloquear_chamado(p_chamado_id bigint)
returns json language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_saldo integer; v_custo integer; v_n integer; c public.chamados%rowtype;
begin
  if v_uid is null then return json_build_object('ok', false, 'erro', 'nao_autenticado'); end if;
  select saldo_creditos into v_saldo from public.profissionais where id = v_uid for update;
  if not found then return json_build_object('ok', false, 'erro', 'nao_profissional'); end if;
  -- trava o pedido: dois profissionais ao mesmo tempo não passam do limite
  select * into c from public.chamados where id = p_chamado_id for update;
  if not found then return json_build_object('ok', false, 'erro', 'chamado_inexistente'); end if;

  if exists (select 1 from public.desbloqueios where prof_id = v_uid and chamado_id = p_chamado_id) then
    return json_build_object('ok', true, 'ja_desbloqueado', true, 'nome', c.nome_cliente, 'telefone', c.telefone_cliente, 'saldo', v_saldo);
  end if;
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

-- devolve o que o profissional pagou por um contato (uma vez só)
create or replace function public.devolver_credito_contato(p_prof uuid, p_chamado bigint)
returns integer language plpgsql security definer set search_path = public as $$
declare v_pago integer;
begin
  if exists (select 1 from public.transacoes_credito where profissional_id = p_prof and referencia_chamado = p_chamado and tipo = 'devolucao') then
    return 0;
  end if;
  select coalesce(-sum(valor), 0) into v_pago from public.transacoes_credito
   where profissional_id = p_prof and referencia_chamado = p_chamado and tipo = 'desbloqueio';
  if v_pago <= 0 then return 0; end if;
  update public.profissionais set saldo_creditos = saldo_creditos + v_pago where id = p_prof;
  insert into public.transacoes_credito (profissional_id, valor, tipo, referencia_chamado) values (p_prof, v_pago, 'devolucao', p_chamado);
  return v_pago;
end $$;

-- profissional reporta um contato que pagou (até 7 dias depois)
create or replace function public.reportar_contato(p_chamado_id bigint, p_motivo text, p_descricao text default null)
returns json language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_desb timestamptz; v_outros integer; v_dev integer := 0; r record;
begin
  if v_uid is null then return json_build_object('ok', false, 'erro', 'nao_autenticado'); end if;
  if p_motivo not in ('telefone_invalido', 'nao_responde', 'pedido_falso', 'ja_contratou', 'outro') then
    return json_build_object('ok', false, 'erro', 'motivo_invalido');
  end if;
  select criado_em into v_desb from public.desbloqueios where prof_id = v_uid and chamado_id = p_chamado_id;
  if not found then return json_build_object('ok', false, 'erro', 'sem_desbloqueio'); end if;
  if v_desb < now() - interval '7 days' then return json_build_object('ok', false, 'erro', 'prazo_encerrado'); end if;
  if exists (select 1 from public.ocorrencias where autor_id = v_uid and chamado_id = p_chamado_id) then
    return json_build_object('ok', false, 'erro', 'ja_reportado');
  end if;

  insert into public.ocorrencias (autor_id, autor_tipo, chamado_id, prof_id, motivo, descricao)
  values (v_uid, 'profissional', p_chamado_id, v_uid, p_motivo, left(nullif(trim(p_descricao), ''), 1500));

  -- dois profissionais diferentes confirmando contato falso/inválido: pedido sai do ar e todos que reportaram recebem de volta
  if p_motivo in ('telefone_invalido', 'pedido_falso') then
    select count(distinct autor_id) into v_outros from public.ocorrencias
     where chamado_id = p_chamado_id and autor_tipo = 'profissional' and motivo in ('telefone_invalido', 'pedido_falso');
    if v_outros >= 2 then
      update public.chamados set status = 'invalido' where id = p_chamado_id;
      for r in select o.id, o.autor_id from public.ocorrencias o
                where o.chamado_id = p_chamado_id and o.autor_tipo = 'profissional' and o.status = 'aberta'
                  and o.motivo in ('telefone_invalido', 'pedido_falso') loop
        declare v integer;
        begin
          v := public.devolver_credito_contato(r.autor_id, p_chamado_id);
          update public.ocorrencias set status = 'resolvida', creditos_devolvidos = v, resolvido_em = now(),
                 resposta = 'Confirmado por mais de um profissional: crédito devolvido automaticamente.' where id = r.id;
          if r.autor_id = v_uid then v_dev := v; end if;
        end;
      end loop;
      return json_build_object('ok', true, 'devolvido', v_dev, 'automatico', true);
    end if;
  end if;
  return json_build_object('ok', true, 'devolvido', 0, 'automatico', false);
end $$;

-- pedidos do cliente, com quem pegou o contato (para ele chamar, escolher e avaliar)
drop function if exists public.meus_pedidos();
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
        'selo_identidade', p.selo_identidade, 'selo_registro', p.selo_registro, 'registro_tipo', case when p.selo_registro then p.registro_tipo end,
        'nota', (select round(avg(coalesce(a.nota, a.estrelas))::numeric, 1) from public.avaliacoes a where a.prof_id = p.id),
        'total_avaliacoes', (select count(*) from public.avaliacoes a where a.prof_id = p.id),
        'ja_avaliei', exists (select 1 from public.avaliacoes a where a.prof_id = p.id and a.chamado_id = m.id),
        'reclamei', exists (select 1 from public.ocorrencias o where o.autor_id = auth.uid() and o.chamado_id = m.id and o.prof_id = p.id),
        'quando', d.criado_em) order by d.criado_em)
      from public.desbloqueios d join public.profissionais p on p.id = d.prof_id where d.chamado_id = m.id), '[]'::json)
  from meus m
  order by m.criado_em desc
$$;

create or replace function public.pedido_do_cliente(p_chamado_id bigint)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.meus_pedidos() m where m.id = p_chamado_id)
$$;

-- cliente encerra o pedido (contratou alguém ou desistiu): ninguém mais paga por esse contato
create or replace function public.encerrar_pedido(p_chamado_id bigint, p_status text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if p_status not in ('atendido', 'cancelado') then return json_build_object('ok', false, 'erro', 'status_invalido'); end if;
  if not public.pedido_do_cliente(p_chamado_id) then return json_build_object('ok', false, 'erro', 'nao_e_seu'); end if;
  update public.chamados set status = p_status where id = p_chamado_id and status = 'novo';
  return json_build_object('ok', true);
end $$;

-- cliente avalia quem pegou o contato do pedido dele
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

-- cliente pede mediação sobre um profissional do pedido dele
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
  insert into public.ocorrencias (autor_id, autor_tipo, chamado_id, prof_id, motivo, descricao)
  values (auth.uid(), 'cliente', p_chamado_id, p_prof_id, p_motivo, left(trim(p_descricao), 1500))
  on conflict do nothing;
  return json_build_object('ok', true);
end $$;

-- profissional envia (ou reenvia) os dados da verificação; os arquivos já subiram para o storage privado
create or replace function public.enviar_verificacao(p_documento text, p_registro_tipo text, p_registro_numero text, p_emite_nf boolean, p_aceite boolean)
returns json language plpgsql security definer set search_path = public, storage as $$
declare v_uid uuid := auth.uid(); v_doc text := regexp_replace(coalesce(p_documento, ''), '\D', '', 'g'); v_status text;
begin
  if v_uid is null then return json_build_object('ok', false, 'erro', 'nao_autenticado'); end if;
  select verificacao_status into v_status from public.profissionais where id = v_uid;
  if not found then return json_build_object('ok', false, 'erro', 'nao_profissional'); end if;
  if v_status = 'aprovada' then return json_build_object('ok', false, 'erro', 'ja_aprovada'); end if;
  if not coalesce(p_aceite, false) then return json_build_object('ok', false, 'erro', 'aceite_termos'); end if;
  if length(v_doc) not in (11, 14) then return json_build_object('ok', false, 'erro', 'documento_invalido'); end if;
  if not exists (select 1 from storage.objects where bucket_id = 'verificacoes' and name like v_uid::text || '/documento%')
     or not exists (select 1 from storage.objects where bucket_id = 'verificacoes' and name like v_uid::text || '/selfie%') then
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

-- o profissional (ou cliente) apaga a própria conta — LGPD
create or replace function public.excluir_minha_conta()
returns json language plpgsql security definer set search_path = public, auth as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then return json_build_object('ok', false, 'erro', 'nao_autenticado'); end if;
  if coalesce((select is_admin from public.profissionais where id = v_uid), false) then
    return json_build_object('ok', false, 'erro', 'admin');
  end if;
  update public.ocorrencias set autor_id = null where autor_id = v_uid;
  update public.ocorrencias set prof_id = null where prof_id = v_uid;
  delete from public.avaliacoes where prof_id = v_uid;
  delete from public.desbloqueios where prof_id = v_uid;
  update public.chamados set desbloqueado_por = null where desbloqueado_por = v_uid;
  update public.chamados set cliente_id = null where cliente_id = v_uid;
  delete from public.profissionais where id = v_uid;
  delete from public.clientes where id = v_uid;
  delete from auth.users where id = v_uid;
  return json_build_object('ok', true);
end $$;

-- ---------- painel admin ----------
create or replace function public.admin_profissionais()
returns setof json language plpgsql stable security definer set search_path = public, auth as $$
begin
  if not public.e_admin() then raise exception 'acesso negado'; end if;
  return query
    select json_build_object('id', p.id, 'nome', p.nome, 'telefone', p.telefone, 'categoria', p.categoria, 'especialidades', p.especialidades,
      'saldo_creditos', p.saldo_creditos, 'is_admin', p.is_admin, 'cidade', p.cidade, 'criado_em', p.criado_em,
      'email', u.email, 'documento', p.documento, 'registro_tipo', p.registro_tipo, 'registro_numero', p.registro_numero,
      'emite_nf', p.emite_nf, 'selo_identidade', p.selo_identidade, 'selo_registro', p.selo_registro, 'selo_mei', p.selo_mei,
      'verificacao_status', p.verificacao_status, 'verificacao_motivo', p.verificacao_motivo, 'verificacao_enviada_em', p.verificacao_enviada_em,
      'arquivos', (select coalesce(json_agg(o.name order by o.name), '[]'::json) from storage.objects o
                    where o.bucket_id = 'verificacoes' and o.name like p.id::text || '/%'))
    from public.profissionais p left join auth.users u on u.id = p.id
    order by (p.verificacao_status = 'pendente') desc, p.criado_em desc;
end $$;

create or replace function public.admin_decidir_verificacao(p_prof_id uuid, p_identidade boolean, p_registro boolean, p_mei boolean, p_motivo text default null)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not public.e_admin() then raise exception 'acesso negado'; end if;
  update public.profissionais set
    selo_identidade = coalesce(p_identidade, false),
    selo_registro = coalesce(p_registro, false) and registro_numero is not null,
    selo_mei = coalesce(p_mei, false),
    verificacao_status = case when coalesce(p_identidade, false) then 'aprovada' else 'recusada' end,
    verificacao_motivo = nullif(trim(coalesce(p_motivo, '')), ''),
    verificado_em = now()
  where id = p_prof_id;
  if not found then raise exception 'profissional não encontrado'; end if;
  return json_build_object('ok', true);
end $$;

create or replace function public.admin_ocorrencias()
returns setof json language plpgsql stable security definer set search_path = public as $$
begin
  if not public.e_admin() then raise exception 'acesso negado'; end if;
  return query
    select json_build_object('id', o.id, 'autor_tipo', o.autor_tipo, 'motivo', o.motivo, 'descricao', o.descricao, 'status', o.status,
      'creditos_devolvidos', o.creditos_devolvidos, 'resposta', o.resposta, 'criado_em', o.criado_em,
      'chamado_id', o.chamado_id, 'servico', c.servico, 'cliente', c.nome_cliente, 'telefone_cliente', c.telefone_cliente,
      'prof_id', o.prof_id, 'prof_nome', p.nome, 'prof_telefone', p.telefone,
      'autor_nome', coalesce((select nome from public.clientes where id = o.autor_id), (select nome from public.profissionais where id = o.autor_id)))
    from public.ocorrencias o
    left join public.chamados c on c.id = o.chamado_id
    left join public.profissionais p on p.id = o.prof_id
    order by (o.status = 'aberta') desc, o.criado_em desc
    limit 200;
end $$;

create or replace function public.admin_resolver_ocorrencia(p_id bigint, p_devolver boolean, p_resposta text, p_status text default 'resolvida')
returns json language plpgsql security definer set search_path = public as $$
declare o public.ocorrencias%rowtype; v integer := 0;
begin
  if not public.e_admin() then raise exception 'acesso negado'; end if;
  if p_status not in ('resolvida', 'recusada') then raise exception 'status inválido'; end if;
  select * into o from public.ocorrencias where id = p_id for update;
  if not found then raise exception 'ocorrência não encontrada'; end if;
  if coalesce(p_devolver, false) and o.autor_tipo = 'profissional' and o.prof_id is not null and o.chamado_id is not null then
    v := public.devolver_credito_contato(o.prof_id, o.chamado_id);
  end if;
  update public.ocorrencias set status = p_status, creditos_devolvidos = creditos_devolvidos + v,
         resposta = nullif(trim(coalesce(p_resposta, '')), ''), resolvido_em = now() where id = p_id;
  return json_build_object('ok', true, 'devolvido', v);
end $$;

create or replace function public.admin_marcar_pedido(p_chamado_id bigint, p_status text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not public.e_admin() then raise exception 'acesso negado'; end if;
  if p_status not in ('novo', 'atendido', 'cancelado', 'invalido') then raise exception 'status inválido'; end if;
  update public.chamados set status = p_status where id = p_chamado_id;
  return json_build_object('ok', true);
end $$;

create or replace function public.admin_excluir_profissional(p_prof_id uuid)
returns json language plpgsql security definer set search_path = public, auth as $$
begin
  if not public.e_admin() then raise exception 'acesso negado'; end if;
  if p_prof_id = auth.uid() then raise exception 'não é possível excluir a própria conta'; end if;
  update public.ocorrencias set prof_id = null where prof_id = p_prof_id;
  update public.ocorrencias set autor_id = null where autor_id = p_prof_id;
  delete from public.desbloqueios where prof_id = p_prof_id;
  delete from public.avaliacoes where prof_id = p_prof_id;
  update public.chamados set desbloqueado_por = null where desbloqueado_por = p_prof_id;
  delete from public.profissionais where id = p_prof_id;
  delete from auth.users where id = p_prof_id;
  return json_build_object('ok', true);
end $$;

-- ---------- quem pode chamar ----------
revoke execute on function public.minha_conta(), public.pedidos_disponiveis(), public.desbloquear_chamado(bigint),
  public.devolver_credito_contato(uuid, bigint), public.reportar_contato(bigint, text, text), public.meus_pedidos(),
  public.pedido_do_cliente(bigint), public.encerrar_pedido(bigint, text), public.avaliar_profissional(bigint, uuid, integer, text),
  public.reclamar_profissional(bigint, uuid, text, text), public.enviar_verificacao(text, text, text, boolean, boolean),
  public.excluir_minha_conta(), public.admin_profissionais(), public.admin_decidir_verificacao(uuid, boolean, boolean, boolean, text),
  public.admin_ocorrencias(), public.admin_resolver_ocorrencia(bigint, boolean, text, text), public.admin_marcar_pedido(bigint, text),
  public.admin_excluir_profissional(uuid)
  from public, anon;
revoke execute on function public.devolver_credito_contato(uuid, bigint), public.pedido_do_cliente(bigint) from authenticated;
grant execute on function public.minha_conta(), public.pedidos_disponiveis(), public.desbloquear_chamado(bigint),
  public.reportar_contato(bigint, text, text), public.meus_pedidos(), public.encerrar_pedido(bigint, text),
  public.avaliar_profissional(bigint, uuid, integer, text), public.reclamar_profissional(bigint, uuid, text, text),
  public.enviar_verificacao(text, text, text, boolean, boolean), public.excluir_minha_conta(),
  public.admin_profissionais(), public.admin_decidir_verificacao(uuid, boolean, boolean, boolean, text),
  public.admin_ocorrencias(), public.admin_resolver_ocorrencia(bigint, boolean, text, text), public.admin_marcar_pedido(bigint, text),
  public.admin_excluir_profissional(uuid)
  to authenticated;
grant execute on function public.perfis_publicos(uuid), public.avaliacoes_publicas(uuid, integer), public.estatisticas_publicas() to anon, authenticated;
