-- Correção: "Excluir cliente" falhava quando o cliente tinha ordem de serviço.
-- Ao excluir cliente ou veículo, as OS (e as fotos, via os_fotos) vão junto, como já acontece com cobranças e histórico.
alter table public.ordens_servico drop constraint ordens_servico_cliente_id_fkey,
  add constraint ordens_servico_cliente_id_fkey foreign key (cliente_id) references public.clientes(id) on delete cascade;
alter table public.ordens_servico drop constraint ordens_servico_veiculo_id_fkey,
  add constraint ordens_servico_veiculo_id_fkey foreign key (veiculo_id) references public.veiculos(id) on delete cascade;
