-- Keep the automatic payout day based on the investment date, while allowing
-- an admin to explicitly choose any supported monthly payout day.

ALTER TABLE public.investments
  ADD COLUMN IF NOT EXISTS payout_day_overridden BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE public.investments
  ALTER COLUMN payout_day DROP DEFAULT;

CREATE OR REPLACE FUNCTION public.admin_pay_date_for_cycle(
  p_base DATE,
  p_cycle_day INTEGER
)
RETURNS DATE
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  IF p_base IS NULL THEN
    RAISE EXCEPTION 'A base date is required to calculate the pay date.';
  END IF;

  IF p_cycle_day IS NULL OR NOT (p_cycle_day = ANY (ARRAY[1, 5, 10, 15, 20, 25])) THEN
    RAISE EXCEPTION 'Payout day must be one of 1, 5, 10, 15, 20, or 25.';
  END IF;

  IF p_cycle_day >= EXTRACT(DAY FROM p_base)::INTEGER THEN
    RETURN make_date(
      EXTRACT(YEAR FROM p_base)::INTEGER,
      EXTRACT(MONTH FROM p_base)::INTEGER,
      p_cycle_day
    );
  END IF;

  RETURN (date_trunc('month', p_base) + INTERVAL '1 month')::DATE
    + (p_cycle_day - 1);
END;
$$;

-- Replace the existing triggers so the 10th remains valid when explicitly
-- chosen, without running two different payout-day policies at once.
DROP TRIGGER IF EXISTS investments_apply_payout_cycle ON public.investments;
DROP TRIGGER IF EXISTS trg_sync_investment_pay_date ON public.investments;

-- Recalculate the automatic cycle for pending requests without an override,
-- while preserving any explicit admin choice (including an explicit 10th).
UPDATE public.investments
SET payout_day = public.investment_cycle_day(
      COALESCE(invested_date, (NOW() AT TIME ZONE 'Asia/Kolkata')::DATE)
    ),
    pay_date = public.admin_pay_date_for_cycle(
      COALESCE(invested_date, (NOW() AT TIME ZONE 'Asia/Kolkata')::DATE),
      public.investment_cycle_day(
        COALESCE(invested_date, (NOW() AT TIME ZONE 'Asia/Kolkata')::DATE)
      )
    )
WHERE status IN ('Pending', 'Under Review')
  AND NOT COALESCE(payout_day_overridden, FALSE);

CREATE OR REPLACE FUNCTION public.apply_investment_payout_cycle()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_base DATE;
BEGIN
  IF TG_OP = 'INSERT' THEN
    v_base := COALESCE(NEW.invested_date, (NOW() AT TIME ZONE 'Asia/Kolkata')::DATE);
    IF COALESCE(NEW.payout_day_overridden, FALSE)
       AND NEW.payout_day = ANY (ARRAY[1, 5, 10, 15, 20, 25]) THEN
      NEW.pay_date := public.admin_pay_date_for_cycle(v_base, NEW.payout_day);
    ELSE
      NEW.payout_day := public.investment_cycle_day(v_base);
      NEW.payout_day_overridden := FALSE;
      NEW.pay_date := public.admin_pay_date_for_cycle(v_base, NEW.payout_day);
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.status = 'Active'
     AND OLD.status IS DISTINCT FROM NEW.status
     AND OLD.status IN ('Pending', 'Under Review') THEN
    NEW.invested_date := COALESCE(
      NEW.invested_date,
      (NOW() AT TIME ZONE 'Asia/Kolkata')::DATE
    );
    IF NOT COALESCE(NEW.payout_day_overridden, FALSE) THEN
      NEW.payout_day := public.investment_cycle_day(NEW.invested_date);
    ELSIF NEW.payout_day IS NULL
          OR NOT (NEW.payout_day = ANY (ARRAY[1, 5, 10, 15, 20, 25])) THEN
      RAISE EXCEPTION 'Select a valid payout day before approving this investment.';
    END IF;
    NEW.pay_date := public.admin_pay_date_for_cycle(NEW.invested_date, NEW.payout_day);
    RETURN NEW;
  END IF;

  IF NEW.payout_day IS DISTINCT FROM OLD.payout_day THEN
    IF NEW.payout_day IS NULL THEN
      v_base := COALESCE(NEW.invested_date, (NOW() AT TIME ZONE 'Asia/Kolkata')::DATE);
      NEW.payout_day := public.investment_cycle_day(v_base);
      NEW.payout_day_overridden := FALSE;
    ELSE
      IF NOT (NEW.payout_day = ANY (ARRAY[1, 5, 10, 15, 20, 25])) THEN
        RAISE EXCEPTION 'Payout day must be one of 1, 5, 10, 15, 20, or 25.';
      END IF;
      NEW.payout_day_overridden := TRUE;
    END IF;
  END IF;

  IF NOT COALESCE(NEW.payout_day_overridden, FALSE)
     AND (
       NEW.invested_date IS DISTINCT FROM OLD.invested_date
       OR NEW.payout_day IS DISTINCT FROM OLD.payout_day
     ) THEN
    v_base := COALESCE(NEW.invested_date, (NOW() AT TIME ZONE 'Asia/Kolkata')::DATE);
    NEW.payout_day := public.investment_cycle_day(v_base);
    NEW.pay_date := public.admin_pay_date_for_cycle(v_base, NEW.payout_day);
  END IF;

  IF COALESCE(NEW.payout_day_overridden, FALSE)
     AND NEW.payout_day IS NOT NULL
     AND (
       NEW.payout_day IS DISTINCT FROM OLD.payout_day
       OR NEW.invested_date IS DISTINCT FROM OLD.invested_date
       OR NEW.payout_day_overridden IS DISTINCT FROM OLD.payout_day_overridden
     ) THEN
    v_base := COALESCE(NEW.invested_date, (NOW() AT TIME ZONE 'Asia/Kolkata')::DATE);
    NEW.pay_date := public.admin_pay_date_for_cycle(v_base, NEW.payout_day);
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER investments_apply_payout_cycle
  BEFORE INSERT OR UPDATE OF payout_day, invested_date, status
  ON public.investments
  FOR EACH ROW
  EXECUTE FUNCTION public.apply_investment_payout_cycle();

CREATE OR REPLACE FUNCTION public.admin_update_investment_terms(
  p_id UUID,
  p_interest_rate NUMERIC,
  p_tds_percent NUMERIC,
  p_payout_day INTEGER DEFAULT NULL,
  p_referral_rate NUMERIC DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row public.investments%ROWTYPE;
  v_referral_rate NUMERIC(8, 6);
BEGIN
  IF p_interest_rate IS NULL OR p_interest_rate <= 0 OR p_interest_rate > 1 THEN
    RAISE EXCEPTION 'Interest rate must be a decimal between 0 and 1 (e.g. 0.05).';
  END IF;

  IF p_tds_percent IS NULL OR p_tds_percent < 0 OR p_tds_percent > 1 THEN
    RAISE EXCEPTION 'TDS percent must be a decimal between 0 and 1.';
  END IF;

  IF p_payout_day IS NOT NULL
     AND NOT (p_payout_day = ANY (ARRAY[1, 5, 10, 15, 20, 25])) THEN
    RAISE EXCEPTION 'Payout day must be one of 1, 5, 10, 15, 20, or 25.';
  END IF;

  SELECT * INTO v_row
  FROM public.investments
  WHERE id = p_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Investment request not found';
  END IF;

  IF v_row.status NOT IN ('Pending', 'Under Review') THEN
    RAISE EXCEPTION 'Only pending or held requests can have terms updated.';
  END IF;

  v_referral_rate := COALESCE(p_referral_rate, v_row.referral_rate, 0.01);
  IF v_referral_rate < 0 OR v_referral_rate > 1 THEN
    RAISE EXCEPTION 'Referral rate must be between 0%% and 100%%.';
  END IF;

  IF p_payout_day IS NULL THEN
    UPDATE public.investments
    SET interest_rate = p_interest_rate,
        tds_percent = p_tds_percent,
        referral_rate = v_referral_rate,
        updated_at = NOW()
    WHERE id = p_id
    RETURNING * INTO v_row;
  ELSE
    UPDATE public.investments
    SET interest_rate = p_interest_rate,
        tds_percent = p_tds_percent,
        payout_day = p_payout_day,
        payout_day_overridden = TRUE,
        referral_rate = v_referral_rate,
        updated_at = NOW()
    WHERE id = p_id
    RETURNING * INTO v_row;
  END IF;

  RETURN json_build_object(
    'ok', TRUE,
    'id', v_row.id,
    'interest_rate', v_row.interest_rate,
    'tds_percent', v_row.tds_percent,
    'payout_day', v_row.payout_day,
    'payout_day_overridden', v_row.payout_day_overridden,
    'referral_rate', v_row.referral_rate,
    'status', v_row.status
  );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_update_investment_terms(UUID, NUMERIC, NUMERIC, INTEGER, NUMERIC) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_update_investment_terms(UUID, NUMERIC, NUMERIC, INTEGER, NUMERIC) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
