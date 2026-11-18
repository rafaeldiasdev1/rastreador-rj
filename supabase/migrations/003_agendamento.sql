-- Rotina diária de cobrança: todo dia às 9h05 (Brasília)
create extension if not exists pg_cron;
create extension if not exists pg_net;

create or replace function public.chamar_rotina() returns void language plpgsql security definer set search_path = '' as $$
begin
  perform net.http_post(
    url := 'https://xpafmvjlwgmhmvhfsqrg.supabase.co/functions/v1/api/rotina',
    headers := jsonb_build_object('Content-Type', 'application/json',
                                  'x-cron-secret', (select valor from public.segredos_internos where chave = 'cron')),
    body := '{}'::jsonb,
    timeout_milliseconds := 120000
  );
end; $$;
revoke execute on function public.chamar_rotina() from public, anon, authenticated;

select cron.schedule('rotina-cobranca-diaria', '5 12 * * *', 'select public.chamar_rotina()');
