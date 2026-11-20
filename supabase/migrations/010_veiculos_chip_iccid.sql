-- ICCID do chip (19-20 dígitos impressos no cartão SIM, começa com 89).
-- A operadora pede esse número para bloquear, trocar ou consultar a linha.
alter table public.veiculos
  add column if not exists chip_iccid text;

alter table public.veiculos
  drop constraint if exists veiculos_chip_iccid_formato,
  add constraint veiculos_chip_iccid_formato
    check (chip_iccid is null or chip_iccid ~ '^89[0-9]{16,20}$');

-- um mesmo chip não pode estar em dois veículos
create unique index if not exists veiculos_chip_iccid_unico
  on public.veiculos (chip_iccid) where chip_iccid is not null;

comment on column public.veiculos.chip_iccid is 'ICCID do chip (só dígitos, começa com 89). Usado para falar com a operadora.';
