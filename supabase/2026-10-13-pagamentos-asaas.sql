-- =========================================================
-- Foster Central · créditos pagos pelo Asaas (2026-10-13)
-- O webhook (função asaas-creditos) chama creditar_pagamento / estornar_pagamento com a chave de serviço.
-- Pagamento de e-mail ainda sem cadastro fica pendente e cai sozinho quando o profissional se cadastra.
-- =========================================================

create table if not exists public.pagamentos_credito (
  id bigint generated always as identity primary key,
  pagamento_id text not null unique,      -- id da cobrança no Asaas (pay_...)
  email text not null,
  valor numeric(10,2),
  link_id text,
  forma text,
  creditos integer not null check (creditos > 0),
  profissional_id uuid references public.profissionais(id) on delete set null,
  status text not null check (status in ('creditado', 'sem_conta', 'estornado')),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create index if not exists pagamentos_credito_email on public.pagamentos_credito (lower(email), status);
alter table public.pagamentos_credito enable row level security;
-- o profissional vê as próprias compras; gravação só pelas funções abaixo
drop policy if exists "pagamentos_credito_le_proprio" on public.pagamentos_credito;
create policy "pagamentos_credito_le_proprio" on public.pagamentos_credito for select to authenticated using (profissional_id = auth.uid());

-- credita uma vez por cobrança; devolve 'creditado', 'sem_conta' ou 'duplicado'
create or replace function public.creditar_pagamento(p_pagamento_id text, p_email text, p_creditos integer,
  p_valor numeric default null, p_link text default null, p_forma text default null)
returns text language plpgsql security definer set search_path = public, auth as $$
declare v_prof uuid;
begin
  if exists (select 1 from public.pagamentos_credito where pagamento_id = p_pagamento_id) then return 'duplicado'; end if;
  select p.id into v_prof from public.profissionais p join auth.users u on u.id = p.id
   where lower(u.email) = lower(trim(p_email)) limit 1;
  if v_prof is null then
    insert into public.pagamentos_credito (pagamento_id, email, valor, link_id, forma, creditos, status)
      values (p_pagamento_id, lower(trim(p_email)), p_valor, p_link, p_forma, p_creditos, 'sem_conta');
    return 'sem_conta';
  end if;
  insert into public.pagamentos_credito (pagamento_id, email, valor, link_id, forma, creditos, profissional_id, status)
    values (p_pagamento_id, lower(trim(p_email)), p_valor, p_link, p_forma, p_creditos, v_prof, 'creditado');
  update public.profissionais set saldo_creditos = saldo_creditos + p_creditos where id = v_prof;
  insert into public.transacoes_credito (profissional_id, valor, tipo) values (v_prof, p_creditos, 'compra');
  return 'creditado';
end $$;

-- estorno ou chargeback: tira os créditos daquela cobrança (sem deixar o saldo negativo)
create or replace function public.estornar_pagamento(p_pagamento_id text)
returns text language plpgsql security definer set search_path = public as $$
declare r public.pagamentos_credito%rowtype; v_tirar integer;
begin
  select * into r from public.pagamentos_credito where pagamento_id = p_pagamento_id for update;
  if not found then return 'nao_encontrado'; end if;
  if r.status = 'estornado' then return 'duplicado'; end if;
  if r.status = 'creditado' and r.profissional_id is not null then
    select least(saldo_creditos, r.creditos) into v_tirar from public.profissionais where id = r.profissional_id for update;
    update public.profissionais set saldo_creditos = saldo_creditos - coalesce(v_tirar, 0) where id = r.profissional_id;
    if coalesce(v_tirar, 0) > 0 then
      insert into public.transacoes_credito (profissional_id, valor, tipo) values (r.profissional_id, -v_tirar, 'estorno');
    end if;
  end if;
  update public.pagamentos_credito set status = 'estornado', atualizado_em = now() where id = r.id;
  return 'estornado';
end $$;

-- quem pagou antes de se cadastrar recebe os créditos assim que a ficha de profissional é criada
create or replace function public.creditar_pendentes()
returns trigger language plpgsql security definer set search_path = public, auth as $$
declare v_email text; v_total integer;
begin
  select lower(email) into v_email from auth.users where id = new.id;
  if v_email is null then return new; end if;
  with pend as (
    update public.pagamentos_credito set status = 'creditado', profissional_id = new.id, atualizado_em = now()
     where status = 'sem_conta' and lower(email) = v_email returning creditos)
  select coalesce(sum(creditos), 0) into v_total from pend;
  if v_total > 0 then
    update public.profissionais set saldo_creditos = saldo_creditos + v_total where id = new.id;
    insert into public.transacoes_credito (profissional_id, valor, tipo) values (new.id, v_total, 'compra');
  end if;
  return new;
end $$;
drop trigger if exists profissionais_creditar_pendentes on public.profissionais;
create trigger profissionais_creditar_pendentes after insert on public.profissionais
  for each row execute function public.creditar_pendentes();

revoke all on public.pagamentos_credito from anon;
revoke insert, update, delete on public.pagamentos_credito from authenticated;
revoke execute on function public.creditar_pagamento(text, text, integer, numeric, text, text), public.estornar_pagamento(text), public.creditar_pendentes() from public, anon, authenticated;
grant execute on function public.creditar_pagamento(text, text, integer, numeric, text, text), public.estornar_pagamento(text) to service_role;
