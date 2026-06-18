-- =========================================================
-- FCS CENTRAL DE SERVIÇOS — Setup do banco no Supabase
-- Cole este script completo no SQL Editor do Supabase e clique "Run"
-- =========================================================

-- 1) Tabela de profissionais (cadastro/login)
create table if not exists profissionais (
  id uuid primary key references auth.users(id) on delete cascade,
  nome text not null,
  telefone text,
  saldo_creditos integer not null default 5, -- créditos de boas-vindas
  criado_em timestamp with time zone default now()
);

-- 2) Tabela de chamados (pedidos dos clientes)
create table if not exists chamados (
  id bigint generated always as identity primary key,
  nome_cliente text not null,
  telefone_cliente text not null,
  servico text not null,
  bairro text,
  descricao text not null,
  status text not null default 'novo', -- 'novo' | 'atendido'
  desbloqueado_por uuid references profissionais(id),
  criado_em timestamp with time zone default now()
);

-- 3) Tabela de transações de crédito (compras e gastos)
create table if not exists transacoes_credito (
  id bigint generated always as identity primary key,
  profissional_id uuid references profissionais(id) on delete cascade,
  valor integer not null, -- positivo = compra/recarga, negativo = gasto
  tipo text not null, -- 'compra' | 'desbloqueio' | 'bonus'
  referencia_chamado bigint references chamados(id),
  criado_em timestamp with time zone default now()
);

-- =========================================================
-- SEGURANÇA (Row Level Security)
-- =========================================================

alter table profissionais enable row level security;
alter table chamados enable row level security;
alter table transacoes_credito enable row level security;

-- Profissionais: cada um vê e edita só o próprio registro
create policy "profissionais_select_own"
  on profissionais for select
  using (auth.uid() = id);

create policy "profissionais_update_own"
  on profissionais for update
  using (auth.uid() = id);

create policy "profissionais_insert_own"
  on profissionais for insert
  with check (auth.uid() = id);

-- Chamados: qualquer pessoa (incluindo visitantes não logados) pode CRIAR um chamado
create policy "chamados_insert_publico"
  on chamados for insert
  with check (true);

-- Chamados: apenas profissionais logados podem VER os chamados
create policy "chamados_select_profissionais"
  on chamados for select
  using (auth.role() = 'authenticated');

-- Chamados: apenas profissionais logados podem ATUALIZAR (desbloquear/marcar atendido)
create policy "chamados_update_profissionais"
  on chamados for update
  using (auth.role() = 'authenticated');

-- Transações: cada profissional vê apenas as próprias
create policy "transacoes_select_own"
  on transacoes_credito for select
  using (auth.uid() = profissional_id);

create policy "transacoes_insert_own"
  on transacoes_credito for insert
  with check (auth.uid() = profissional_id);

-- =========================================================
-- FUNÇÃO: criar registro em "profissionais" automaticamente
-- quando um novo usuário se cadastra (auth.users)
-- =========================================================

create or replace function public.handle_new_profissional()
returns trigger as $$
begin
  insert into public.profissionais (id, nome, telefone, saldo_creditos)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'nome', 'Profissional'),
    coalesce(new.raw_user_meta_data->>'telefone', ''),
    5
  );
  return new;
end;
$$ language plpgsql security definer;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_profissional();

-- =========================================================
-- FUNÇÃO: desbloquear contato com segurança (debita crédito
-- e marca o chamado como desbloqueado em uma única transação)
-- =========================================================

create or replace function public.desbloquear_chamado(p_chamado_id bigint, p_custo integer)
returns json as $$
declare
  v_saldo integer;
  v_profissional uuid := auth.uid();
begin
  if v_profissional is null then
    return json_build_object('ok', false, 'erro', 'nao_autenticado');
  end if;

  select saldo_creditos into v_saldo
  from profissionais where id = v_profissional
  for update;

  if v_saldo < p_custo then
    return json_build_object('ok', false, 'erro', 'saldo_insuficiente', 'saldo', v_saldo);
  end if;

  update profissionais
    set saldo_creditos = saldo_creditos - p_custo
    where id = v_profissional;

  update chamados
    set desbloqueado_por = v_profissional
    where id = p_chamado_id and desbloqueado_por is null;

  insert into transacoes_credito (profissional_id, valor, tipo, referencia_chamado)
  values (v_profissional, -p_custo, 'desbloqueio', p_chamado_id);

  return json_build_object('ok', true, 'saldo', v_saldo - p_custo);
end;
$$ language plpgsql security definer;

-- =========================================================
-- FUNÇÃO: adicionar créditos (simulação de compra)
-- Em produção, isso seria chamado pelo webhook do gateway de pagamento,
-- não diretamente pelo app.
-- =========================================================

create or replace function public.adicionar_creditos(p_quantidade integer)
returns json as $$
declare
  v_profissional uuid := auth.uid();
  v_novo_saldo integer;
begin
  if v_profissional is null then
    return json_build_object('ok', false, 'erro', 'nao_autenticado');
  end if;

  update profissionais
    set saldo_creditos = saldo_creditos + p_quantidade
    where id = v_profissional
    returning saldo_creditos into v_novo_saldo;

  insert into transacoes_credito (profissional_id, valor, tipo)
  values (v_profissional, p_quantidade, 'compra');

  return json_build_object('ok', true, 'saldo', v_novo_saldo);
end;
$$ language plpgsql security definer;

-- =========================================================
-- Ativar Realtime na tabela chamados (para o painel atualizar sozinho)
-- =========================================================
alter publication supabase_realtime add table chamados;
