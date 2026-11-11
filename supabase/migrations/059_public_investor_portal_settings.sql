-- Public investor settings used by the mobile app. Excludes payment credentials.
-- This must read the same singleton row the admin Settings page updates.

CREATE OR REPLACE FUNCTION public.get_investor_portal_settings()
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row public.admin_portal_settings%ROWTYPE;
BEGIN
  SELECT * INTO v_row
  FROM public.admin_portal_settings
  WHERE id = 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Portal settings are not configured.';
  END IF;

  RETURN json_build_object(
    'platform_name', v_row.platform_name,
    'support_email', v_row.support_email,
    'support_phone', v_row.support_phone,
    'min_investment_amount', v_row.min_investment_amount,
    'max_investment_amount', v_row.max_investment_amount
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_investor_portal_settings() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_investor_portal_settings() TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
