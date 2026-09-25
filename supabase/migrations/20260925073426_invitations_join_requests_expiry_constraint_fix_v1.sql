begin;

alter table public.kuri_invitations
  drop constraint if exists kuri_invitations_check1;

commit;