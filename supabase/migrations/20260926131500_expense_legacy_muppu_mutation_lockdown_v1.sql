-- Retire legacy Muppu mutation entry points.
-- Historical Muppu rows remain read-only provenance until the final API cleanup.
-- Canonical Expense mutations are now the supported financial path.

REVOKE ALL ON FUNCTION public.create_muppu_record_for_admin(
  uuid,uuid,uuid,bigint
) FROM PUBLIC,authenticated;

REVOKE ALL ON FUNCTION public.mark_muppu_paid_for_admin(
  uuid,text,timestamptz
) FROM PUBLIC,authenticated;

REVOKE ALL ON FUNCTION public.waive_muppu_for_admin(
  uuid,text
) FROM PUBLIC,authenticated;

REVOKE ALL ON FUNCTION public.deduct_muppu_from_prize_for_admin(
  uuid,text
) FROM PUBLIC,authenticated;

REVOKE ALL ON FUNCTION public.list_muppu_records_for_admin(
  uuid,uuid
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.list_muppu_records_for_admin(
  uuid,uuid
) TO authenticated;
