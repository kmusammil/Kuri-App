begin;

revoke all on function public.enforce_kuri_status_transition() from public;
revoke all on function public.enforce_cycle_status_transition() from public;
revoke all on function public.enforce_draw_status_transition() from public;
revoke all on function public.enforce_payout_status_transition() from public;
revoke all on function public.enforce_membership_status_transition() from public;
revoke all on function public.enforce_membership_exit_status_transition() from public;

alter table public._state_machine_context enable row level security;
revoke all on table public._state_machine_context from anon, authenticated;

do $$
declare old_s text; new_s text; rejected boolean; expected_valid boolean;
begin
  create temp table sm_kuri(id integer primary key, status public.kuri_status);
  create trigger sm_kuri_guard before update of status on sm_kuri for each row execute function public.enforce_kuri_status_transition();
  foreach old_s in array array['DRAFT','OPEN','ACTIVE','COMPLETED','ARCHIVED'] loop
    foreach new_s in array array['DRAFT','OPEN','ACTIVE','COMPLETED','ARCHIVED'] loop
      expected_valid := (old_s='DRAFT' and new_s='OPEN') or (old_s='OPEN' and new_s='ACTIVE') or (old_s='ACTIVE' and new_s='COMPLETED') or (old_s='COMPLETED' and new_s='ARCHIVED') or old_s=new_s;
      truncate sm_kuri; insert into sm_kuri values(1,old_s::public.kuri_status);
      rejected:=false; begin update sm_kuri set status=new_s::public.kuri_status where id=1; exception when others then rejected:=true; end;
      if rejected <> (not expected_valid) then raise exception 'Kuri transition matrix failure: % -> %',old_s,new_s; end if;
    end loop;
  end loop;

  create temp table sm_cycle(id integer primary key, status public.cycle_status);
  create trigger sm_cycle_guard before update of status on sm_cycle for each row execute function public.enforce_cycle_status_transition();
  foreach old_s in array array['UPCOMING','OPEN','PAYMENT_CLOSED','DRAW_PENDING','COMPLETED','CANCELLED'] loop
    foreach new_s in array array['UPCOMING','OPEN','PAYMENT_CLOSED','DRAW_PENDING','COMPLETED','CANCELLED'] loop
      expected_valid := (old_s='UPCOMING' and new_s='OPEN') or (old_s='OPEN' and new_s='PAYMENT_CLOSED') or (old_s='PAYMENT_CLOSED' and new_s='DRAW_PENDING') or (old_s='DRAW_PENDING' and new_s='COMPLETED') or (old_s in ('UPCOMING','OPEN','PAYMENT_CLOSED','DRAW_PENDING') and new_s='CANCELLED') or old_s=new_s;
      truncate sm_cycle; insert into sm_cycle values(1,old_s::public.cycle_status);
      rejected:=false; begin update sm_cycle set status=new_s::public.cycle_status where id=1; exception when others then rejected:=true; end;
      if rejected <> (not expected_valid) then raise exception 'Cycle transition matrix failure: % -> %',old_s,new_s; end if;
    end loop;
  end loop;

  create temp table sm_draw(id integer primary key, status public.draw_status);
  create trigger sm_draw_guard before update of status on sm_draw for each row execute function public.enforce_draw_status_transition();
  foreach old_s in array array['DRAFT','POOL_READY','DRAWING','RESULTS_READY','FINALIZED','CANCELLED'] loop
    foreach new_s in array array['DRAFT','POOL_READY','DRAWING','RESULTS_READY','FINALIZED','CANCELLED'] loop
      expected_valid := (old_s='DRAFT' and new_s='POOL_READY') or (old_s='POOL_READY' and new_s in ('DRAWING','CANCELLED')) or (old_s='DRAWING' and new_s in ('RESULTS_READY','CANCELLED')) or (old_s='RESULTS_READY' and new_s='FINALIZED') or old_s=new_s;
      truncate sm_draw; insert into sm_draw values(1,old_s::public.draw_status);
      rejected:=false; begin update sm_draw set status=new_s::public.draw_status where id=1; exception when others then rejected:=true; end;
      if rejected <> (not expected_valid) then raise exception 'Draw transition matrix failure: % -> %',old_s,new_s; end if;
    end loop;
  end loop;

  create temp table sm_payout(id integer primary key, status public.payout_status);
  create trigger sm_payout_guard before update of status on sm_payout for each row execute function public.enforce_payout_status_transition();
  foreach old_s in array array['PENDING','PROCESSING','PAID','CANCELLED'] loop
    foreach new_s in array array['PENDING','PROCESSING','PAID','CANCELLED'] loop
      expected_valid := (old_s='PENDING' and new_s in ('PROCESSING','CANCELLED')) or (old_s='PROCESSING' and new_s in ('PAID','CANCELLED')) or old_s=new_s;
      truncate sm_payout; insert into sm_payout values(1,old_s::public.payout_status);
      rejected:=false; begin update sm_payout set status=new_s::public.payout_status where id=1; exception when others then rejected:=true; end;
      if rejected <> (not expected_valid) then raise exception 'Payout transition matrix failure: % -> %',old_s,new_s; end if;
    end loop;
  end loop;

  create temp table sm_membership(id integer primary key, status public.membership_status);
  create trigger sm_membership_guard before update of status on sm_membership for each row execute function public.enforce_membership_status_transition();
  foreach old_s in array array['PENDING','ACTIVE','SUSPENDED','EXITED','COMPLETED','TRANSFERRED'] loop
    foreach new_s in array array['PENDING','ACTIVE','SUSPENDED','EXITED','COMPLETED','TRANSFERRED'] loop
      expected_valid := (old_s='PENDING' and new_s='ACTIVE') or (old_s='ACTIVE' and new_s in ('SUSPENDED','EXITED','COMPLETED','TRANSFERRED')) or (old_s='SUSPENDED' and new_s in ('ACTIVE','EXITED','COMPLETED','TRANSFERRED')) or old_s=new_s;
      truncate sm_membership; insert into sm_membership values(1,old_s::public.membership_status);
      rejected:=false; begin update sm_membership set status=new_s::public.membership_status where id=1; exception when others then rejected:=true; end;
      if rejected <> (not expected_valid) then raise exception 'Membership transition matrix failure: % -> %',old_s,new_s; end if;
    end loop;
  end loop;

  create temp table sm_exit(id integer primary key, status public.settlement_status);
  create trigger sm_exit_guard before update of status on sm_exit for each row execute function public.enforce_membership_exit_status_transition();
  foreach old_s in array array['PENDING','APPROVED','SETTLED','CANCELLED'] loop
    foreach new_s in array array['PENDING','APPROVED','SETTLED','CANCELLED'] loop
      expected_valid := (old_s='PENDING' and new_s in ('APPROVED','CANCELLED')) or (old_s='APPROVED' and new_s in ('SETTLED','CANCELLED')) or old_s=new_s;
      truncate sm_exit; insert into sm_exit values(1,old_s::public.settlement_status);
      rejected:=false; begin update sm_exit set status=new_s::public.settlement_status where id=1; exception when others then rejected:=true; end;
      if rejected <> (not expected_valid) then raise exception 'Membership exit transition matrix failure: % -> %',old_s,new_s; end if;
    end loop;
  end loop;
end $$;

commit;