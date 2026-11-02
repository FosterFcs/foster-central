-- Bloqueia pedido repetido: mesmo telefone + mesmo serviço nas últimas 24 h (ignora pedidos cancelados/inválidos).
-- Mantém o limite de 3 pedidos por dia por telefone.
create or replace function public.freio_pedidos()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_tel text := regexp_replace(coalesce(new.telefone_cliente, ''), '\D', '', 'g');
begin
  if length(v_tel) < 10 then raise exception 'telefone_invalido'; end if;
  if exists (select 1 from public.chamados
       where regexp_replace(telefone_cliente, '\D', '', 'g') = v_tel
         and lower(trim(coalesce(servico, ''))) = lower(trim(coalesce(new.servico, '')))
         and coalesce(status, '') not in ('cancelado', 'invalido')
         and criado_em > now() - interval '24 hours') then
    raise exception 'pedido_duplicado' using hint = 'Já existe um pedido deste serviço com este telefone nas últimas 24 horas.';
  end if;
  if (select count(*) from public.chamados
       where regexp_replace(telefone_cliente, '\D', '', 'g') = v_tel and criado_em > now() - interval '24 hours') >= 3 then
    raise exception 'limite_pedidos' using hint = 'Limite de 3 pedidos por dia para o mesmo telefone.';
  end if;
  return new;
end $function$;
