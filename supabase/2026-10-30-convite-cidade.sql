-- Cidade de atendimento já no cadastro do profissional + origem do cadastro (convite por cidade)
alter table public.profissionais add column if not exists origem text;

create or replace function public.handle_new_profissional()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
        v_aceite boolean := coalesce(m->>'aceite_termos', '') <> '';
begin
  if m->>'tipo' = 'cliente' then
    insert into public.clientes (id, nome, telefone, cidade, email, termos_versao, aceite_termos_em)
    values (new.id, coalesce(nullif(m->>'nome', ''), 'Cliente'), m->>'telefone', m->>'cidade', new.email,
            case when v_aceite then left(m->>'aceite_termos', 20) end, case when v_aceite then now() end)
    on conflict (id) do nothing;
  else
    insert into public.profissionais (id, nome, telefone, categoria, especialidades, saldo_creditos, termos_versao, aceite_termos_em, cidade, origem)
    values (new.id, coalesce(nullif(m->>'nome', ''), 'Profissional'), coalesce(m->>'telefone', ''),
            nullif(m->>'categoria', ''), nullif(m->>'especialidades', ''), 10,
            case when v_aceite then left(m->>'aceite_termos', 20) end, case when v_aceite then now() end,
            nullif(left(trim(m->>'cidade'), 80), ''), nullif(left(regexp_replace(coalesce(m->>'origem', ''), '[^a-z0-9-]', '', 'g'), 60), ''))
    on conflict (id) do nothing;
  end if;
  return new;
end $function$;

-- admin: quantos profissionais por cidade e por convite
create or replace function public.admin_profissionais_por_cidade()
 returns table(cidade text, total bigint, verificados bigint, por_convite bigint)
 language plpgsql security definer set search_path to 'public'
as $$
begin
  if not exists (select 1 from profissionais where id = auth.uid() and is_admin) then raise exception 'sem_permissao'; end if;
  return query
    select coalesce(nullif(trim(p.cidade), ''), '(sem cidade)'), count(*),
           count(*) filter (where p.selo_identidade or p.selo_registro or p.cnpj_verificado_em is not null),
           count(*) filter (where p.origem like 'convite%')
    from profissionais p group by 1 order by 2 desc;
end $$;
revoke all on function public.admin_profissionais_por_cidade() from public, anon;
grant execute on function public.admin_profissionais_por_cidade() to authenticated;
