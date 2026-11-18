alter table public.veiculos
  add column if not exists tipo text not null default 'carro'
  check (tipo in ('carro','moto','caminhao','outros'));
