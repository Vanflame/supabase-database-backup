


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "pg_catalog";






CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "extensions";






COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE OR REPLACE FUNCTION "public"."acquire_scheduler_lease"("p_lease_key" "text", "p_ttl_seconds" integer DEFAULT 60) RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
 declare
     did_acquire boolean := false;
     affected_rows int := 0;
 begin
     insert into public.scheduler_leases (lease_key, leased_until, updated_at)
     values (p_lease_key, now() + make_interval(secs => greatest(1, p_ttl_seconds)), now())
     on conflict (lease_key)
     do update set
         leased_until = excluded.leased_until,
         updated_at = excluded.updated_at
     where public.scheduler_leases.leased_until < now();
 
     get diagnostics affected_rows = ROW_COUNT;
     did_acquire := affected_rows > 0;
     return did_acquire;
 end;
 $$;


ALTER FUNCTION "public"."acquire_scheduler_lease"("p_lease_key" "text", "p_ttl_seconds" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."apply_payment_method_txn"("p_payment_method_id" "uuid", "p_direction" "text", "p_amount" numeric, "p_source_table" "text", "p_source_id" "uuid", "p_effective_at" timestamp with time zone) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    IF p_payment_method_id IS NULL THEN
        RETURN;
    END IF;

    INSERT INTO public.payment_method_transactions (
        payment_method_id,
        direction,
        amount,
        source_table,
        source_id,
        effective_at
    ) VALUES (
        p_payment_method_id,
        p_direction,
        p_amount,
        p_source_table,
        p_source_id,
        p_effective_at
    )
    ON CONFLICT (source_table, source_id, direction) DO NOTHING;

    IF FOUND THEN
        UPDATE public.payment_methods
        SET wallet_balance = COALESCE(wallet_balance, 0)
            + CASE WHEN p_direction = 'in' THEN p_amount ELSE -p_amount END
        WHERE id = p_payment_method_id;
    END IF;
END;
$$;


ALTER FUNCTION "public"."apply_payment_method_txn"("p_payment_method_id" "uuid", "p_direction" "text", "p_amount" numeric, "p_source_table" "text", "p_source_id" "uuid", "p_effective_at" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."apply_sim_failure_streak_on_failure_record"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  v_app_name text;
  v_next_failed_apps text[];
  v_distinct_count integer;
  v_device_id text;
  v_sim_number text;
BEGIN
  -- Lookup app_name from otp_sessions; NEW.session_id is required by schema
  SELECT lower(os.app_name) INTO v_app_name
  FROM public.otp_sessions os
  WHERE os.id = NEW.session_id;

  IF v_app_name IS NULL OR length(trim(v_app_name)) = 0 THEN
    RETURN NEW;
  END IF;

  -- Upsert streak row and update failed_apps distinct list
  INSERT INTO public.sim_failure_streaks (sim_id, failed_apps, updated_at)
  VALUES (NEW.sim_id, ARRAY[v_app_name], now())
  ON CONFLICT (sim_id) DO UPDATE
  SET
    failed_apps = (
      SELECT ARRAY(
        SELECT DISTINCT x
        FROM unnest(public.sim_failure_streaks.failed_apps || ARRAY[v_app_name]) AS x
        WHERE x IS NOT NULL AND length(trim(x)) > 0
        ORDER BY x
      )
    ),
    updated_at = now()
  RETURNING failed_apps INTO v_next_failed_apps;

  v_distinct_count := COALESCE(array_length(v_next_failed_apps, 1), 0);

  -- Auto-pause SIM after 3 distinct failed apps (Option 3: count all failure types)
  IF v_distinct_count >= 3 THEN
    UPDATE public.sims
    SET status = 'PAUSED',
        paused_at = now(),
        paused_reason = 'failure_streak_3_apps',
        paused_context = jsonb_build_object(
          'rule', 'failure_streak_3_apps',
          'distinct_failed_apps', v_distinct_count,
          'failed_apps', v_next_failed_apps,
          'failure_record_id', NEW.id,
          'failure_type', NEW.failure_type,
          'session_id', NEW.session_id
        ),
        updated_at = now()
    WHERE id = NEW.sim_id;

    -- Create a device-targeted Agent Quality Rules announcement (best-effort)
    SELECT s.device_id, s.number INTO v_device_id, v_sim_number
    FROM public.sims s
    WHERE s.id = NEW.sim_id;

    IF v_device_id IS NOT NULL AND length(trim(v_device_id)) > 0 THEN
      INSERT INTO public.announcement (
        type,
        title,
        message,
        target_device_id,
        is_active,
        priority,
        show_in_banner,
        show_in_notification
      ) VALUES (
  'warning',
  'SIM Paused: Consecutive Failed Apps - ' || COALESCE(v_sim_number, ''),
  'Your SIM number ' || COALESCE(v_sim_number, '(unknown)') ||
  ' has been automatically PAUSED under Agent Quality Rules. ' ||
  'Reason: Consecutive OTP failures across 3 different apps. ' ||
  'Failed apps: ' || array_to_string(v_next_failed_apps, ', ') || '. ' ||
  'Session ID: ' || NEW.session_id::text,
  v_device_id,
  true,
  10,
  true,
  true
);

    END IF;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."apply_sim_failure_streak_on_failure_record"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."assign_default_referrer_on_insert"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_default_referrer_id UUID := '61665c4b-6a7d-4b0d-8475-8ed5de81ee82';
BEGIN
    -- Only assign if user doesn't have a referrer and is not the default referrer itself
    IF NEW.referred_by IS NULL AND NEW.id != v_default_referrer_id THEN
        -- Verify default referrer exists
        IF EXISTS (SELECT 1 FROM public.users WHERE id = v_default_referrer_id) THEN
            NEW.referred_by := v_default_referrer_id;
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."assign_default_referrer_on_insert"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."assign_default_referrer_on_insert"() IS 'Function kept for manual use. Trigger is disabled - users without referrer will not be auto-assigned.';



CREATE OR REPLACE FUNCTION "public"."auto_generate_referral_code"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    IF NEW.referral_code IS NULL THEN
        NEW.referral_code := generate_referral_code();
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."auto_generate_referral_code"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."auto_link_sms_to_otp_session"("p_sim_number" "text") RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  v_session              record;
  v_message_id           bigint;
  v_sender               text;
  v_existing_count       integer;
  v_new_count            integer;
  v_max_messages         integer;
  v_only_otp             boolean;
  v_sender_restrictions  text[];
  v_now                  timestamptz := now();
BEGIN
  -- Find the most recent active/pending session for this SIM that can still accept messages.
  SELECT *
  INTO v_session
  FROM public.otp_sessions
  WHERE sim_number = p_sim_number
    AND status IN ('pending', 'active')
  ORDER BY created_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN 'no_session';
  END IF;

  -- Load per-app config
  SELECT COALESCE(max_otp_messages, 3), COALESCE(only_otp, true), sender_restrictions
  INTO v_max_messages, v_only_otp, v_sender_restrictions
  FROM public.otp_pricing
  WHERE app_name = v_session.app_name
  LIMIT 1;

  IF v_max_messages IS NULL THEN
    v_max_messages := 3;
  END IF;

  IF v_only_otp IS NULL THEN
    v_only_otp := true;
  END IF;

  -- Check if session can still accept messages
  SELECT COUNT(*) INTO v_existing_count
  FROM public.sms_messages
  WHERE consumed_by_session = v_session.id;

  IF v_existing_count >= v_max_messages THEN
    IF v_session.status != 'completed' THEN
      UPDATE public.otp_sessions
      SET status = 'completed',
          status_updated_at = v_now,
          last_activity_at = v_now
      WHERE id = v_session.id;
    END IF;
    RETURN 'session_at_max_messages';
  END IF;

  -- Find the latest unlinked message after session creation.
  -- If only_otp=true, require OTP-looking regex. Otherwise accept any message.
  IF v_only_otp THEN
    SELECT id, sender
    INTO v_message_id, v_sender
    FROM public.sms_messages
    WHERE sim_number = p_sim_number
      AND consumed_by_session IS NULL
      AND "timestamp" >= v_session.created_at
      AND message ~ '(?<!\d)(?!(?:\+?63|0)\d{8,10})(?:\d{4,8}|\d(?:[-\s]?\d){4,7})(?!\d)'
    ORDER BY "timestamp" DESC
    LIMIT 1;
  ELSE
    SELECT id, sender
    INTO v_message_id, v_sender
    FROM public.sms_messages
    WHERE sim_number = p_sim_number
      AND consumed_by_session IS NULL
      AND "timestamp" >= v_session.created_at
    ORDER BY "timestamp" DESC
    LIMIT 1;
  END IF;

  -- If no new message, handle expiry transitions
  IF NOT FOUND THEN
    IF v_session.expires_at IS NOT NULL AND v_session.expires_at < v_now THEN
      IF v_existing_count > 0 THEN
        UPDATE public.otp_sessions
        SET status = 'completed',
            status_updated_at = v_now,
            last_activity_at = v_now
        WHERE id = v_session.id;
        RETURN 'expired_with_messages_completed';
      ELSE
        UPDATE public.otp_sessions
        SET status = 'expired',
            status_updated_at = v_now,
            last_activity_at = v_now
        WHERE id = v_session.id;
        RETURN 'expired_no_messages';
      END IF;
    END IF;
    RETURN 'no_valid_message';
  END IF;

  ---------------------------------------------------------------------
  -- Sender restriction enforcement (per app)
  -- Example: restriction 'grab' matches sender 'GrabPH'
  ---------------------------------------------------------------------
  IF v_sender_restrictions IS NOT NULL AND array_length(v_sender_restrictions, 1) > 0 THEN
    IF NOT EXISTS (
      SELECT 1
      FROM unnest(v_sender_restrictions) AS r(keyword)
      WHERE lower(v_sender) LIKE '%' || lower(keyword) || '%'
    ) THEN
      RETURN 'sender_restriction_mismatch';
    END IF;
  ELSE
    ---------------------------------------------------------------------
    -- Fallback safety (existing behavior):
    -- If sender matches ANY pricing app_name, require it matches this session's app.
    ---------------------------------------------------------------------
    IF EXISTS (
      SELECT 1
      FROM public.otp_pricing p
      WHERE lower(v_sender) LIKE '%' || lower(p.app_name) || '%'
    ) THEN
      IF NOT EXISTS (
        SELECT 1
        FROM public.otp_pricing p
        WHERE lower(p.app_name) = lower(v_session.app_name)
          AND lower(v_sender) LIKE '%' || lower(p.app_name) || '%'
      ) THEN
        RETURN 'sender_mismatch';
      END IF;
    END IF;
  END IF;

  -- Link the message to the session
  v_new_count := v_existing_count + 1;

  UPDATE public.sms_messages
  SET consumed_by_session = v_session.id
  WHERE id = v_message_id;

  -- Decide final status
  IF v_new_count >= v_max_messages THEN
    UPDATE public.otp_sessions
    SET status = 'completed',
        otp_message = (SELECT message FROM public.sms_messages WHERE id = v_message_id),
        otp_sender = v_sender,
        sms_message_id = v_message_id,
        message_count = v_new_count,
        status_updated_at = v_now,
        last_activity_at = v_now
    WHERE id = v_session.id;
  ELSE
    IF v_session.expires_at IS NOT NULL AND v_session.expires_at < v_now THEN
      UPDATE public.otp_sessions
      SET status = 'completed',
          otp_message = (SELECT message FROM public.sms_messages WHERE id = v_message_id),
          otp_sender = v_sender,
          sms_message_id = v_message_id,
          message_count = v_new_count,
          status_updated_at = v_now,
          last_activity_at = v_now
      WHERE id = v_session.id;
    ELSE
      UPDATE public.otp_sessions
      SET status = 'active',
          otp_message = (SELECT message FROM public.sms_messages WHERE id = v_message_id),
          otp_sender = v_sender,
          sms_message_id = v_message_id,
          message_count = v_new_count,
          status_updated_at = v_now,
          last_activity_at = v_now,
          activated_at = COALESCE(activated_at, v_now)
      WHERE id = v_session.id;
    END IF;
  END IF;

  INSERT INTO public.sim_app_usage (sim_number, app_name)
  VALUES (v_session.sim_number, v_session.app_name)
  ON CONFLICT (sim_number, app_name) DO NOTHING;

  IF v_new_count >= v_max_messages THEN
    RETURN 'linked_completed_max';
  ELSIF v_session.expires_at IS NOT NULL AND v_session.expires_at < v_now THEN
    RETURN 'linked_expired_completed';
  ELSE
    RETURN 'linked_active';
  END IF;
END;
$$;


ALTER FUNCTION "public"."auto_link_sms_to_otp_session"("p_sim_number" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."auto_link_sms_to_otp_session"("p_sim_number" "text") IS 'Automatically links SMS messages to active sessions, supporting per-app only_otp and sender_restrictions';



CREATE OR REPLACE FUNCTION "public"."auto_link_sms_to_session"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  update sms_messages
  set consumed_by_session = NEW.id
  where id = NEW.sms_message_id
    and (consumed_by_session is null or consumed_by_session <> NEW.id);
  return NEW;
end;
$$;


ALTER FUNCTION "public"."auto_link_sms_to_session"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."auto_mature_on_query"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  -- Auto-mature any pending transactions that have passed their available_at
  -- This runs in the background when transactions are queried
  PERFORM public.auto_mature_pending_transactions();
  RETURN NULL; -- This is a statement-level trigger, return doesn't matter
END;
$$;


ALTER FUNCTION "public"."auto_mature_on_query"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."auto_mature_pending_transactions"() RETURNS integer
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  v_count integer := 0;
  v_transaction record;
BEGIN
  -- Find all pending transactions that have matured (available_at <= now)
  FOR v_transaction IN
    SELECT id, user_id, agent_share
    FROM public.agent_transactions
    WHERE status = 'pending'
      AND available_at <= NOW()
  LOOP
    -- Update status to 'available'
    -- This will trigger update_agent_balance_on_transaction_change()
    UPDATE public.agent_transactions
    SET status = 'available',
        updated_at = NOW()
    WHERE id = v_transaction.id;
    
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;


ALTER FUNCTION "public"."auto_mature_pending_transactions"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."auto_mature_pending_transactions"() IS 'Automatically matures pending transactions that have passed their available_at timestamp';



CREATE OR REPLACE FUNCTION "public"."backfill_sim_stats_from_usage"() RETURNS TABLE("sim_id" bigint, "sim_number" "text", "total_completed" integer, "total_failed" integer, "updated_count" integer)
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  v_sim_record RECORD;
  v_completed_count integer;
  v_failed_count integer;
  v_existing_stats RECORD;
BEGIN
  -- Loop through all SIMs
  FOR v_sim_record IN 
    SELECT id, number 
    FROM public.sims
    ORDER BY id
  LOOP
    -- Count completed sessions from sim_app_usage (each entry = 1 completion)
    SELECT COUNT(*) INTO v_completed_count
    FROM public.sim_app_usage
    WHERE sim_app_usage.sim_number = v_sim_record.number;

    -- Get existing failed count from sims table (preserve it)
    SELECT sims.total_failed INTO v_failed_count
    FROM public.sims
    WHERE sims.id = v_sim_record.id;

    -- If no existing entry, set failed to 0
    IF v_failed_count IS NULL THEN
      v_failed_count := 0;
    END IF;

    -- Update sims table directly
    UPDATE public.sims
    SET 
      total_completed = v_completed_count,
      total_failed = COALESCE(v_failed_count, 0),
      updated_at = now()
    WHERE id = v_sim_record.id;

    -- Return result
    RETURN QUERY SELECT 
      v_sim_record.id,
      v_sim_record.number,
      v_completed_count,
      v_failed_count,
      1;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."backfill_sim_stats_from_usage"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."backfill_sim_stats_from_usage"() IS 'Backfills sims table with completed counts from sim_app_usage for all SIMs';



CREATE OR REPLACE FUNCTION "public"."check_otp_message"("p_session_id" "uuid") RETURNS json
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  v_session record;
  v_message record;
  v_result json;
BEGIN
  -- Debug: show what session id is being passed
  RAISE NOTICE 'Incoming p_session_id=%', p_session_id;

  -- Guard against NULL session id
  IF p_session_id IS NULL THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Session id cannot be null'
    );
  END IF;

  -- Get session details
  SELECT * INTO v_session
  FROM public.otp_sessions
  WHERE id = p_session_id;

  IF NOT FOUND THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Session not found'
    );
  END IF;

  IF v_session.status NOT IN ('pending', 'active') THEN
    RETURN json_build_object(
      'success', true,
      'status', v_session.status,
      'message', null
    );
  END IF;

  -- Check for new message
  SELECT * INTO v_message
  FROM public.v_sms_messages_full
  WHERE sim_number = v_session.sim_number
    AND consumed_by_session IS NULL
  ORDER BY "timestamp" DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN json_build_object(
      'success', true,
      'status', 'waiting',
      'message', null
    );
  END IF;

  -- Mark message as consumed
  UPDATE public.sms_messages
  SET consumed_by_session = p_session_id
  WHERE id = v_message.id;

  -- Update session as completed
  UPDATE public.otp_sessions
  SET status         = 'completed',
      otp_message    = v_message.message,
      otp_sender     = v_message.sender,
      sms_message_id = v_message.id
  WHERE id = p_session_id;

  -- Record SIM usage for this app
  INSERT INTO public.sim_app_usage (sim_number, app_name, session_id)
  VALUES (v_session.sim_number, v_session.app_name, p_session_id)
  ON CONFLICT (sim_number, app_name) DO UPDATE
  SET session_id = COALESCE(EXCLUDED.session_id, sim_app_usage.session_id),
      used_at   = now();

  -- Return result
  v_result := json_build_object(
    'success', true,
    'status', 'completed',
    'message', json_build_object(
      'sender', v_message.sender,
      'content', v_message.message,
      'timestamp', v_message.timestamp
    )
  );

  RETURN v_result;
END;
$$;


ALTER FUNCTION "public"."check_otp_message"("p_session_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cleanup_expired_rate_limits"() RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    DELETE FROM rate_limit_tracking 
    WHERE reset_time < NOW();
END;
$$;


ALTER FUNCTION "public"."cleanup_expired_rate_limits"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."clear_expires_at_if_pending"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  -- If status is pending and expires_at is set, clear it
  IF NEW.status = 'pending' AND NEW.expires_at IS NOT NULL THEN
    NEW.expires_at := NULL;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."clear_expires_at_if_pending"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_agent_invite_earning_for_tx"("p_agent_transaction_id" bigint) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  v_invited_agent_id uuid;
  v_inviter_id uuid;
  v_tx_status text;
  v_amount decimal(10,2);
BEGIN
  -- Get tx info
  SELECT user_id, status INTO v_invited_agent_id, v_tx_status
  FROM public.agent_transactions
  WHERE id = p_agent_transaction_id;

  IF v_invited_agent_id IS NULL THEN
    RETURN;
  END IF;

  -- Only pay on available/claimed
  IF lower(coalesce(v_tx_status,'')) NOT IN ('available','claimed') THEN
    RETURN;
  END IF;

  -- Find inviter (referrer) of this agent
  SELECT referred_by INTO v_inviter_id
  FROM public.users
  WHERE id = v_invited_agent_id;

  IF v_inviter_id IS NULL THEN
    RETURN;
  END IF;

  -- Get active config amount
  SELECT COALESCE(agent_invite_commission_per_session, 0.15) INTO v_amount
  FROM public.referral_config
  WHERE is_active = true
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_amount IS NULL THEN
    v_amount := 0.15;
  END IF;

  -- Insert ledger row, deduped
  INSERT INTO public.agent_invite_earnings (
    inviter_id,
    invited_agent_id,
    agent_transaction_id,
    amount,
    status
  ) VALUES (
    v_inviter_id,
    v_invited_agent_id,
    p_agent_transaction_id,
    v_amount,
    'pending'
  )
  ON CONFLICT (agent_transaction_id) DO NOTHING;
END;
$$;


ALTER FUNCTION "public"."create_agent_invite_earning_for_tx"("p_agent_transaction_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_agent_transaction_from_usage"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  v_agent_share numeric(12,2);
  v_site_share  numeric(12,2);
  v_commission_rate numeric(5,2);
BEGIN
  -- Guard: must have agent + amount
  IF NEW.agent_user_id IS NULL
     OR NEW.gross_amount IS NULL
     OR NEW.gross_amount <= 0
  THEN
    RETURN NEW;
  END IF;

  -- Commission logic (ONLY based on agent_direct)
  IF NEW.agent_direct IS TRUE THEN
    -- Agent-direct commission (config)
    SELECT default_commission_percentage
    INTO v_commission_rate
    FROM public.agent_commission_config
    WHERE is_agent_direct = true
    ORDER BY updated_at DESC
    LIMIT 1;
  ELSE
    -- Normal agent commission
    v_commission_rate := public.get_agent_commission_rate(NEW.agent_user_id);
  END IF;

  -- Absolute safety
  IF v_commission_rate IS NULL THEN
    v_commission_rate := 0;
  END IF;

  -- Calculate shares
  v_agent_share := ROUND(NEW.gross_amount * (v_commission_rate / 100.0), 2);
  v_site_share  := NEW.gross_amount - v_agent_share;

  -- Insert exactly once per sim_app_usage_id.
  -- NOTE: requires idx_agent_transactions_unique_sim_app_usage_id (partial unique index)
  INSERT INTO public.agent_transactions (
    user_id,
    sim_app_usage_id,
    sim_number,
    app_name,
    gross_amount,
    agent_share,
    site_share,
    status,
    available_at,
    agent_direct
  ) VALUES (
    NEW.agent_user_id,
    NEW.id,
    NEW.sim_number,
    NEW.app_name,
    NEW.gross_amount,
    v_agent_share,
    v_site_share,
    'pending',
    NOW() + interval '12 hours',
    NEW.agent_direct
  )
  ON CONFLICT (sim_app_usage_id) WHERE sim_app_usage_id IS NOT NULL DO NOTHING;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."create_agent_transaction_from_usage"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."create_agent_transaction_from_usage"() IS 'Creates agent_transactions from sim_app_usage updates. Balances are updated by agent_transactions triggers.';



CREATE OR REPLACE FUNCTION "public"."create_otp_session"("p_user_id" "uuid", "p_app_name" "text") RETURNS json
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_session_id uuid;
  v_sim_number text;
  v_app_display_name text;
  v_price numeric(10,2);
  v_result json;
BEGIN
  -- Normalize app name
  p_app_name := lower(trim(p_app_name));
  
  -- Get app pricing info (don't insert, just select)
  SELECT display_name, price INTO v_app_display_name, v_price
  FROM public.otp_pricing
  WHERE app_name = p_app_name;
  
  -- If app doesn't exist, use defaults
  IF NOT FOUND THEN
    v_app_display_name := p_app_name;
    v_price := 0.10;
  END IF;
  
  -- Find available SIM
  SELECT s.number INTO v_sim_number
  FROM sims s
  WHERE s.type = 'private'
  AND s.number NOT IN (
    SELECT COALESCE(sim_number, '') 
    FROM otp_sessions 
    WHERE status IN ('pending', 'active')
  )
  AND s.number NOT IN (
    SELECT sim_number 
    FROM sim_app_usage 
    WHERE app_name = p_app_name
  )
  LIMIT 1;
  
  IF v_sim_number IS NULL THEN
    RETURN json_build_object(
      'success', false,
      'error', 'No available SIM for this app'
    );
  END IF;
  
  -- Create OTP session
  INSERT INTO public.otp_sessions (user_id, app_name, sim_number, status, expires_at)
  VALUES (p_user_id, p_app_name, v_sim_number, 'active', NOW() + INTERVAL '10 minutes')
  RETURNING id INTO v_session_id;
  
  -- Return result
  v_result := json_build_object(
    'success', true,
    'session_id', v_session_id,
    'sim_number', v_sim_number,
    'app_name', p_app_name,
    'app_display_name', v_app_display_name,
    'price', v_price,
    'expires_in', 600
  );
  
  RETURN v_result;
END;
$$;


ALTER FUNCTION "public"."create_otp_session"("p_user_id" "uuid", "p_app_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_expired_otps"() RETURNS "void"
    LANGUAGE "sql"
    AS $$
  delete from public.otp_messages where expires_at < now();
$$;


ALTER FUNCTION "public"."delete_expired_otps"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."detect_carrier_from_number"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$DECLARE
  normalized text;
  prefix4 text;
BEGIN
  -- Do nothing if carrier already exists
  IF NEW.carrier IS NOT NULL THEN
    RETURN NEW;
  END IF;

  -- Normalize number
  normalized := trim(NEW.number);

  -- Handle +63XXXXXXXXXX → 09XXXXXXXXX
  IF normalized LIKE '+63%' THEN
    normalized := '0' || substr(normalized, 4);

  -- Handle +09XXXXXXXXX → 09XXXXXXXXX
  ELSIF normalized LIKE '+09%' THEN
    normalized := substr(normalized, 2);
  END IF;

  -- Must start with 09 after normalization
  IF normalized NOT LIKE '09%' THEN
    RETURN NEW;
  END IF;

  -- Extract first 4-digit prefix
  prefix4 := substr(normalized, 1, 4);

  -- Detect carrier
  NEW.carrier := CASE
    /* ===================== GLOBE / TM / GOMO ===================== */
    WHEN prefix4 IN (
      '0817',
      '0904','0905','0906',
      '0915','0916','0917',
      '0926','0927',
      '0935','0936','0937',
      '0945',
      '0953','0954','0955','0956',
      '0965','0966','0967',
      '0975','0976','0977','0978','0979',
      '0995','0996','0997'
    ) THEN 'TM'

    /* ===================== SMART / TNT / SUN ===================== */
    WHEN prefix4 IN (
      '0813',
      '0907','0908','0909',
      '0910','0911','0912','0913','0914',
      '0918','0919',
      '0920','0921','0928','0929',
      '0930','0938','0939',
      '0940','0946','0947','0948','0949',
      '0950','0951',
      '0961','0963','0968','0969',
      '0970',
      '0980','0981','0982','0985','0989',
      '0998','0999','0960'
    ) THEN 'TNT'

    /* ===================== DITO ===================== */
    WHEN prefix4 IN (
      '0895','0896','0897','0898',
      '0991','0992','0993','0994'
    ) THEN 'DITO'

    ELSE NULL
  END;

  RETURN NEW;
END;$$;


ALTER FUNCTION "public"."detect_carrier_from_number"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."detect_carrier_from_number_after"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$DECLARE
  normalized text;
  prefix4 text;
  detected_carrier text;
BEGIN
  -- Only act if carrier is still NULL in table
  IF NEW.carrier IS NOT NULL THEN
    RETURN NULL;
  END IF;

  normalized := trim(NEW.number);

  IF normalized LIKE '+63%' THEN
    normalized := '0' || substr(normalized, 4);
  ELSIF normalized LIKE '+09%' THEN
    normalized := substr(normalized, 2);
  END IF;

  IF normalized NOT LIKE '09%' THEN
    RETURN NULL;
  END IF;

  prefix4 := substr(normalized, 1, 4);

  detected_carrier := CASE
    -- GLOBE / TM / GOMO
    WHEN prefix4 IN (
      '0817','0904','0905','0906','0915','0916','0917',
      '0926','0927','0935','0936','0937','0945',
      '0953','0954','0955','0956',
      '0965','0966','0967',
      '0975','0976','0977','0978','0979',
      '0995','0996','0997'
    ) THEN 'GLOBE'

    -- SMART / TNT / SUN
    WHEN prefix4 IN (
      '0813','0907','0908','0909',
      '0910','0911','0912','0913','0914',
      '0918','0919','0920','0921','0928','0929',
      '0930','0938','0939',
      '0940','0946','0947','0948','0949',
      '0950','0951',
      '0961','0963','0968','0969',
      '0970','0980','0981','0982','0985','0989',
      '0998','0999','0960'
    ) THEN 'SMART'

    -- DITO
    WHEN prefix4 IN (
      '0895','0896','0897','0898',
      '0991','0992','0993','0994'
    ) THEN 'DITO'

    ELSE NULL
  END;

  -- Update safely AFTER all other triggers
  IF detected_carrier IS NOT NULL THEN
    UPDATE sims
    SET carrier = detected_carrier
    WHERE id = NEW.id
      AND carrier IS NULL;
  END IF;

  RETURN NULL;
END;$$;


ALTER FUNCTION "public"."detect_carrier_from_number_after"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."enqueue_manual_payment_auto_approved"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    matched_exists BOOLEAN;
BEGIN
    IF (TG_OP = 'UPDATE' OR TG_OP = 'INSERT')
        AND NEW.status = 'approved'
        AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM NEW.status)
        AND NEW.approved_by IS NULL
    THEN
        SELECT EXISTS(
            SELECT 1
            FROM public.gcash_notif gn
            WHERE gn.matched_payment_id = NEW.id
        )
        INTO matched_exists;

        IF matched_exists THEN
            INSERT INTO public.notification_outbox (event_type, record_id, user_id, payload)
            VALUES (
                'manual_payment_auto_approved',
                NEW.id,
                NEW.user_id,
                jsonb_build_object(
                    'amount', NEW.amount,
                    'app_name', NEW.app_name,
                    'approved_at', NEW.approved_at
                )
            )
            ON CONFLICT (event_type, record_id) DO NOTHING;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."enqueue_manual_payment_auto_approved"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."enqueue_otp_on_approval"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$DECLARE
  v_existing_id uuid;
BEGIN
  -- Only when status changes to approved
  IF TG_OP = 'UPDATE'
     AND NEW.status = 'approved'
     AND OLD.status IS DISTINCT FROM 'approved' 
     AND NEW.agent_direct IS FALSE
     THEN

    IF NEW.user_id IS NULL OR NEW.app_name IS NULL THEN
      RETURN NEW;
    END IF;

    -- Check if a queue row already exists for this payment (due to retries, etc.)
    SELECT payment_id
    INTO v_existing_id
    FROM public.otp_session_queue
    WHERE payment_id = NEW.id
    LIMIT 1;

    IF v_existing_id IS NOT NULL THEN
      -- Already enqueued; do nothing
      RETURN NEW;
    END IF;

    -- Insert a single queue item for this payment
    INSERT INTO public.otp_session_queue (payment_id, user_id, app_name, processed, created_at)
    VALUES (NEW.id, NEW.user_id, NEW.app_name, false, now());
  END IF;

  RETURN NEW;
END;$$;


ALTER FUNCTION "public"."enqueue_otp_on_approval"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."enqueue_telegram_referral_invite_event"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
    if new.referred_by is null then
        return new;
    end if;

    insert into public.telegram_referral_invite_events(provider, referrer_id, referred_user_id)
    values ('telegram', new.referred_by, new.id)
    on conflict (provider, referred_user_id) do nothing;

    return new;
end;
$$;


ALTER FUNCTION "public"."enqueue_telegram_referral_invite_event"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."enqueue_wallet_topup_auto_approved"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    IF (TG_OP = 'UPDATE' OR TG_OP = 'INSERT')
        AND NEW.status = 'approved'
        AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM NEW.status)
        AND NEW.matched_notification_id IS NOT NULL
        AND NEW.approved_by IS NULL
    THEN
        INSERT INTO public.notification_outbox (event_type, record_id, user_id, payload)
        VALUES (
            'wallet_topup_auto_approved',
            NEW.id,
            NEW.user_id,
            jsonb_build_object(
                'amount', NEW.amount,
                'approved_at', NEW.approved_at,
                'matched_notification_id', NEW.matched_notification_id
            )
        )
        ON CONFLICT (event_type, record_id) DO NOTHING;
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."enqueue_wallet_topup_auto_approved"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."expire_old_sessions"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_expired_count integer;
BEGIN
  -- Update expired sessions
  UPDATE public.otp_sessions
  SET 
    status = 'expired', 
    status_updated_at = NOW(),
    last_activity_at = NOW()
  WHERE status IN ('pending', 'active')
  AND expires_at IS NOT NULL
  AND expires_at < NOW();
  
  GET DIAGNOSTICS v_expired_count = ROW_COUNT;
  
  RETURN v_expired_count;
END;
$$;


ALTER FUNCTION "public"."expire_old_sessions"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."expire_otp_sessions"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  -- Update active sessions that have expired
  UPDATE otp_sessions 
  SET 
    status = 'expired',
    status_updated_at = NOW(),
    last_activity_at = NOW()
  WHERE 
    status = 'active' 
    AND expires_at IS NOT NULL 
    AND expires_at < NOW();
END;
$$;


ALTER FUNCTION "public"."expire_otp_sessions"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_accumulate_device_uptime"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
declare
  delta_seconds bigint;
begin
  -- Only accumulate if device is online
  if OLD.last_heartbeat is not null
     and NEW.last_heartbeat is not null
     and NEW.status = 'online' then

    delta_seconds :=
      extract(epoch from (NEW.last_heartbeat - OLD.last_heartbeat));

    if delta_seconds > 0 and delta_seconds < 3600 then
      NEW.uptime_seconds := OLD.uptime_seconds + delta_seconds;
    else
      NEW.uptime_seconds := OLD.uptime_seconds;
    end if;
  else
    NEW.uptime_seconds := OLD.uptime_seconds;
  end if;

  return NEW;
end;
$$;


ALTER FUNCTION "public"."fn_accumulate_device_uptime"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_accumulate_sim_uptime"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    delta_seconds bigint;
    device_status text;
BEGIN
    -- Get device status
    SELECT status INTO device_status
    FROM devices
    WHERE device_id = NEW.device_id;

    -- Conditions to accumulate uptime
    IF OLD.last_heartbeat IS NOT NULL
       AND NEW.last_heartbeat IS NOT NULL
       AND NEW.status IN ('ACTIVE', 'IN_USE') THEN

        delta_seconds := EXTRACT(EPOCH FROM (NEW.last_heartbeat - OLD.last_heartbeat));

        IF delta_seconds > 0 THEN
            NEW.uptime_seconds := COALESCE(OLD.uptime_seconds,0) + delta_seconds;
        ELSE
            NEW.uptime_seconds := COALESCE(OLD.uptime_seconds,0);
        END IF;

    ELSE
        NEW.uptime_seconds := COALESCE(OLD.uptime_seconds,0);
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."fn_accumulate_sim_uptime"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_update_device_status_from_last_seen"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
declare
  new_status text;
  elapsed_seconds double precision;
begin
  -- be defensive: if last_seen is null -> offline
  if new.last_seen is null then
    new_status := 'offline';
  else
    elapsed_seconds := extract(epoch from (now() - new.last_seen));

    if elapsed_seconds < (5 * 60) then
      new_status := 'active';
    elsif elapsed_seconds < (30 * 60) then
      new_status := 'idle';
    else
      new_status := 'offline';
    end if;
  end if;

  -- only update if changed (avoid infinite trigger loops)
  if (new.status is distinct from new_status) then
    -- update device row: set status and updated_at
    update public.devices
      set status = new_status,
          updated_at = now()
    where device_id = new.device_id;

    -- optionally update sims associated with device
    -- only run if you have status column on sims (adjust table name/schema as needed)
    update public.sims
      set type = coalesce(type, 'public'), -- no change; placeholder if needed
          updated_at = now()
    where device_id = new.device_id;

    -- Note: if you want a column `status` on sims, replace the update above with:
    -- update public.sims set status = new_status, updated_at = now() where device_id = new.device_id;
  end if;

  return new;
end;
$$;


ALTER FUNCTION "public"."fn_update_device_status_from_last_seen"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_referral_code"() RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    chars TEXT := 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    code TEXT;
    exists_check BOOLEAN;
BEGIN
    LOOP
        code := 'OP' || 
            SUBSTR(chars, 1 + FLOOR(RANDOM() * LENGTH(chars))::INTEGER, 1) ||
            SUBSTR(chars, 1 + FLOOR(RANDOM() * LENGTH(chars))::INTEGER, 1) ||
            SUBSTR(chars, 1 + FLOOR(RANDOM() * LENGTH(chars))::INTEGER, 1) ||
            SUBSTR(chars, 1 + FLOOR(RANDOM() * LENGTH(chars))::INTEGER, 1);
        
        SELECT EXISTS(SELECT 1 FROM public.users WHERE referral_code = code) INTO exists_check;
        EXIT WHEN NOT exists_check;
    END LOOP;
    
    RETURN code;
END;
$$;


ALTER FUNCTION "public"."generate_referral_code"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_agent_commission_rate"("p_user_id" "uuid") RETURNS numeric
    LANGUAGE "plpgsql" STABLE
    AS $$
DECLARE
    v_rate NUMERIC(5,2);
    v_override_rate NUMERIC(5,2);
BEGIN
    -- First check for active per-agent override
    SELECT commission_percentage INTO v_override_rate
    FROM public.agent_commission_overrides
    WHERE user_id = p_user_id
      AND is_active = true
      AND (expires_at IS NULL OR expires_at > NOW())
    ORDER BY created_at DESC
    LIMIT 1;
    
    -- If override exists, use it
    IF v_override_rate IS NOT NULL THEN
        RETURN v_override_rate;
    END IF;
    
    -- Otherwise, get default from config
    SELECT default_commission_percentage INTO v_rate
    FROM public.agent_commission_config
    WHERE is_active = true
    ORDER BY created_at DESC
    LIMIT 1;
    
    -- If no config exists, default to 60%
    RETURN COALESCE(v_rate, 60.00);
END;
$$;


ALTER FUNCTION "public"."get_agent_commission_rate"("p_user_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_agent_commission_rate"("p_user_id" "uuid") IS 'Returns the commission rate (as percentage) for a given agent. Checks per-agent overrides first, then falls back to global default.';



CREATE OR REPLACE FUNCTION "public"."get_agent_transactions_with_auto_mature"("p_user_id" "uuid" DEFAULT NULL::"uuid", "p_status" character varying DEFAULT NULL::character varying) RETURNS TABLE("id" bigint, "user_id" "uuid", "sim_app_usage_id" "uuid", "sim_number" "text", "app_name" "text", "gross_amount" numeric, "agent_share" numeric, "site_share" numeric, "status" character varying, "available_at" timestamp with time zone, "claimed_at" timestamp with time zone, "created_at" timestamp with time zone, "updated_at" timestamp with time zone)
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  -- Auto-mature pending transactions before querying
  PERFORM public.auto_mature_pending_transactions();
  
  -- Return filtered results
  RETURN QUERY
  SELECT 
    at.id,
    at.user_id,
    at.sim_app_usage_id,
    at.sim_number,
    at.app_name,
    at.gross_amount,
    at.agent_share,
    at.site_share,
    at.status,
    at.available_at,
    at.claimed_at,
    at.created_at,
    at.updated_at
  FROM public.agent_transactions at
  WHERE (p_user_id IS NULL OR at.user_id = p_user_id)
    AND (p_status IS NULL OR at.status = p_status)
  ORDER BY at.created_at DESC;
END;
$$;


ALTER FUNCTION "public"."get_agent_transactions_with_auto_mature"("p_user_id" "uuid", "p_status" character varying) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_agent_transactions_with_auto_mature"("p_user_id" "uuid", "p_status" character varying) IS 'Queries agent_transactions and auto-matures pending transactions before returning results';



CREATE OR REPLACE FUNCTION "public"."get_device_status_from_heartbeat"("heartbeat_time" timestamp with time zone) RETURNS "text"
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
DECLARE
  minutes_since_heartbeat int;
BEGIN
  minutes_since_heartbeat := EXTRACT(EPOCH FROM (now() - heartbeat_time)) / 60;
  
  IF minutes_since_heartbeat <= 5 THEN
    RETURN 'active';
  ELSIF minutes_since_heartbeat <= 30 THEN
    RETURN 'idle';
  ELSE
    RETURN 'offline';
  END IF;
END;
$$;


ALTER FUNCTION "public"."get_device_status_from_heartbeat"("heartbeat_time" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_or_create_rate_limit"("p_identifier" "text", "p_endpoint_path" "text", "p_window_seconds" integer) RETURNS TABLE("current_count" integer, "reset_time" timestamp with time zone)
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_count INTEGER;
    v_reset_time TIMESTAMPTZ;
    v_now TIMESTAMPTZ := NOW();
BEGIN
    -- Try to get existing entry
    SELECT count, rate_limit_tracking.reset_time
    INTO v_count, v_reset_time
    FROM rate_limit_tracking
    WHERE identifier = p_identifier
      AND endpoint_path = p_endpoint_path;
    
    -- If entry exists and is still valid
    IF v_count IS NOT NULL AND v_reset_time > v_now THEN
        -- Increment count
        UPDATE rate_limit_tracking
        SET count = count + 1,
            updated_at = v_now
        WHERE identifier = p_identifier
          AND endpoint_path = p_endpoint_path;
        
        v_count := v_count + 1;
    ELSE
        -- Create new entry or reset expired one
        v_reset_time := v_now + (p_window_seconds || ' seconds')::INTERVAL;
        v_count := 1;
        
        INSERT INTO rate_limit_tracking (identifier, endpoint_path, count, reset_time)
        VALUES (p_identifier, p_endpoint_path, v_count, v_reset_time)
        ON CONFLICT (identifier, endpoint_path)
        DO UPDATE SET
            count = 1,
            reset_time = v_reset_time,
            updated_at = v_now;
    END IF;
    
    RETURN QUERY SELECT v_count, v_reset_time;
END;
$$;


ALTER FUNCTION "public"."get_or_create_rate_limit"("p_identifier" "text", "p_endpoint_path" "text", "p_window_seconds" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_session_time_remaining"("session_id" "uuid") RETURNS integer
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  time_remaining INTEGER;
BEGIN
  SELECT 
    CASE 
      WHEN status = 'active' AND expires_at IS NOT NULL THEN
        GREATEST(0, EXTRACT(EPOCH FROM (expires_at - NOW()))::INTEGER)
      ELSE 0
    END
  INTO time_remaining
  FROM otp_sessions 
  WHERE id = session_id;
  
  RETURN COALESCE(time_remaining, 0);
END;
$$;


ALTER FUNCTION "public"."get_session_time_remaining"("session_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_user_role"("user_id" "uuid") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  RETURN (
    SELECT role FROM users WHERE id = user_id
  );
END;
$$;


ALTER FUNCTION "public"."get_user_role"("user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_user_sessions"("p_user_id" "uuid", "p_limit" integer DEFAULT 50, "p_offset" integer DEFAULT 0) RETURNS json
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_result json;
BEGIN
  -- Use a simpler approach to avoid JSON parsing issues
  SELECT COALESCE(
    json_agg(
      json_build_object(
        'id', id,
        'app_name', app_name,
        'sim_number', sim_number,
        'status', status,
        'otp_message', otp_message,
        'otp_sender', otp_sender,
        'created_at', created_at,
        'expires_at', expires_at,
        'time_remaining', CASE 
          WHEN status = 'active' AND expires_at IS NOT NULL THEN
            GREATEST(0, EXTRACT(EPOCH FROM (expires_at - NOW()))::INTEGER)
          ELSE 0
        END
      )
    ), 
    '[]'::json
  ) INTO v_result
  FROM (
    SELECT 
      id, app_name, sim_number, status, otp_message, otp_sender, 
      created_at, expires_at
    FROM public.otp_sessions
    WHERE user_id = p_user_id
    ORDER BY created_at DESC
    LIMIT p_limit
    OFFSET p_offset
  ) sessions;
  
  RETURN v_result;
END;
$$;


ALTER FUNCTION "public"."get_user_sessions"("p_user_id" "uuid", "p_limit" integer, "p_offset" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_expired_session_with_messages"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  v_message_count integer;
  v_now timestamptz := now();
BEGIN
  -- Only process if status changed to 'expired'
  IF NEW.status = 'expired' AND (OLD.status IS NULL OR OLD.status != 'expired') THEN
    -- Count linked messages for this session
    SELECT COUNT(*) INTO v_message_count
    FROM public.sms_messages
    WHERE consumed_by_session = NEW.id;

    -- If session has messages, mark as completed instead
    IF v_message_count > 0 THEN
      NEW.status := 'completed';
      NEW.status_updated_at := v_now;
      NEW.last_activity_at := v_now;
      
      -- Also update message_count if not already set
      IF NEW.message_count IS NULL OR NEW.message_count = 0 THEN
        NEW.message_count := v_message_count;
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."handle_expired_session_with_messages"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_manual_payment_status"("p_payment_id" "uuid", "p_status" "text", "p_approved_by" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_payment RECORD;
  v_otp_session RECORD;
  v_response JSONB;
BEGIN
  -- Validate input
  IF p_status NOT IN ('pending', 'approved', 'rejected') THEN
    RAISE EXCEPTION 'Invalid status: %', p_status;
  END IF;

  -- Fetch the payment
  SELECT * INTO v_payment FROM manual_payments WHERE id = p_payment_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Payment not found';
  END IF;

  -- Update the payment record
  UPDATE manual_payments
  SET 
    status = p_status,
    approved_by = CASE WHEN p_status = 'approved' THEN p_approved_by ELSE NULL END,
    approved_at = CASE WHEN p_status = 'approved' THEN now() ELSE NULL END,
    updated_at = now()
  WHERE id = p_payment_id;

  -- Handle response and OTP session creation
  IF p_status = 'pending' THEN
    v_response := jsonb_build_object(
      'status', 'pending',
      'message', 'Your payment is pending review. We’ll notify you once it’s approved or rejected.'
    );

  ELSIF p_status = 'approved' THEN
    -- Create OTP session
    INSERT INTO otp_sessions (user_id, app_name, status)
    VALUES (v_payment.user_id, v_payment.app_name, 'pending')
    RETURNING * INTO v_otp_session;

    v_response := jsonb_build_object(
      'status', 'approved',
      'message', 'Your payment has been approved. An OTP session has been successfully created.',
      'otp_session_id', v_otp_session.id,
      'app_name', v_payment.app_name
    );

  ELSE
    v_response := jsonb_build_object(
      'status', 'rejected',
      'message', 'Your payment was rejected. Please contact support if you believe this is an error.'
    );
  END IF;

  RETURN v_response;
END;
$$;


ALTER FUNCTION "public"."handle_manual_payment_status"("p_payment_id" "uuid", "p_status" "text", "p_approved_by" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."increment_sim_failed"("p_sim_id" bigint) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  -- Update total_failed in sims table directly
  UPDATE public.sims
  SET 
    total_failed = COALESCE(total_failed, 0) + 1,
    updated_at = now()
  WHERE id = p_sim_id;
END;
$$;


ALTER FUNCTION "public"."increment_sim_failed"("p_sim_id" bigint) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."increment_sim_failed"("p_sim_id" bigint) IS 'Increments the total_failed count for a SIM in sims table';



CREATE OR REPLACE FUNCTION "public"."is_admin"("user_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  RETURN (
    SELECT role = 'admin' FROM users WHERE id = user_id
  );
END;
$$;


ALTER FUNCTION "public"."is_admin"("user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_app_allowlisted"("p_app_name" "text") RETURNS boolean
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public'
    AS $$
SELECT EXISTS (
SELECT 1
FROM public.v_app_availability v
WHERE v.app_name = p_app_name
);
$$;


ALTER FUNCTION "public"."is_app_allowlisted"("p_app_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."log_sim_app_usage"("p_sim_number" "text", "p_app_name" "text", "p_session_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  -- Ensure the session exists before linking
  IF NOT EXISTS (
    SELECT 1 FROM public.otp_sessions WHERE id = p_session_id
  ) THEN
    RAISE EXCEPTION 'Session % not found in otp_sessions', p_session_id;
  END IF;

  -- Insert or update usage record
  INSERT INTO public.sim_app_usage (sim_number, app_name, session_id)
  VALUES (p_sim_number, p_app_name, p_session_id)
  ON CONFLICT (sim_number, app_name) DO UPDATE
  SET session_id = EXCLUDED.session_id,
      used_at   = now();
END;
$$;


ALTER FUNCTION "public"."log_sim_app_usage"("p_sim_number" "text", "p_app_name" "text", "p_session_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."manual_expire_sessions"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_expired_count integer;
BEGIN
  -- Find and expire sessions that should be expired
  UPDATE otp_sessions 
  SET 
    status = 'expired',
    status_updated_at = NOW(),
    last_activity_at = NOW()
  WHERE 
    status = 'active' 
    AND expires_at IS NOT NULL 
    AND expires_at < NOW();
    
  GET DIAGNOSTICS v_expired_count = ROW_COUNT;
  
  RETURN v_expired_count;
END;
$$;


ALTER FUNCTION "public"."manual_expire_sessions"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."match_from_gcash"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$DECLARE
window_minutes integer;
min_time timestamptz;
max_time timestamptz;
candidate record;
is_allowed boolean := false;
BEGIN
IF NEW.status IS DISTINCT FROM 'RECEIVED' OR NEW.matched_payment_id IS NOT NULL THEN
RETURN NEW;
END IF;
window_minutes := COALESCE(NEW.match_window_minutes, 30);
min_time := NEW.occurred_at - make_interval(mins => window_minutes);
max_time := NEW.occurred_at + make_interval(mins => window_minutes);
SELECT mp.id, mp.user_id, mp.app_name
INTO candidate
FROM public.manual_payments mp
WHERE mp.status = 'pending'
AND NEW.sender_number IS NOT NULL
AND mp.sender_number IS NOT NULL
AND mp.sender_number = NEW.sender_number
AND mp.amount = NEW.amount
AND mp.created_at BETWEEN min_time AND max_time
ORDER BY ABS(EXTRACT(EPOCH FROM (mp.created_at - NEW.occurred_at))) ASC
LIMIT 1;
IF candidate IS NULL THEN
RETURN NEW;
END IF;
SELECT public.is_app_allowlisted(candidate.app_name) INTO is_allowed;
IF NOT is_allowed THEN
RETURN NEW; -- custom app: leave pending, keep notif RECEIVED
END IF;
UPDATE public.manual_payments
SET status = 'approved',
approved_at = now()
WHERE id = candidate.id
AND status = 'pending';
UPDATE public.gcash_notif
SET status = 'MATCHED',
matched_payment_id = candidate.id
WHERE id = NEW.id
AND status = 'RECEIVED';
RETURN NEW;
END;$$;


ALTER FUNCTION "public"."match_from_gcash"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."match_from_manual"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$DECLARE
window_minutes integer := 30;
min_time timestamptz;
max_time timestamptz;
candidate record;
eff_amount numeric;
is_allowed boolean := false;
BEGIN
IF NEW.status IS DISTINCT FROM 'pending' THEN
RETURN NEW;
END IF;
SELECT public.is_app_allowlisted(NEW.app_name) INTO is_allowed;
IF NOT is_allowed THEN
RETURN NEW; -- custom app: leave pending for admin review
END IF;
eff_amount := NEW.amount;
min_time := NEW.created_at - make_interval(mins => window_minutes);
max_time := NEW.created_at + make_interval(mins => window_minutes);
SELECT gn.id
INTO candidate
FROM public.gcash_notif gn
WHERE gn.status = 'RECEIVED'
AND gn.amount = eff_amount
AND NEW.sender_number IS NOT NULL
AND gn.sender_number IS NOT NULL
AND gn.sender_number = NEW.sender_number
AND gn.occurred_at BETWEEN min_time AND max_time
ORDER BY ABS(EXTRACT(EPOCH FROM (NEW.created_at - gn.occurred_at))) ASC
LIMIT 1;
IF candidate IS NULL THEN
RETURN NEW;
END IF;
UPDATE public.manual_payments
SET status = 'approved',
approved_at = now()
WHERE id = NEW.id
AND status = 'pending';
UPDATE public.gcash_notif
SET status = 'MATCHED',
matched_payment_id = NEW.id
WHERE id = candidate.id
AND status = 'RECEIVED';
RETURN NEW;
END;$$;


ALTER FUNCTION "public"."match_from_manual"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."match_gcash_notif_to_wallet_topup"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    window_minutes integer;
    min_time timestamptz;
    max_time timestamptz;
    candidate record;
    v_user_balance DECIMAL(10,2);
BEGIN
    -- Only process if status is 'RECEIVED' and not already matched
    IF NEW.status IS DISTINCT FROM 'RECEIVED' OR NEW.matched_payment_id IS NOT NULL OR NEW.matched_topup_id IS NOT NULL THEN
        RETURN NEW;
    END IF;
    
    window_minutes := COALESCE(NEW.match_window_minutes, 30);
    min_time := NEW.occurred_at - make_interval(mins => window_minutes);
    max_time := NEW.occurred_at + make_interval(mins => window_minutes);
    
    -- Prefer sender_number + amount within window
    SELECT wt.id, wt.user_id, wt.amount
    INTO candidate
    FROM public.wallet_topups wt
    WHERE wt.status = 'pending'
        AND NEW.sender_number IS NOT NULL
        AND wt.sender_number IS NOT NULL
        AND wt.sender_number = NEW.sender_number
        AND wt.amount = NEW.amount
        AND wt.created_at BETWEEN min_time AND max_time
        AND wt.matched_notification_id IS NULL
    ORDER BY ABS(EXTRACT(EPOCH FROM (wt.created_at - NEW.occurred_at))) ASC
    LIMIT 1;
    
    IF candidate.id IS NULL THEN
        RETURN NEW;
    END IF;
    
    -- Get current wallet balance
    SELECT wallet_balance INTO v_user_balance
    FROM public.users
    WHERE id = candidate.user_id;
    
    -- Update wallet balance
    UPDATE public.users
    SET wallet_balance = COALESCE(v_user_balance, 0) + candidate.amount
    WHERE id = candidate.user_id;
    
    -- Create wallet transaction
    INSERT INTO public.wallet_transactions (
        user_id,
        type,
        amount,
        description,
        status,
        balance_before,
        balance_after
    ) VALUES (
        candidate.user_id,
        'topup',
        candidate.amount,
        'Wallet top-up (auto-approved via GCash notification)',
        'success',
        COALESCE(v_user_balance, 0),
        COALESCE(v_user_balance, 0) + candidate.amount
    );
    
    -- Mark top-up as approved
    UPDATE public.wallet_topups
    SET status = 'approved',
        approved_at = NOW(),
        matched_notification_id = NEW.id
    WHERE id = candidate.id
        AND status = 'pending';
    
    -- Mark gcash_notif as matched
    UPDATE public.gcash_notif
    SET status = 'MATCHED',
        matched_topup_id = candidate.id
    WHERE id = NEW.id
        AND status = 'RECEIVED';
    
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."match_gcash_notif_to_wallet_topup"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."match_wallet_topup_with_gcash_notif"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    window_minutes integer := 30;
    min_time timestamptz;
    max_time timestamptz;
    candidate record;
    v_user_balance DECIMAL(10,2);
BEGIN
    -- Only process if status is 'pending'
    IF NEW.status IS DISTINCT FROM 'pending' THEN
        RETURN NEW;
    END IF;
    
    min_time := NEW.created_at - make_interval(mins => window_minutes);
    max_time := NEW.created_at + make_interval(mins => window_minutes);
    
    -- Prefer sender_number + amount within window
    SELECT gn.id
    INTO candidate
    FROM public.gcash_notif gn
    WHERE gn.status = 'RECEIVED'
        AND gn.amount = NEW.amount
        AND NEW.sender_number IS NOT NULL
        AND gn.sender_number IS NOT NULL
        AND gn.sender_number = NEW.sender_number
        AND gn.occurred_at BETWEEN min_time AND max_time
        AND gn.matched_payment_id IS NULL
        AND gn.matched_topup_id IS NULL
    ORDER BY ABS(EXTRACT(EPOCH FROM (NEW.created_at - gn.occurred_at))) ASC
    LIMIT 1;
    
    IF candidate.id IS NULL THEN
        RETURN NEW;
    END IF;
    
    -- Get current wallet balance
    SELECT wallet_balance INTO v_user_balance
    FROM public.users
    WHERE id = NEW.user_id;
    
    -- Update wallet balance
    UPDATE public.users
    SET wallet_balance = COALESCE(v_user_balance, 0) + NEW.amount
    WHERE id = NEW.user_id;
    
    -- Create wallet transaction
    INSERT INTO public.wallet_transactions (
        user_id,
        type,
        amount,
        description,
        status,
        balance_before,
        balance_after
    ) VALUES (
        NEW.user_id,
        'topup',
        NEW.amount,
        'Wallet top-up (auto-approved via GCash notification)',
        'success',
        COALESCE(v_user_balance, 0),
        COALESCE(v_user_balance, 0) + NEW.amount
    );
    
    -- Mark top-up as approved (but don't update gcash_notif yet - that happens in AFTER trigger)
    NEW.status := 'approved';
    NEW.approved_at := NOW();
    NEW.matched_notification_id := candidate.id;
    
    -- Store the candidate.id in a temporary variable for the AFTER trigger
    -- We'll use a custom attribute or just rely on matched_notification_id
    
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."match_wallet_topup_with_gcash_notif"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."pause_sim_on_excessive_excluded_apps"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  v_count integer;
  v_old_count integer;
BEGIN
  v_count := COALESCE(jsonb_array_length(COALESCE(NEW.excluded_apps, '[]'::jsonb)), 0);
  v_old_count := COALESCE(jsonb_array_length(COALESCE(OLD.excluded_apps, '[]'::jsonb)), 0);

  -- Rule: >3 exclusions means not fresh -> pause
  IF v_count > 3 THEN
    -- Pause the SIM, but do not overwrite an existing pause reason that isn't this rule
    IF NEW.paused_reason IS NULL OR NEW.paused_reason = 'excluded_apps_over_limit' THEN
      NEW.status := 'PAUSED';
      NEW.paused_at := COALESCE(NEW.paused_at, now());
      NEW.paused_reason := 'excluded_apps_over_limit';
      NEW.paused_context := jsonb_build_object(
        'rule', 'excluded_apps_over_limit',
        'excluded_apps_count', v_count,
        'excluded_apps', COALESCE(NEW.excluded_apps, '[]'::jsonb)
      );
      NEW.updated_at := now();
    END IF;

    -- Create a device-targeted announcement only when crossing threshold (best-effort)
    IF v_old_count <= 3 AND (NEW.device_id IS NOT NULL AND length(trim(NEW.device_id)) > 0) THEN
      INSERT INTO public.announcement (
        type,
        title,
        message,
        target_device_id,
        is_active,
        priority,
        show_in_banner,
        show_in_notification
      ) VALUES (
        'warning',
        'SIM Paused: Too Many App Exclusions (Agent Quality Rules) - ' || COALESCE(NEW.number, ''),
        E'Your SIM number ' || COALESCE(NEW.number, '(unknown)') || E' has been automatically PAUSED under Agent Quality Rules.\n\n' ||
        E'Reason: The system detected that this SIM now requires more than 3 app exclusions (not considered fresh/unused).\n\n' ||
        E'Details:\n' ||
        E'- Excluded apps count: ' || v_count::text || E'\n' ||
        E'- Excluded apps: ' || COALESCE(NEW.excluded_apps::text, '[]'),
        NEW.device_id,
        true,
        10,
        true,
        true
      );
    END IF;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."pause_sim_on_excessive_excluded_apps"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."preserve_private_sims"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  -- Block *any* change between public and private
  IF (OLD.type <> NEW.type) THEN
    NEW.type := OLD.type;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."preserve_private_sims"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."prevent_claimed_status_change"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    -- If the old status was 'claimed', prevent any change to it
    IF OLD.status = 'claimed' AND NEW.status != 'claimed' THEN
        RAISE EXCEPTION 'Cannot change milestone status from claimed to %', NEW.status;
    END IF;
    
    -- If the old status was 'claimed', prevent clearing claimed_at
    IF OLD.status = 'claimed' AND NEW.claimed_at IS NULL THEN
        RAISE EXCEPTION 'Cannot clear claimed_at timestamp for a claimed milestone';
    END IF;
    
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."prevent_claimed_status_change"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."prevent_claimed_status_change"() IS 'Prevents changing milestone status from claimed back to any other status. Once a milestone is claimed, it cannot be unclaimed.';



CREATE OR REPLACE FUNCTION "public"."process_agent_earnings_on_otp_complete"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$DECLARE
  v_agent_user_id uuid;
  v_price numeric(12,2);
  v_gross_amount numeric(12,2);
  v_agent_share numeric(12,2);
  v_site_share numeric(12,2);
  v_commission_rate numeric(5,2);
BEGIN
  -- Only process when status changes to 'completed' and sim_number exists
  IF NEW.status = 'completed' 
     AND (OLD.status IS NULL OR OLD.status != 'completed')
     AND NEW.sim_number IS NOT NULL THEN
    
    -- Find agent user_id from sim_number (via sims -> devices -> users)
    SELECT d.user_id INTO v_agent_user_id
    FROM public.sims s
    JOIN public.devices d ON s.device_id = d.device_id
    WHERE s.number = NEW.sim_number
    LIMIT 1;
    
    -- Only proceed if agent found
    IF v_agent_user_id IS NOT NULL THEN
      -- Get pricing for this app
      SELECT price INTO v_price
      FROM public.otp_pricing
      WHERE app_name = NEW.app_name
      LIMIT 1;
      
      -- Use pricing or default to 0.10
      v_gross_amount := COALESCE(v_price, 0.10);
      
      -- Get dynamic commission rate for this agent
      v_commission_rate := public.get_agent_commission_rate(v_agent_user_id);
      
      -- Calculate split using dynamic rate
      v_agent_share := v_gross_amount * (v_commission_rate / 100.00);
      v_site_share := v_gross_amount - v_agent_share;
      
      -- Ensure split matches gross (rounding adjustment)
      IF (v_agent_share + v_site_share) != v_gross_amount THEN
        v_site_share := v_gross_amount - v_agent_share;
      END IF;
      
      -- Update sim_app_usage with agent info and revenue
      -- This will trigger create_agent_transaction_from_usage()
      UPDATE public.sim_app_usage
      SET agent_user_id = v_agent_user_id,
          gross_amount = v_gross_amount,
          agent_share = v_agent_share,
          site_share = v_site_share,
          session_id = NEW.id,
          used_at = COALESCE(used_at, NOW()),
          agent_direct = NEW.agent_direct  -- ✅ propagate agent_direct
      WHERE sim_number = NEW.sim_number
        AND app_name = NEW.app_name;
      
      -- If sim_app_usage doesn't exist yet, create it
      IF NOT FOUND THEN
        INSERT INTO public.sim_app_usage (
          sim_number,
          app_name,
          agent_user_id,
          gross_amount,
          agent_share,
          site_share,
          session_id,
          used_at,
          agent_direct  -- ✅ propagate agent_direct
        ) VALUES (
          NEW.sim_number,
          NEW.app_name,
          v_agent_user_id,
          v_gross_amount,
          v_agent_share,
          v_site_share,
          NEW.id,
          NOW(),
          NEW.agent_direct
        )
        ON CONFLICT (sim_number, app_name) DO UPDATE
        SET agent_user_id = EXCLUDED.agent_user_id,
            gross_amount = EXCLUDED.gross_amount,
            agent_share = EXCLUDED.agent_share,
            site_share = EXCLUDED.site_share,
            session_id = EXCLUDED.session_id,
            used_at = COALESCE(sim_app_usage.used_at, EXCLUDED.used_at),
            agent_direct = EXCLUDED.agent_direct; -- ✅ propagate agent_direct
      END IF;
    END IF;
  END IF;
  
  RETURN NEW;
END;$$;


ALTER FUNCTION "public"."process_agent_earnings_on_otp_complete"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."process_agent_earnings_on_otp_complete"() IS 'Automatically processes agent earnings when OTP session completes';



CREATE OR REPLACE FUNCTION "public"."process_referral_commission"("p_otp_session_id" "uuid", "p_user_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_referrer_id UUID;
    v_commission_rate DECIMAL(10,2);
    v_referrer_exists BOOLEAN;
    v_existing_count INTEGER;
    v_lock_acquired BOOLEAN;
BEGIN
    -- Validate inputs
    IF p_otp_session_id IS NULL OR p_user_id IS NULL THEN
        RETURN;
    END IF;
    
    -- Use advisory lock to prevent concurrent execution
    v_lock_acquired := pg_try_advisory_xact_lock(
        hashtext(p_otp_session_id::text)
    );
    
    IF NOT v_lock_acquired THEN
        RETURN;
    END IF;
    
    -- Check if earnings already exist for this OTP session (any referrer)
    SELECT COUNT(*) INTO v_existing_count
    FROM public.referral_earnings
    WHERE otp_session_id = p_otp_session_id;
    
    -- Exit immediately if ANY earnings exist
    IF v_existing_count > 0 THEN
        RETURN;
    END IF;
    
    -- Get referrer for this user (ONLY the direct referrer)
    SELECT referred_by INTO v_referrer_id
    FROM public.users
    WHERE id = p_user_id 
    AND referred_by IS NOT NULL
    LIMIT 1;
    
    -- Exit if user has no referrer
    IF v_referrer_id IS NULL THEN
        RETURN;
    END IF;
    
    -- Check if referrer still exists and is not archived
    SELECT EXISTS(
        SELECT 1 FROM public.users 
        WHERE id = v_referrer_id 
        AND (is_archived IS NULL OR is_archived = false)
    ) INTO v_referrer_exists;
    
    IF NOT v_referrer_exists THEN
        RETURN;
    END IF;
    
    -- Final check: Verify no earnings exist for this specific OTP session and referrer
    SELECT COUNT(*) INTO v_existing_count
    FROM public.referral_earnings
    WHERE otp_session_id = p_otp_session_id
    AND referrer_id = v_referrer_id;
    
    IF v_existing_count > 0 THEN
        RETURN;
    END IF;
    
    -- Get current commission rate from config
    SELECT commission_per_otp INTO v_commission_rate
    FROM public.referral_config
    WHERE is_active = true
    ORDER BY created_at DESC
    LIMIT 1;
    
    -- Default to 0.20 if no config found
    IF v_commission_rate IS NULL THEN
        v_commission_rate := 0.20;
    END IF;
    
    -- Create referral earnings record (ONLY ONE record per OTP session)
    INSERT INTO public.referral_earnings (
        referrer_id,
        referred_user_id,
        otp_session_id,
        amount,
        status
    )
    VALUES (
        v_referrer_id,
        p_user_id,
        p_otp_session_id,
        v_commission_rate,
        'pending'
    )
    ON CONFLICT (otp_session_id, referrer_id) DO NOTHING;
    
    -- Update milestone progress
    PERFORM update_milestone_progress(v_referrer_id);
    
END;
$$;


ALTER FUNCTION "public"."process_referral_commission"("p_otp_session_id" "uuid", "p_user_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."process_referral_commission"("p_otp_session_id" "uuid", "p_user_id" "uuid") IS 'Processes referral commission when OTP session is completed. Creates exactly ONE earnings record per OTP session.';



CREATE OR REPLACE FUNCTION "public"."recalculate_agent_balance_from_transactions"("p_user_id" "uuid") RETURNS TABLE("pending_balance" numeric, "available_balance" numeric, "lifetime_claimed" numeric)
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  v_pending numeric(12,2) := 0;
  v_available numeric(12,2) := 0;
  v_lifetime_claimed numeric(12,2) := 0;
BEGIN
  -- Calculate pending balance (sum of all pending transactions)
  SELECT COALESCE(SUM(agent_share), 0) INTO v_pending
  FROM public.agent_transactions
  WHERE user_id = p_user_id AND status = 'pending';

  -- Calculate available balance (sum of all available transactions)
  SELECT COALESCE(SUM(agent_share), 0) INTO v_available
  FROM public.agent_transactions
  WHERE user_id = p_user_id AND status = 'available';

  -- Calculate lifetime claimed (sum of all claimed transactions)
  SELECT COALESCE(SUM(agent_share), 0) INTO v_lifetime_claimed
  FROM public.agent_transactions
  WHERE user_id = p_user_id AND status = 'claimed';

  -- Update or insert the balance record
  INSERT INTO public.agent_balances (user_id, pending_balance, available_balance, lifetime_claimed, updated_at)
  VALUES (p_user_id, v_pending, v_available, v_lifetime_claimed, NOW())
  ON CONFLICT (user_id) DO UPDATE
  SET pending_balance = EXCLUDED.pending_balance,
      available_balance = EXCLUDED.available_balance,
      lifetime_claimed = EXCLUDED.lifetime_claimed,
      updated_at = NOW();

  -- Return the calculated values
  RETURN QUERY SELECT v_pending, v_available, v_lifetime_claimed;
END;
$$;


ALTER FUNCTION "public"."recalculate_agent_balance_from_transactions"("p_user_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."recalculate_agent_balance_from_transactions"("p_user_id" "uuid") IS 'Recalculates agent balance from transactions (source of truth) and updates agent_balances table';



CREATE OR REPLACE FUNCTION "public"."recalculate_all_agent_balances"() RETURNS TABLE("user_id" "uuid", "pending_balance" numeric, "available_balance" numeric, "lifetime_claimed" numeric, "updated_count" integer)
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  v_user_record RECORD;
  v_updated_count integer := 0;
BEGIN
  -- Loop through all users who have agent transactions
  FOR v_user_record IN
    SELECT DISTINCT agent_transactions.user_id
    FROM public.agent_transactions
  LOOP
    -- Recalculate balance for this user
    PERFORM public.recalculate_agent_balance_from_transactions(v_user_record.user_id);
    v_updated_count := v_updated_count + 1;
  END LOOP;

  -- Also handle users who have balance records but no transactions (set to 0)
  UPDATE public.agent_balances
  SET pending_balance = 0,
      available_balance = 0,
      lifetime_claimed = COALESCE(agent_balances.lifetime_claimed, 0),
      updated_at = NOW()
  WHERE agent_balances.user_id NOT IN (SELECT DISTINCT agent_transactions.user_id FROM public.agent_transactions);

  -- Return summary
  RETURN QUERY
  SELECT 
    ab.user_id,
    ab.pending_balance,
    ab.available_balance,
    ab.lifetime_claimed,
    v_updated_count
  FROM public.agent_balances ab
  WHERE ab.user_id IN (SELECT DISTINCT agent_transactions.user_id FROM public.agent_transactions);
END;
$$;


ALTER FUNCTION "public"."recalculate_all_agent_balances"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."recalculate_all_agent_balances"() IS 'Recalculates all agent balances from transactions (fixes any discrepancies)';



CREATE OR REPLACE FUNCTION "public"."recalculate_sim_stats"("p_sim_id" bigint) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  v_sim_number text;
  v_completed_count integer;
  v_failed_count integer;
  v_uptime_seconds bigint;
  v_total_earnings numeric;
BEGIN
  -- Get SIM number
  SELECT number INTO v_sim_number
  FROM public.sims
  WHERE id = p_sim_id;

  IF v_sim_number IS NULL THEN
    RAISE EXCEPTION 'SIM with id % not found', p_sim_id;
  END IF;

  -- Count completed from sim_app_usage
  SELECT COUNT(*) INTO v_completed_count
  FROM public.sim_app_usage
  WHERE sim_app_usage.sim_number = v_sim_number;

  -- Get existing values (preserve uptime, earnings, failed)
  SELECT 
    COALESCE(sim_stats.total_failed, 0),
    COALESCE(sim_stats.uptime_seconds, 0),
    COALESCE(sim_stats.total_earnings, 0)
  INTO v_failed_count, v_uptime_seconds, v_total_earnings
  FROM public.sim_stats
  WHERE sim_stats.sim_id = p_sim_id;

  -- Update or insert
  INSERT INTO public.sim_stats (
    sim_id,
    total_completed,
    total_failed,
    uptime_seconds,
    total_earnings,
    updated_at
  )
  VALUES (
    p_sim_id,
    v_completed_count,
    COALESCE(v_failed_count, 0),
    COALESCE(v_uptime_seconds, 0),
    COALESCE(v_total_earnings, 0),
    now()
  )
  ON CONFLICT ON CONSTRAINT sim_stats_pkey DO UPDATE
  SET 
    total_completed = EXCLUDED.total_completed,
    updated_at = now();
END;
$$;


ALTER FUNCTION "public"."recalculate_sim_stats"("p_sim_id" bigint) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."recalculate_sim_stats"("p_sim_id" bigint) IS 'Recalculates and updates sims table for a specific SIM based on current sim_app_usage data';



CREATE OR REPLACE FUNCTION "public"."record_sim_completion_from_usage"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  v_sim_id bigint;
BEGIN
  -- Find SIM ID by number
  SELECT id INTO v_sim_id
  FROM public.sims
  WHERE sims.number = NEW.sim_number;

  -- If SIM found, update sims table directly
  IF v_sim_id IS NOT NULL THEN
    -- Update total_completed in sims table
    UPDATE public.sims
    SET 
      total_completed = COALESCE(total_completed, 0) + 1,
      updated_at = now()
    WHERE id = v_sim_id;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."record_sim_completion_from_usage"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."record_sim_completion_from_usage"() IS 'Automatically records SIM completions in sims table when a SIM is successfully used for an app';



CREATE OR REPLACE FUNCTION "public"."record_sim_failure_on_expire"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  v_message_count integer;
  v_sim_id bigint;
  v_already_recorded boolean := false;
BEGIN
  -- Only process if status changed to 'expired'
  -- Check both OLD and NEW to ensure we catch the transition
  IF NEW.status = 'expired' AND (OLD.status IS NULL OR OLD.status != 'expired') THEN
    -- Check if we've already recorded a failure for this session and SIM
    -- First, get the SIM ID
    SELECT id INTO v_sim_id
    FROM public.sims
    WHERE sims.number = NEW.sim_number;

    -- Only proceed if we have a SIM ID
    IF v_sim_id IS NOT NULL THEN
      -- Check if we've already recorded this failure
      SELECT EXISTS(
        SELECT 1 FROM public.sim_failure_records 
        WHERE session_id = NEW.id 
          AND sim_id = v_sim_id 
          AND failure_type = 'expired'
      ) INTO v_already_recorded;

      -- Only proceed if we haven't already recorded this failure
      IF NOT v_already_recorded THEN
        -- Count messages for this session
        SELECT COUNT(*) INTO v_message_count
        FROM public.sms_messages
        WHERE consumed_by_session = NEW.id;

        -- If session has no messages and has a SIM number, record failure
        IF v_message_count = 0 AND NEW.sim_number IS NOT NULL THEN
          -- Update total_failed in sims table
          UPDATE public.sims
          SET 
            total_failed = COALESCE(total_failed, 0) + 1,
            updated_at = now()
          WHERE id = v_sim_id;

          -- Record that we've processed this failure
          -- Use the correct ON CONFLICT clause matching the unique constraint
          INSERT INTO public.sim_failure_records (session_id, sim_id, failure_type)
          VALUES (NEW.id, v_sim_id, 'expired')
          ON CONFLICT (session_id, sim_id, failure_type) DO NOTHING;
        END IF;
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."record_sim_failure_on_expire"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."record_sim_failure_on_expire"() IS 'Automatically records SIM failures in sims table when a session expires with no messages received. Uses (session_id, sim_id, failure_type) unique constraint.';



CREATE OR REPLACE FUNCTION "public"."record_sim_heartbeat"("p_sim_number" "text") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  now_ts TIMESTAMP WITH TIME ZONE := now();
  delta_seconds BIGINT;
  v_device_id TEXT;
  v_sim_active BOOLEAN;
  v_device_online BOOLEAN;
BEGIN
  SELECT
    EXTRACT(EPOCH FROM (now_ts - s.last_heartbeat)),
    s.device_id,
    (s.status = 'ACTIVE'),
    (d.status = 'online')
  INTO
    delta_seconds,
    v_device_id,
    v_sim_active,
    v_device_online
  FROM sims s
  LEFT JOIN devices d ON d.device_id = s.device_id
  WHERE s.number = p_sim_number
  FOR UPDATE;

  -- First heartbeat
  IF delta_seconds IS NULL THEN
    UPDATE sims
    SET last_heartbeat = now_ts,
        last_seen = now_ts
    WHERE number = p_sim_number;
    RETURN;
  END IF;

  -- Accumulate uptime only if SIM + DEVICE are valid
  IF v_sim_active
     AND v_device_online
     AND delta_seconds > 0
     AND delta_seconds <= 120 THEN

    UPDATE sims
    SET uptime_seconds = uptime_seconds + delta_seconds,
        last_heartbeat = now_ts,
        last_seen = now_ts
    WHERE number = p_sim_number;

    UPDATE devices
    SET uptime_seconds = uptime_seconds + delta_seconds,
        last_seen = now_ts
    WHERE device_id = v_device_id;

  ELSE
    -- Still update heartbeat timestamps
    UPDATE sims
    SET last_heartbeat = now_ts,
        last_seen = now_ts
    WHERE number = p_sim_number;
  END IF;
END;
$$;


ALTER FUNCTION "public"."record_sim_heartbeat"("p_sim_number" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reset_sim_failure_streak_on_success_usage"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  v_sim_id bigint;
BEGIN
  -- Only reset when session_id is linked (authoritative successful usage)
  IF NEW.session_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT id INTO v_sim_id
  FROM public.sims
  WHERE sims.number = NEW.sim_number;

  IF v_sim_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- Reset streak
  INSERT INTO public.sim_failure_streaks (sim_id, failed_apps, updated_at)
  VALUES (v_sim_id, '{}'::text[], now())
  ON CONFLICT (sim_id) DO UPDATE
  SET failed_apps = '{}'::text[],
      updated_at = now();

  -- Note: do not auto-resume SIM here; only clear reason/context if it was previously set
  UPDATE public.sims
  SET
    paused_reason = NULL,
    paused_context = NULL
  WHERE id = v_sim_id;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."reset_sim_failure_streak_on_success_usage"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_default_referrer_for_users"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_default_referrer_id UUID := '61665c4b-6a7d-4b0d-8475-8ed5de81ee82';
    v_updated_count INTEGER;
    v_result JSONB;
BEGIN
    -- Verify default referrer exists
    IF NOT EXISTS (SELECT 1 FROM public.users WHERE id = v_default_referrer_id) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Default referrer user not found'
        );
    END IF;

    -- Update users without referrer
    UPDATE public.users
    SET referred_by = v_default_referrer_id
    WHERE referred_by IS NULL
        AND id != v_default_referrer_id; -- Don't set self-referral

    GET DIAGNOSTICS v_updated_count = ROW_COUNT;

    -- Log manual assignments for audit
    INSERT INTO public.manual_referral_assignments (
        referred_user_id,
        referrer_id,
        assigned_by,
        previous_referrer_id,
        reason
    )
    SELECT 
        u.id,
        v_default_referrer_id,
        v_default_referrer_id, -- System assignment
        NULL,
        'Default referrer assignment (migration)'
    FROM public.users u
    WHERE u.referred_by = v_default_referrer_id
        AND NOT EXISTS (
            SELECT 1 FROM public.manual_referral_assignments mra
            WHERE mra.referred_user_id = u.id
            AND mra.referrer_id = v_default_referrer_id
        );

    RETURN jsonb_build_object(
        'success', true,
        'updated_count', v_updated_count,
        'default_referrer_id', v_default_referrer_id
    );
END;
$$;


ALTER FUNCTION "public"."set_default_referrer_for_users"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."set_default_referrer_for_users"() IS 'Sets default referrer for all users without a referrer';



CREATE OR REPLACE FUNCTION "public"."snapshot_christmas_2025_failed_baseline"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_event_start_gmt8 timestamp := TIMESTAMP '2025-12-20 18:00:00';
  v_now_gmt8 timestamp := (NOW() AT TIME ZONE 'Asia/Manila');
  v_updated bigint := 0;
BEGIN
  IF v_now_gmt8 < v_event_start_gmt8 THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'event_not_started',
      'event_start_gmt8', v_event_start_gmt8,
      'now_gmt8', v_now_gmt8,
      'updated', 0
    );
  END IF;

  UPDATE public.sims
  SET
    christmas_2025_failed_baseline = total_failed,
    christmas_2025_failed_baseline_set_at = NOW()
  WHERE christmas_2025_failed_baseline_set_at IS NULL;

  GET DIAGNOSTICS v_updated = ROW_COUNT;

  RETURN jsonb_build_object(
    'ok', true,
    'event_start_gmt8', v_event_start_gmt8,
    'now_gmt8', v_now_gmt8,
    'updated', v_updated
  );
END;
$$;


ALTER FUNCTION "public"."snapshot_christmas_2025_failed_baseline"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."snapshot_christmas_2025_uptime_ranking"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_event_end_gmt8 timestamp := TIMESTAMP '2025-12-31 00:00:00';
  v_now_gmt8 timestamp := (NOW() AT TIME ZONE 'Asia/Manila');
  v_inserted bigint := 0;
BEGIN
  IF v_now_gmt8 < v_event_end_gmt8 THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'event_not_ended',
      'event_end_gmt8', v_event_end_gmt8,
      'now_gmt8', v_now_gmt8,
      'inserted', 0
    );
  END IF;

  IF EXISTS (SELECT 1 FROM public.christmas_2025_uptime_ranking_snapshot LIMIT 1) THEN
    RETURN jsonb_build_object(
      'ok', true,
      'reason', 'already_snapshotted',
      'event_end_gmt8', v_event_end_gmt8,
      'now_gmt8', v_now_gmt8,
      'inserted', 0
    );
  END IF;

  INSERT INTO public.christmas_2025_uptime_ranking_snapshot (
    rank,
    user_id,
    email,
    top_device_id,
    top_device_name,
    top_uptime_seconds,
    completed_sessions,
    expired_sessions,
    reliability_pct,
    cancelled_transactions,
    total_profit,
    is_eligible
  )
  SELECT
    v.rank,
    v.user_id,
    v.email,
    v.top_device_id,
    v.top_device_name,
    v.top_uptime_seconds,
    v.completed_sessions,
    v.expired_sessions,
    v.reliability_pct,
    v.cancelled_transactions,
    v.total_profit,
    v.is_eligible
  FROM public.v_christmas_2025_uptime_ranking_live v;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  RETURN jsonb_build_object(
    'ok', true,
    'event_end_gmt8', v_event_end_gmt8,
    'now_gmt8', v_now_gmt8,
    'inserted', v_inserted
  );
END;
$$;


ALTER FUNCTION "public"."snapshot_christmas_2025_uptime_ranking"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_all_milestones_from_config"() RETURNS integer
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_milestone_item JSONB;
    v_required_otps INTEGER;
    v_bonus DECIMAL;
    v_milestone_config JSONB;
    v_updated_count INTEGER := 0;
    v_row_count INTEGER;
BEGIN
    -- Get active config
    SELECT milestone_settings INTO v_milestone_config
    FROM public.referral_config
    WHERE is_active = true
    ORDER BY created_at DESC
    LIMIT 1;
    
    -- If no config, return 0
    IF v_milestone_config IS NULL THEN
        RAISE NOTICE 'No active referral config found';
        RETURN 0;
    END IF;
    
    -- Process each milestone in the config
    FOR v_milestone_item IN SELECT * FROM jsonb_array_elements(v_milestone_config)
    LOOP
        -- Use required_otps and bonus (primary fields), fallback to old format for backward compatibility
        v_required_otps := COALESCE(
            (v_milestone_item->>'required_otps')::INTEGER,
            (v_milestone_item->>'referrals_required')::INTEGER,
            0
        );
        
        v_bonus := COALESCE(
            (v_milestone_item->>'bonus')::DECIMAL,
            (v_milestone_item->>'bonus_amount')::DECIMAL,
            0
        );
        
        -- Update all existing milestone records for this level with new values
        UPDATE public.referral_milestones
        SET 
            required_completed_otps = v_required_otps,
            bonus_amount = v_bonus,
            updated_at = NOW()
        WHERE milestone_level = (v_milestone_item->>'level')::INTEGER
            AND status != 'claimed';  -- Don't update claimed milestones
        
        GET DIAGNOSTICS v_row_count = ROW_COUNT;
        v_updated_count := v_updated_count + v_row_count;
        
        -- Recalculate status for milestones that might have changed requirements
        UPDATE public.referral_milestones
        SET 
            status = CASE
                WHEN progress >= v_required_otps AND status != 'claimed' THEN 'completed'
                WHEN progress > 0 THEN 'in_progress'
                ELSE 'locked'
            END,
            completed_at = CASE
                WHEN progress >= v_required_otps 
                    AND completed_at IS NULL 
                    AND status != 'claimed' 
                THEN NOW()
                ELSE completed_at
            END,
            updated_at = NOW()
        WHERE milestone_level = (v_milestone_item->>'level')::INTEGER
            AND status != 'claimed';
    END LOOP;
    
    RETURN v_updated_count;
END;
$$;


ALTER FUNCTION "public"."sync_all_milestones_from_config"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."sync_all_milestones_from_config"() IS 'Manually syncs all referral_milestones records with the current active referral_config. Returns the number of records updated. Use this if the trigger didn''t fire or if you need to sync milestones manually.';



CREATE OR REPLACE FUNCTION "public"."sync_manual_payment_user_email"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$BEGIN
    -- If user_id is provided, always sync from users table
    IF NEW.user_id IS NOT NULL THEN
        SELECT email INTO NEW.user_email
        FROM public.users
        WHERE id = NEW.user_id;
    END IF;

    -- If user_id is NULL, keep whatever NEW.user_email was set to by the caller
    RETURN NEW;
END;$$;


ALTER FUNCTION "public"."sync_manual_payment_user_email"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_otp_session_user_email"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    -- If user_id is provided, fetch the email from users table
    IF NEW.user_id IS NOT NULL THEN
        SELECT email INTO NEW.user_email
        FROM public.users
        WHERE id = NEW.user_id;
    ELSE
        -- If user_id is NULL, preserve existing user_email (don't clear it)
        -- This allows user_email to persist even after detaching user_id
        -- for historical/audit purposes and smooth database management
        NEW.user_email := COALESCE(NEW.user_email, OLD.user_email);
    END IF;
    
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."sync_otp_session_user_email"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_sim_user_email"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  select u.email
  into new.user_email
  from public.devices d
  join public.users u
    on u.id = d.user_id
  where d.device_id = new.device_id;

  return new;
end;
$$;


ALTER FUNCTION "public"."sync_sim_user_email"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_sim_user_email_from_device"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  update public.sims s
  set user_email = u.email
  from public.users u
  where s.device_id = new.device_id
    and u.id = new.user_id;

  return new;
end;
$$;


ALTER FUNCTION "public"."sync_sim_user_email_from_device"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_sim_user_email_from_user"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  update public.sims s
  set user_email = new.email
  from public.devices d
  where d.device_id = s.device_id
    and d.user_id = new.id;

  return new;
end;
$$;


ALTER FUNCTION "public"."sync_sim_user_email_from_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_voucher_code"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  IF NEW.voucher_id IS NOT NULL THEN
    SELECT code INTO NEW.voucher_code FROM vouchers WHERE id = NEW.voucher_id;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."sync_voucher_code"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_wallet_topup_user_email"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    -- If user_id is provided, fetch the email from users table
    IF NEW.user_id IS NOT NULL THEN
        SELECT email INTO NEW.user_email
        FROM public.users
        WHERE id = NEW.user_id;
    END IF;
    
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."sync_wallet_topup_user_email"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."transition_otp_session_status"("session_id" "uuid", "new_status" "text", "timeout_minutes" integer DEFAULT 10) RETURNS boolean
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  current_status TEXT;
  expires_time TIMESTAMP WITH TIME ZONE;
  current_retry_count INTEGER;
  current_retry_limit INTEGER;
BEGIN
  -- Get current status and retry info
  SELECT status, retry_count, retry_limit 
  INTO current_status, current_retry_count, current_retry_limit
  FROM otp_sessions 
  WHERE id = session_id;
  
  -- Validate session exists
  IF current_status IS NULL THEN
    RETURN FALSE; -- Session not found
  END IF;
  
  -- Check retry limit for expired -> pending transitions
  IF current_status = 'expired' AND new_status = 'pending' THEN
    IF current_retry_count >= current_retry_limit THEN
      RETURN FALSE; -- Retry limit exceeded
    END IF;
  END IF;
  
  -- Define valid transitions (updated to allow expired -> pending)
  IF NOT (
    (current_status = 'pending' AND new_status IN ('active', 'expired')) OR
    (current_status = 'active' AND new_status IN ('completed', 'expired')) OR
    (current_status = 'completed' AND new_status = 'expired') OR
    (current_status = 'expired' AND new_status = 'pending') -- Allow retry
  ) THEN
    RETURN FALSE; -- Invalid transition
  END IF;
  
  -- Calculate expires_at for active status
  IF new_status = 'active' THEN
    expires_time := NOW() + (timeout_minutes || ' minutes')::INTERVAL;
  ELSE
    expires_time := NULL;
  END IF;
  
  -- Update the session with retry tracking
  UPDATE otp_sessions 
  SET 
    status = new_status,
    status_updated_at = NOW(),
    expires_at = expires_time,
    last_activity_at = NOW(),
    retry_count = CASE 
      WHEN current_status = 'expired' AND new_status = 'pending' THEN retry_count + 1
      ELSE retry_count
    END,
    last_retry_at = CASE 
      WHEN current_status = 'expired' AND new_status = 'pending' THEN NOW()
      ELSE last_retry_at
    END
  WHERE id = session_id;
  
  RETURN TRUE;
END;
$$;


ALTER FUNCTION "public"."transition_otp_session_status"("session_id" "uuid", "new_status" "text", "timeout_minutes" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_manual_payments_apply_payment_method_balance"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    IF NEW.status = 'approved'
        AND NEW.voucher_id IS NULL
        AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM NEW.status)
    THEN
        PERFORM public.apply_payment_method_txn(
            NEW.payment_method_id,
            'in',
            NEW.amount,
            'manual_payments',
            NEW.id,
            COALESCE(NEW.approved_at, NOW())
        );
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_manual_payments_apply_payment_method_balance"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_wallet_topups_apply_payment_method_balance"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_payment_method_id UUID;
BEGIN
    IF NEW.status = 'approved' AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM NEW.status) THEN
        -- wallet_topups.payment_method_id is TEXT.
        -- In practice it may contain:
        -- 1) payment_methods.id as a UUID string, or
        -- 2) a method key like 'gcash'
        SELECT pm.id
        INTO v_payment_method_id
        FROM public.payment_methods pm
        WHERE pm.id::text = NEW.payment_method_id
           OR lower(pm.name) = lower(NEW.payment_method_id)
        LIMIT 1;

        PERFORM public.apply_payment_method_txn(
            v_payment_method_id,
            'in',
            NEW.amount,
            'wallet_topups',
            NEW.id,
            COALESCE(NEW.approved_at, NOW())
        );
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_wallet_topups_apply_payment_method_balance"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_wallet_withdrawals_apply_payment_method_balance"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_payment_method_id UUID;
BEGIN
    IF NEW.type = 'withdrawal'
        AND NEW.status = 'success'
        AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM NEW.status)
    THEN
        SELECT pm.id
        INTO v_payment_method_id
        FROM public.withdrawal_payment_methods wpm
        JOIN public.payment_methods pm
            ON lower(pm.name) = lower(wpm.name)
        WHERE wpm.id = NEW.withdrawal_payment_method_id
        LIMIT 1;

        PERFORM public.apply_payment_method_txn(
            v_payment_method_id,
            'out',
            NEW.amount,
            'wallet_transactions',
            NEW.id,
            COALESCE(NEW.processed_at, NOW())
        );
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_wallet_withdrawals_apply_payment_method_balance"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trigger_agent_invite_earning_on_insert"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  PERFORM public.create_agent_invite_earning_for_tx(NEW.id);
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trigger_agent_invite_earning_on_insert"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trigger_agent_invite_earning_on_status_update"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  -- Only act when status changes into available/claimed
  IF lower(coalesce(OLD.status,'')) = lower(coalesce(NEW.status,'')) THEN
    RETURN NEW;
  END IF;

  PERFORM public.create_agent_invite_earning_for_tx(NEW.id);
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trigger_agent_invite_earning_on_status_update"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trigger_auto_link_sms"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_result text;
BEGIN
  -- Call auto-link function immediately after message insertion
  SELECT public.auto_link_sms_to_otp_session(NEW.sim_number) INTO v_result;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trigger_auto_link_sms"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trigger_process_referral_on_otp_complete"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_already_processed BOOLEAN;
BEGIN
    -- Only process if:
    -- 1. Status changed to 'completed'
    -- 2. user_id exists
    -- 3. Commission hasn't been processed yet
    IF NEW.status = 'completed' 
       AND (OLD.status IS NULL OR OLD.status != 'completed') 
       AND NEW.user_id IS NOT NULL
       AND (NEW.commission_processed IS NULL OR NEW.commission_processed = false) THEN
        
        -- Check if earnings already exist (double safety)
        SELECT EXISTS(
            SELECT 1 FROM public.referral_earnings
            WHERE otp_session_id = NEW.id
            LIMIT 1
        ) INTO v_already_processed;
        
        -- Only process if earnings don't already exist
        IF NOT v_already_processed THEN
            -- Process commission
            PERFORM process_referral_commission(NEW.id, NEW.user_id);
            
            -- Mark as processed to prevent future processing
            NEW.commission_processed := true;
        ELSE
            -- Earnings already exist, just mark as processed
            NEW.commission_processed := true;
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trigger_process_referral_on_otp_complete"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_agent_applications_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_agent_applications_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_agent_balance_mature"("p_user_id" "uuid", "p_amount" numeric) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  UPDATE public.agent_balances
  SET pending_balance = pending_balance - p_amount,
      available_balance = available_balance + p_amount,
      updated_at = NOW()
  WHERE user_id = p_user_id;
END;
$$;


ALTER FUNCTION "public"."update_agent_balance_mature"("p_user_id" "uuid", "p_amount" numeric) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."update_agent_balance_mature"("p_user_id" "uuid", "p_amount" numeric) IS 'Helper function to move amount from pending to available balance';



CREATE OR REPLACE FUNCTION "public"."update_agent_balance_on_transaction_change"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  v_amount numeric(12,2);
  v_old_status varchar(16);
  v_new_status varchar(16);
BEGIN
  v_amount := COALESCE(NEW.agent_share, 0);
  v_old_status := COALESCE(OLD.status, '');
  v_new_status := NEW.status;

  -- Handle INSERT (new transaction created)
  IF TG_OP = 'INSERT' THEN
    -- New transaction starts as 'pending', add to pending_balance
    IF NEW.status = 'pending' THEN
      INSERT INTO public.agent_balances (user_id, pending_balance, available_balance, lifetime_claimed)
      VALUES (NEW.user_id, v_amount, 0, 0)
      ON CONFLICT (user_id) DO UPDATE
      SET pending_balance = agent_balances.pending_balance + v_amount,
          updated_at = NOW();
    END IF;
    RETURN NEW;
  END IF;

  -- Handle UPDATE (status change)
  IF TG_OP = 'UPDATE' THEN
    -- Status changed from 'pending' to 'available' (matured)
    IF v_old_status = 'pending' AND v_new_status = 'available' THEN
      UPDATE public.agent_balances
      SET pending_balance = pending_balance - v_amount,
          available_balance = available_balance + v_amount,
          updated_at = NOW()
      WHERE user_id = NEW.user_id;
    END IF;

    -- Status changed to 'claimed' (from any status)
    IF v_new_status = 'claimed' AND v_old_status != 'claimed' THEN
      -- If was 'available', decrease available_balance and increase lifetime_claimed
      IF v_old_status = 'available' THEN
        UPDATE public.agent_balances
        SET available_balance = available_balance - v_amount,
            lifetime_claimed = lifetime_claimed + v_amount,
            updated_at = NOW()
        WHERE user_id = NEW.user_id;
      -- If was 'pending' (direct claim without maturation), decrease pending and increase lifetime
      ELSIF v_old_status = 'pending' THEN
        UPDATE public.agent_balances
        SET pending_balance = pending_balance - v_amount,
            lifetime_claimed = lifetime_claimed + v_amount,
            updated_at = NOW()
        WHERE user_id = NEW.user_id;
      END IF;
    END IF;

    -- Status changed from 'available' or 'claimed' back to 'pending' (shouldn't happen, but handle it)
    IF v_new_status = 'pending' AND (v_old_status = 'available' OR v_old_status = 'claimed') THEN
      IF v_old_status = 'available' THEN
        UPDATE public.agent_balances
        SET available_balance = available_balance - v_amount,
            pending_balance = pending_balance + v_amount,
            updated_at = NOW()
        WHERE user_id = NEW.user_id;
      ELSIF v_old_status = 'claimed' THEN
        UPDATE public.agent_balances
        SET lifetime_claimed = lifetime_claimed - v_amount,
            pending_balance = pending_balance + v_amount,
            updated_at = NOW()
        WHERE user_id = NEW.user_id;
      END IF;
    END IF;

    RETURN NEW;
  END IF;

  -- Handle DELETE (remove from balances)
  IF TG_OP = 'DELETE' THEN
    IF OLD.status = 'pending' THEN
      UPDATE public.agent_balances
      SET pending_balance = pending_balance - OLD.agent_share,
          updated_at = NOW()
      WHERE user_id = OLD.user_id;
    ELSIF OLD.status = 'available' THEN
      UPDATE public.agent_balances
      SET available_balance = available_balance - OLD.agent_share,
          updated_at = NOW()
      WHERE user_id = OLD.user_id;
    ELSIF OLD.status = 'claimed' THEN
      UPDATE public.agent_balances
      SET lifetime_claimed = lifetime_claimed - OLD.agent_share,
          updated_at = NOW()
      WHERE user_id = OLD.user_id;
    END IF;
    RETURN OLD;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_agent_balance_on_transaction_change"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."update_agent_balance_on_transaction_change"() IS 'Automatically updates agent_balances when agent_transactions are created, updated, or deleted';



CREATE OR REPLACE FUNCTION "public"."update_agent_commission_config_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_agent_commission_config_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_agent_commission_overrides_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_agent_commission_overrides_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_contact_submissions_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_contact_submissions_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_device_and_sim_status"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  new_status text;
BEGIN
  -- Determine status based on heartbeat
  new_status := get_device_status_from_heartbeat(NEW.last_heartbeat);

  -- Only update if status changed
  IF new_status IS DISTINCT FROM OLD.status THEN
    UPDATE public.devices
    SET status = new_status,
        updated_at = now()
    WHERE device_id = NEW.device_id;

    UPDATE public.sims
    SET status = new_status,
        updated_at = now()
    WHERE device_id = NEW.device_id;

    RAISE NOTICE 'Device % -> % and linked SIMs updated to %', NEW.device_id, OLD.status, new_status;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_device_and_sim_status"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_device_name_in_sims"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  IF NEW.device_id IS NOT NULL THEN
    SELECT name INTO NEW.device_name
    FROM public.devices
    WHERE device_id = NEW.device_id;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_device_name_in_sims"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_gcash_notif_after_topup_match"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    -- Only process if topup was auto-approved and has a matched notification
    IF NEW.status = 'approved' AND NEW.matched_notification_id IS NOT NULL THEN
        -- Mark gcash_notif as matched (now that the topup row exists)
        UPDATE public.gcash_notif
        SET status = 'MATCHED',
            matched_topup_id = NEW.id
        WHERE id = NEW.matched_notification_id
            AND status = 'RECEIVED'
            AND matched_topup_id IS NULL;
    END IF;
    
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_gcash_notif_after_topup_match"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."update_gcash_notif_after_topup_match"() IS 'Updates gcash_notif after wallet_topups row is committed to avoid foreign key constraint violations';



CREATE OR REPLACE FUNCTION "public"."update_last_activity"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.last_activity_at = NOW();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_last_activity"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_last_login"("user_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  UPDATE users 
  SET 
    last_login_at = NOW(),
    login_count = login_count + 1
  WHERE id = user_id;
END;
$$;


ALTER FUNCTION "public"."update_last_login"("user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_messages_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_messages_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_milestone_progress"("p_referrer_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_total_completed_otps INTEGER;
    v_milestone_record RECORD;
    v_milestone_config JSONB;
    v_milestone_item JSONB;
    v_required_otps INTEGER;
    v_bonus DECIMAL;
BEGIN
    -- Count total completed OTPs from all referrals
    SELECT COUNT(DISTINCT otp_session_id) INTO v_total_completed_otps
    FROM public.referral_earnings
    WHERE referrer_id = p_referrer_id;
    
    -- Get milestone config
    SELECT milestone_settings INTO v_milestone_config
    FROM public.referral_config
    WHERE is_active = true
    ORDER BY created_at DESC
    LIMIT 1;
    
    -- If no config, exit
    IF v_milestone_config IS NULL THEN
        RETURN;
    END IF;
    
    -- Process each milestone
    FOR v_milestone_item IN SELECT * FROM jsonb_array_elements(v_milestone_config)
    LOOP
        -- Handle both old format (required_otps, bonus) and new format (referrals_required, bonus_amount)
        v_required_otps := COALESCE(
            (v_milestone_item->>'required_otps')::INTEGER,
            (v_milestone_item->>'referrals_required')::INTEGER,
            0
        );
        v_bonus := COALESCE(
            (v_milestone_item->>'bonus')::DECIMAL,
            (v_milestone_item->>'bonus_amount')::DECIMAL,
            0
        );
        
        INSERT INTO public.referral_milestones (
            referrer_id,
            milestone_level,
            required_completed_otps,
            bonus_amount,
            progress,
            status
        )
        VALUES (
            p_referrer_id,
            (v_milestone_item->>'level')::INTEGER,
            v_required_otps,
            v_bonus,
            v_total_completed_otps,
            CASE
                WHEN v_total_completed_otps >= v_required_otps THEN 'completed'
                WHEN v_total_completed_otps > 0 THEN 'in_progress'
                ELSE 'locked'
            END
        )
        ON CONFLICT (referrer_id, milestone_level) 
        DO UPDATE SET
            required_completed_otps = v_required_otps,  -- Update required_otps when config changes
            bonus_amount = v_bonus,  -- Update bonus when config changes
            progress = v_total_completed_otps,
            -- CRITICAL FIX: Preserve 'claimed' status - never change it once claimed
            status = CASE
                -- If already claimed, preserve it forever
                WHEN referral_milestones.status = 'claimed' THEN 'claimed'
                -- Otherwise, update based on progress
                WHEN v_total_completed_otps >= v_required_otps THEN 'completed'
                WHEN v_total_completed_otps > 0 THEN 'in_progress'
                ELSE 'locked'
            END,
            completed_at = CASE
                WHEN v_total_completed_otps >= v_required_otps 
                    AND referral_milestones.completed_at IS NULL THEN NOW()
                ELSE referral_milestones.completed_at
            END,
            -- claimed_at is preserved automatically (not updated here)
            updated_at = NOW();
    END LOOP;
END;
$$;


ALTER FUNCTION "public"."update_milestone_progress"("p_referrer_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."update_milestone_progress"("p_referrer_id" "uuid") IS 'Updates milestone progress for a referrer. Preserves claimed status - once a milestone is claimed, it will never be changed back to completed/in_progress/locked.';



CREATE OR REPLACE FUNCTION "public"."update_milestones_on_config_change"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_milestone_item JSONB;
    v_required_otps INTEGER;
    v_bonus DECIMAL;
BEGIN
    -- Process if this is an active config
    -- For INSERT: always process if is_active = true
    -- For UPDATE: process if milestone_settings changed or is_active changed to true
    IF NEW.is_active = true THEN
        IF TG_OP = 'INSERT' OR 
           (TG_OP = 'UPDATE' AND (
               OLD.milestone_settings IS DISTINCT FROM NEW.milestone_settings OR 
               (OLD.is_active IS DISTINCT FROM NEW.is_active AND NEW.is_active = true)
           )) THEN
        -- Process each milestone in the config
        FOR v_milestone_item IN SELECT * FROM jsonb_array_elements(NEW.milestone_settings)
        LOOP
            -- Use required_otps and bonus (primary fields), fallback to old format for backward compatibility
            v_required_otps := COALESCE(
                (v_milestone_item->>'required_otps')::INTEGER,
                (v_milestone_item->>'referrals_required')::INTEGER,
                0
            );
            
            v_bonus := COALESCE(
                (v_milestone_item->>'bonus')::DECIMAL,
                (v_milestone_item->>'bonus_amount')::DECIMAL,
                0
            );
            
            -- Update all existing milestone records for this level with new values
            UPDATE public.referral_milestones
            SET 
                required_completed_otps = v_required_otps,
                bonus_amount = v_bonus,
                updated_at = NOW()
            WHERE milestone_level = (v_milestone_item->>'level')::INTEGER
                AND status != 'claimed';  -- Don't update claimed milestones
            
            -- Recalculate status for milestones that might have changed requirements
            UPDATE public.referral_milestones
            SET 
                status = CASE
                    WHEN progress >= v_required_otps AND status != 'claimed' THEN 'completed'
                    WHEN progress > 0 THEN 'in_progress'
                    ELSE 'locked'
                END,
                completed_at = CASE
                    WHEN progress >= v_required_otps 
                        AND completed_at IS NULL 
                        AND status != 'claimed' 
                    THEN NOW()
                    ELSE completed_at
                END,
                updated_at = NOW()
            WHERE milestone_level = (v_milestone_item->>'level')::INTEGER
                AND status != 'claimed';
        END LOOP;
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_milestones_on_config_change"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."update_milestones_on_config_change"() IS 'Automatically updates all referral_milestones records when referral_config milestone_settings change. Handles both old format (required_otps, bonus) and new format (referrals_required, bonus_amount). Recalculates milestone status based on new requirements.';



CREATE OR REPLACE FUNCTION "public"."update_rate_limit_config_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_rate_limit_config_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_rate_limit_tracking_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_rate_limit_tracking_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_referral_config_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_referral_config_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_referral_milestones_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_referral_milestones_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_review_replies_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_review_replies_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_reviews_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_reviews_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_updated_at_column"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_updated_at_column"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_user_referral"("p_referred_user_id" "uuid", "p_referrer_id" "uuid", "p_assigned_by" "uuid", "p_reason" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_previous_referrer_id UUID;
    v_result JSONB;
BEGIN
    -- Get current referrer
    SELECT referred_by INTO v_previous_referrer_id
    FROM public.users
    WHERE id = p_referred_user_id;

    -- Prevent self-referral
    IF p_referred_user_id = p_referrer_id THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Cannot assign user as their own referrer'
        );
    END IF;

    -- Prevent circular referral (referrer cannot be referred by the user being assigned)
    IF EXISTS (
        SELECT 1 FROM public.users
        WHERE id = p_referrer_id
        AND referred_by = p_referred_user_id
    ) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Circular referral detected: referrer is already referred by this user'
        );
    END IF;

    -- Update user's referred_by
    UPDATE public.users
    SET referred_by = p_referrer_id
    WHERE id = p_referred_user_id;

    -- Log the manual assignment
    INSERT INTO public.manual_referral_assignments (
        referred_user_id,
        referrer_id,
        assigned_by,
        previous_referrer_id,
        reason
    ) VALUES (
        p_referred_user_id,
        p_referrer_id,
        p_assigned_by,
        v_previous_referrer_id,
        p_reason
    );

    RETURN jsonb_build_object(
        'success', true,
        'referred_user_id', p_referred_user_id,
        'referrer_id', p_referrer_id,
        'previous_referrer_id', v_previous_referrer_id
    );
END;
$$;


ALTER FUNCTION "public"."update_user_referral"("p_referred_user_id" "uuid", "p_referrer_id" "uuid", "p_assigned_by" "uuid", "p_reason" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."update_user_referral"("p_referred_user_id" "uuid", "p_referrer_id" "uuid", "p_assigned_by" "uuid", "p_reason" "text") IS 'Safely updates a user referral relationship and logs the change for audit';



CREATE OR REPLACE FUNCTION "public"."update_user_settings_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_user_settings_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_users_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_users_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_wallet_topups_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_wallet_topups_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_withdrawal_payment_methods_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_withdrawal_payment_methods_updated_at"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."account_deletion_tokens" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "token" character varying(255) NOT NULL,
    "expires_at" timestamp with time zone NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "used_at" timestamp with time zone
);


ALTER TABLE "public"."account_deletion_tokens" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."agent_applications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "email" "text" NOT NULL,
    "phone" "text" NOT NULL,
    "sim_count" "text",
    "experience" "text",
    "message" "text",
    "agreed_to_terms" boolean DEFAULT false NOT NULL,
    "agreed_to_privacy" boolean DEFAULT false NOT NULL,
    "agreed_to_agent_terms" boolean DEFAULT false NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "admin_notes" "text",
    "reviewed_at" timestamp with time zone,
    "reviewed_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "agent_applications_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'reviewed'::"text", 'approved'::"text", 'rejected'::"text", 'contacted'::"text"])))
);


ALTER TABLE "public"."agent_applications" OWNER TO "postgres";


COMMENT ON TABLE "public"."agent_applications" IS 'Stores agent application form submissions from the become-agent page';



COMMENT ON COLUMN "public"."agent_applications"."agreed_to_terms" IS 'User agreed to general Terms of Service';



COMMENT ON COLUMN "public"."agent_applications"."agreed_to_privacy" IS 'User agreed to Privacy Policy';



COMMENT ON COLUMN "public"."agent_applications"."agreed_to_agent_terms" IS 'User agreed to Agent Terms and Conditions';



COMMENT ON COLUMN "public"."agent_applications"."status" IS 'Application status: pending, reviewed, approved, rejected, or contacted';



CREATE TABLE IF NOT EXISTS "public"."agent_balances" (
    "user_id" "uuid" NOT NULL,
    "pending_balance" numeric(12,2) DEFAULT 0 NOT NULL,
    "available_balance" numeric(12,2) DEFAULT 0 NOT NULL,
    "lifetime_claimed" numeric(12,2) DEFAULT 0 NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."agent_balances" OWNER TO "postgres";


COMMENT ON TABLE "public"."agent_balances" IS 'Cached balances for agents (per user)';



COMMENT ON COLUMN "public"."agent_balances"."pending_balance" IS 'Earnings in 24h cooldown';



COMMENT ON COLUMN "public"."agent_balances"."available_balance" IS 'Earnings available to claim';



COMMENT ON COLUMN "public"."agent_balances"."lifetime_claimed" IS 'Total claimed over the agent lifespan';



CREATE TABLE IF NOT EXISTS "public"."agent_claims" (
    "id" bigint NOT NULL,
    "user_id" "uuid" NOT NULL,
    "amount" numeric(12,2) NOT NULL,
    "status" character varying(16) DEFAULT 'pending'::character varying NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "claimed_at" timestamp with time zone,
    "note" "text",
    CONSTRAINT "agent_claims_status_check" CHECK ((("status")::"text" = ANY ((ARRAY['pending'::character varying, 'processing'::character varying, 'paid'::character varying, 'failed'::character varying])::"text"[])))
);


ALTER TABLE "public"."agent_claims" OWNER TO "postgres";


COMMENT ON TABLE "public"."agent_claims" IS 'History of agent payout claims';



COMMENT ON COLUMN "public"."agent_claims"."amount" IS 'Amount withdrawn from available balance';



CREATE SEQUENCE IF NOT EXISTS "public"."agent_claims_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."agent_claims_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."agent_claims_id_seq" OWNED BY "public"."agent_claims"."id";



CREATE TABLE IF NOT EXISTS "public"."agent_commission_config" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "default_commission_percentage" numeric(5,2) DEFAULT 60.00 NOT NULL,
    "description" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "updated_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "is_agent_direct" boolean DEFAULT false NOT NULL,
    CONSTRAINT "agent_commission_config_default_commission_percentage_check" CHECK ((("default_commission_percentage" >= (0)::numeric) AND ("default_commission_percentage" <= (100)::numeric)))
);


ALTER TABLE "public"."agent_commission_config" OWNER TO "postgres";


COMMENT ON TABLE "public"."agent_commission_config" IS 'Global default commission rate configuration for all agents';



COMMENT ON COLUMN "public"."agent_commission_config"."default_commission_percentage" IS 'Default commission percentage (0-100). Agent gets this percentage, site gets the remainder.';



COMMENT ON COLUMN "public"."agent_commission_config"."is_active" IS 'Only one config should be active at a time';



CREATE TABLE IF NOT EXISTS "public"."agent_commission_overrides" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "commission_percentage" numeric(5,2) NOT NULL,
    "reason" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "set_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "expires_at" timestamp with time zone,
    CONSTRAINT "agent_commission_overrides_commission_percentage_check" CHECK ((("commission_percentage" >= (0)::numeric) AND ("commission_percentage" <= (100)::numeric)))
);


ALTER TABLE "public"."agent_commission_overrides" OWNER TO "postgres";


COMMENT ON TABLE "public"."agent_commission_overrides" IS 'Per-agent commission rate overrides. Allows custom rates for specific agents.';



COMMENT ON COLUMN "public"."agent_commission_overrides"."commission_percentage" IS 'Custom commission percentage (0-100) for this specific agent';



COMMENT ON COLUMN "public"."agent_commission_overrides"."reason" IS 'Reason for setting this custom rate (e.g., "High performer bonus", "Promotional rate")';



COMMENT ON COLUMN "public"."agent_commission_overrides"."expires_at" IS 'Optional expiration date. If set, override becomes inactive after this date';



CREATE TABLE IF NOT EXISTS "public"."agent_invite_earnings" (
    "id" bigint NOT NULL,
    "inviter_id" "uuid" NOT NULL,
    "invited_agent_id" "uuid" NOT NULL,
    "agent_transaction_id" bigint NOT NULL,
    "amount" numeric(10,2) NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "claimed_at" timestamp with time zone,
    CONSTRAINT "agent_invite_earnings_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'claimed'::"text"])))
);


ALTER TABLE "public"."agent_invite_earnings" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."agent_invite_earnings_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."agent_invite_earnings_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."agent_invite_earnings_id_seq" OWNED BY "public"."agent_invite_earnings"."id";



CREATE TABLE IF NOT EXISTS "public"."agent_transactions" (
    "id" bigint NOT NULL,
    "user_id" "uuid" NOT NULL,
    "sim_app_usage_id" "uuid",
    "sim_number" "text",
    "app_name" "text",
    "gross_amount" numeric(12,2) NOT NULL,
    "agent_share" numeric(12,2) NOT NULL,
    "site_share" numeric(12,2) NOT NULL,
    "status" character varying(16) DEFAULT 'pending'::character varying NOT NULL,
    "available_at" timestamp with time zone DEFAULT ("now"() + '24:00:00'::interval) NOT NULL,
    "claimed_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "agent_direct" boolean DEFAULT false NOT NULL,
    CONSTRAINT "agent_transactions_split_check" CHECK ((("agent_share" + "site_share") = "gross_amount")),
    CONSTRAINT "agent_transactions_status_check" CHECK ((("status")::"text" = ANY ((ARRAY['pending'::character varying, 'available'::character varying, 'claimed'::character varying, 'cancelled'::character varying])::"text"[])))
);


ALTER TABLE "public"."agent_transactions" OWNER TO "postgres";


COMMENT ON TABLE "public"."agent_transactions" IS 'Ledger of earnings per SIM app usage with 24h cooldown';



COMMENT ON COLUMN "public"."agent_transactions"."available_at" IS 'When this earning moves from pending to available (24h after creation)';



CREATE SEQUENCE IF NOT EXISTS "public"."agent_transactions_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."agent_transactions_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."agent_transactions_id_seq" OWNED BY "public"."agent_transactions"."id";



CREATE TABLE IF NOT EXISTS "public"."announcement" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "type" "text" NOT NULL,
    "title" "text" NOT NULL,
    "message" "text" NOT NULL,
    "target_email" "text",
    "target_device_id" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "priority" integer DEFAULT 0 NOT NULL,
    "show_in_banner" boolean DEFAULT true NOT NULL,
    "show_in_notification" boolean DEFAULT true NOT NULL,
    "action_url" "text",
    "action_text" "text",
    "starts_at" timestamp with time zone,
    "expires_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "announcement_type_check" CHECK (("type" = ANY (ARRAY['announcement'::"text", 'warning'::"text", 'error'::"text"])))
);


ALTER TABLE "public"."announcement" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."chat_bot_states" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "provider" "text" NOT NULL,
    "chat_id" "text" NOT NULL,
    "state" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."chat_bot_states" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."chat_link_codes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "provider" "text" NOT NULL,
    "code" "text" NOT NULL,
    "expires_at" timestamp with time zone NOT NULL,
    "used_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."chat_link_codes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."christmas_2025_uptime_ranking_snapshot" (
    "rank" bigint NOT NULL,
    "user_id" "uuid" NOT NULL,
    "email" "text",
    "top_device_id" "text",
    "top_device_name" "text",
    "top_uptime_seconds" bigint,
    "completed_sessions" bigint,
    "expired_sessions" bigint,
    "reliability_pct" numeric,
    "cancelled_transactions" bigint,
    "total_profit" numeric,
    "is_eligible" boolean,
    "snapshot_taken_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."christmas_2025_uptime_ranking_snapshot" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."contact_submissions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "first_name" character varying(100) NOT NULL,
    "last_name" character varying(100) NOT NULL,
    "email" character varying(255) NOT NULL,
    "phone" character varying(20),
    "subject" character varying(100) NOT NULL,
    "priority" character varying(20) NOT NULL,
    "message" "text" NOT NULL,
    "attachments" "jsonb" DEFAULT '[]'::"jsonb",
    "status" character varying(20) DEFAULT 'pending'::character varying,
    "admin_notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "contact_submissions_priority_check" CHECK ((("priority")::"text" = ANY ((ARRAY['low'::character varying, 'medium'::character varying, 'high'::character varying, 'critical'::character varying])::"text"[]))),
    CONSTRAINT "contact_submissions_status_check" CHECK ((("status")::"text" = ANY ((ARRAY['pending'::character varying, 'in_progress'::character varying, 'resolved'::character varying, 'closed'::character varying])::"text"[])))
);


ALTER TABLE "public"."contact_submissions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."daily_analytics_snapshots" (
    "id" bigint NOT NULL,
    "snapshot_date" "date" NOT NULL,
    "captured_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "total_wallet_balance" numeric DEFAULT 0 NOT NULL,
    "total_liabilities" numeric DEFAULT 0 NOT NULL,
    "total_agent_pending_balance" numeric DEFAULT 0 NOT NULL,
    "total_agent_available_balance" numeric DEFAULT 0 NOT NULL,
    "total_agent_current_balance" numeric DEFAULT 0 NOT NULL,
    "total_site_share" numeric DEFAULT 0 NOT NULL,
    "total_site_loss_claimed" numeric DEFAULT 0 NOT NULL,
    "net_platform_profit" numeric DEFAULT 0 NOT NULL,
    "profit_earned_for_day" numeric DEFAULT 0 NOT NULL,
    "overall_wallet" numeric DEFAULT 0,
    "total_combined_liabilities" numeric GENERATED ALWAYS AS ((("total_wallet_balance" + "total_liabilities") + "total_agent_current_balance")) STORED,
    "net_balance" numeric GENERATED ALWAYS AS (("overall_wallet" - (("total_wallet_balance" + "total_liabilities") + "total_agent_current_balance"))) STORED
);


ALTER TABLE "public"."daily_analytics_snapshots" OWNER TO "postgres";


ALTER TABLE "public"."daily_analytics_snapshots" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."daily_analytics_snapshots_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."devices" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "device_id" "text" NOT NULL,
    "name" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "last_seen" timestamp with time zone DEFAULT "now"(),
    "status" "text" DEFAULT 'offline'::"text",
    "last_heartbeat" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "user_id" "uuid",
    "uptime_seconds" bigint DEFAULT 0 NOT NULL,
    "last_status_change" timestamp with time zone
);


ALTER TABLE "public"."devices" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."device_status" AS
 SELECT "device_id",
    "name",
    "last_seen",
    "created_at",
        CASE
            WHEN (("now"() - "last_seen") < '00:05:00'::interval) THEN '🟢 Active'::"text"
            WHEN (("now"() - "last_seen") < '00:30:00'::interval) THEN '🟡 Idle'::"text"
            ELSE '🔴 Offline'::"text"
        END AS "status"
   FROM "public"."devices";


ALTER VIEW "public"."device_status" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."feedback" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "type" "text" NOT NULL,
    "title" "text" NOT NULL,
    "description" "text" NOT NULL,
    "email" "text",
    "status" "text" DEFAULT 'open'::"text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "user_agent" "text",
    "ip_address" "text",
    CONSTRAINT "feedback_status_check" CHECK (("status" = ANY (ARRAY['open'::"text", 'in_progress'::"text", 'resolved'::"text", 'wont_fix'::"text", 'duplicate'::"text"])))
);


ALTER TABLE "public"."feedback" OWNER TO "postgres";


COMMENT ON TABLE "public"."feedback" IS 'Stores user feedback and feature requests';



COMMENT ON COLUMN "public"."feedback"."status" IS 'Current status of the feedback: open, in_progress, resolved, wont_fix, duplicate';



CREATE TABLE IF NOT EXISTS "public"."gcash_notif" (
    "id" bigint NOT NULL,
    "source" "text" DEFAULT 'gcash'::"text",
    "amount" numeric(12,2) NOT NULL,
    "sender_masked" "text",
    "sender_number" "text",
    "occurred_at" timestamp with time zone NOT NULL,
    "raw" "text",
    "status" "text" DEFAULT 'RECEIVED'::"text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "matched_payment_id" "uuid",
    "match_window_minutes" integer DEFAULT 10,
    "occurred_at_gmt8" timestamp without time zone GENERATED ALWAYS AS (("occurred_at" AT TIME ZONE 'Asia/Manila'::"text")) STORED,
    "created_at_gmt8" timestamp without time zone GENERATED ALWAYS AS (("created_at" AT TIME ZONE 'Asia/Manila'::"text")) STORED,
    "matched_topup_id" "uuid"
);


ALTER TABLE "public"."gcash_notif" OWNER TO "postgres";


COMMENT ON COLUMN "public"."gcash_notif"."occurred_at_gmt8" IS 'GMT+8 (Asia/Manila) timezone version of occurred_at';



COMMENT ON COLUMN "public"."gcash_notif"."created_at_gmt8" IS 'GMT+8 (Asia/Manila) timezone version of created_at';



ALTER TABLE "public"."gcash_notif" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."gcash_notif_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."incoming_webhook_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "payload" "jsonb" NOT NULL,
    "headers" "jsonb",
    "query_params" "jsonb",
    "ip" "text",
    "user_agent" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."incoming_webhook_events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."manual_payments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "payment_method_id" "uuid",
    "amount" numeric(10,2) NOT NULL,
    "receipt_url" "text",
    "status" "text" DEFAULT 'pending'::"text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "approved_at" timestamp with time zone,
    "approved_by" "uuid",
    "voucher_id" "uuid",
    "app_name" "text",
    "voucher_code" "text",
    "ocr_reference" "text",
    "ocr_amount" numeric(10,2),
    "sender_number" "text",
    "created_at_gmt8" timestamp without time zone GENERATED ALWAYS AS (("created_at" AT TIME ZONE 'Asia/Manila'::"text")) STORED,
    "approved_at_gmt8" timestamp without time zone GENERATED ALWAYS AS (
CASE
    WHEN ("approved_at" IS NOT NULL) THEN ("approved_at" AT TIME ZONE 'Asia/Manila'::"text")
    ELSE NULL::timestamp without time zone
END) STORED,
    "user_email" "text",
    "quantity" integer DEFAULT 1 NOT NULL,
    "unit_price" numeric(10,2),
    "otp_session_id" "uuid",
    "agent_user_id" "uuid",
    "agent_direct" boolean DEFAULT false NOT NULL,
    CONSTRAINT "manual_payments_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'rejected'::"text"])))
);


ALTER TABLE "public"."manual_payments" OWNER TO "postgres";


COMMENT ON COLUMN "public"."manual_payments"."created_at_gmt8" IS 'GMT+8 (Asia/Manila) timezone version of created_at';



COMMENT ON COLUMN "public"."manual_payments"."approved_at_gmt8" IS 'GMT+8 (Asia/Manila) timezone version of approved_at';



COMMENT ON COLUMN "public"."manual_payments"."user_email" IS 'User email from users table, automatically synced via trigger';



COMMENT ON COLUMN "public"."manual_payments"."otp_session_id" IS 'Linked OTP session for this payment (agent-direct escrow/session purchase).';



COMMENT ON COLUMN "public"."manual_payments"."agent_user_id" IS 'Agent that this payment is associated with.';



COMMENT ON COLUMN "public"."manual_payments"."agent_direct" IS 'TRUE when payment is for an agent-direct OTP session.';



CREATE TABLE IF NOT EXISTS "public"."manual_referral_assignments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "referred_user_id" "uuid" NOT NULL,
    "referrer_id" "uuid" NOT NULL,
    "assigned_by" "uuid" NOT NULL,
    "previous_referrer_id" "uuid",
    "reason" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."manual_referral_assignments" OWNER TO "postgres";


COMMENT ON TABLE "public"."manual_referral_assignments" IS 'Audit trail for manual referral assignments by admins';



COMMENT ON COLUMN "public"."manual_referral_assignments"."previous_referrer_id" IS 'Previous referrer (if any) before manual assignment';



COMMENT ON COLUMN "public"."manual_referral_assignments"."reason" IS 'Reason or notes for the manual assignment';



CREATE TABLE IF NOT EXISTS "public"."notification_outbox" (
    "id" bigint NOT NULL,
    "event_type" "text" NOT NULL,
    "record_id" "uuid" NOT NULL,
    "user_id" "uuid",
    "payload" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "processed_at" timestamp with time zone,
    "attempts" integer DEFAULT 0 NOT NULL,
    "last_error" "text"
);


ALTER TABLE "public"."notification_outbox" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."notification_outbox_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."notification_outbox_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."notification_outbox_id_seq" OWNED BY "public"."notification_outbox"."id";



CREATE TABLE IF NOT EXISTS "public"."otp_pricing" (
    "id" bigint NOT NULL,
    "app_name" "text" NOT NULL,
    "display_name" "text",
    "price" numeric(10,2) DEFAULT 5.00 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "max_quantity" integer,
    "max_otp_messages" integer DEFAULT 3 NOT NULL,
    "allowed_carriers" "text"[],
    "discount_percentage" numeric(5,2) DEFAULT NULL::numeric,
    "only_otp" boolean DEFAULT true NOT NULL,
    "sender_restrictions" "text"[],
    CONSTRAINT "otp_pricing_discount_percentage_check" CHECK ((("discount_percentage" IS NULL) OR (("discount_percentage" >= (0)::numeric) AND ("discount_percentage" <= (100)::numeric))))
);


ALTER TABLE "public"."otp_pricing" OWNER TO "postgres";


COMMENT ON COLUMN "public"."otp_pricing"."max_quantity" IS 'Maximum allowed quantity for this app. NULL means no limit (uses available_sims).';



COMMENT ON COLUMN "public"."otp_pricing"."max_otp_messages" IS 'Maximum number of OTP SMS messages that can be linked to a session for this app (default: 3)';



COMMENT ON COLUMN "public"."otp_pricing"."allowed_carriers" IS 'Array of allowed carrier names (e.g., ["Globe", "TM"]). NULL means no restriction (all carriers allowed).';



COMMENT ON COLUMN "public"."otp_pricing"."discount_percentage" IS 'Discount percentage (0-100). NULL means no discount. When set, the discounted price is calculated as: price * (1 - discount_percentage / 100)';



COMMENT ON COLUMN "public"."otp_pricing"."only_otp" IS 'If true, only SMS messages that look like OTP will be linked to sessions for this app';



COMMENT ON COLUMN "public"."otp_pricing"."sender_restrictions" IS 'Optional list of sender keywords allowed for this app (case-insensitive contains match)';



CREATE SEQUENCE IF NOT EXISTS "public"."otp_pricing_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."otp_pricing_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."otp_pricing_id_seq" OWNED BY "public"."otp_pricing"."id";



CREATE TABLE IF NOT EXISTS "public"."otp_session_extensions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "session_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "minutes_added" integer DEFAULT 5 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."otp_session_extensions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."otp_session_queue" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "payment_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "app_name" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "processed" boolean DEFAULT false,
    "processed_at" timestamp with time zone
);


ALTER TABLE "public"."otp_session_queue" OWNER TO "postgres";


COMMENT ON TABLE "public"."otp_session_queue" IS 'Queue for OTP session creation when payments are auto-approved';



CREATE TABLE IF NOT EXISTS "public"."otp_sessions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "app_name" "text" NOT NULL,
    "sim_number" "text",
    "status" "text" DEFAULT 'pending'::"text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "expires_at" timestamp with time zone DEFAULT ("now"() + '00:10:00'::interval),
    "sms_message_id" bigint,
    "otp_message" "text",
    "otp_sender" "text",
    "status_updated_at" timestamp with time zone DEFAULT "now"(),
    "timeout_duration" integer DEFAULT 600,
    "last_activity_at" timestamp with time zone DEFAULT "now"(),
    "activated_at" timestamp with time zone,
    "retry_count" integer DEFAULT 0,
    "retry_limit" integer DEFAULT 3,
    "previous_sim_number" "text",
    "last_retry_at" timestamp with time zone,
    "is_demo" boolean DEFAULT false,
    "demo_token" "text",
    "demo_expires_at" timestamp with time zone,
    "created_at_gmt8" timestamp without time zone GENERATED ALWAYS AS (("created_at" AT TIME ZONE 'Asia/Manila'::"text")) STORED,
    "expires_at_gmt8" timestamp without time zone GENERATED ALWAYS AS (
CASE
    WHEN ("expires_at" IS NOT NULL) THEN ("expires_at" AT TIME ZONE 'Asia/Manila'::"text")
    ELSE NULL::timestamp without time zone
END) STORED,
    "status_updated_at_gmt8" timestamp without time zone GENERATED ALWAYS AS (("status_updated_at" AT TIME ZONE 'Asia/Manila'::"text")) STORED,
    "last_activity_at_gmt8" timestamp without time zone GENERATED ALWAYS AS (("last_activity_at" AT TIME ZONE 'Asia/Manila'::"text")) STORED,
    "activated_at_gmt8" timestamp without time zone GENERATED ALWAYS AS (
CASE
    WHEN ("activated_at" IS NOT NULL) THEN ("activated_at" AT TIME ZONE 'Asia/Manila'::"text")
    ELSE NULL::timestamp without time zone
END) STORED,
    "last_retry_at_gmt8" timestamp without time zone GENERATED ALWAYS AS (
CASE
    WHEN ("last_retry_at" IS NOT NULL) THEN ("last_retry_at" AT TIME ZONE 'Asia/Manila'::"text")
    ELSE NULL::timestamp without time zone
END) STORED,
    "demo_expires_at_gmt8" timestamp without time zone GENERATED ALWAYS AS (
CASE
    WHEN ("demo_expires_at" IS NOT NULL) THEN ("demo_expires_at" AT TIME ZONE 'Asia/Manila'::"text")
    ELSE NULL::timestamp without time zone
END) STORED,
    "user_email" "text",
    "locked_sim" boolean DEFAULT false NOT NULL,
    "message_count" integer DEFAULT 0 NOT NULL,
    "original_app" "text",
    "commission_processed" boolean DEFAULT false NOT NULL,
    "agent_direct" boolean DEFAULT false NOT NULL,
    "agent_user_id" "uuid",
    "agent_sim_id" bigint,
    "agent_price" numeric(12,2),
    "site_base_price" numeric(12,2),
    "guest_email" "text",
    "public_token" "text",
    "price_paid" numeric(12,2),
    "paid_with_voucher" boolean DEFAULT false NOT NULL,
    "extended_count" integer DEFAULT 0 NOT NULL,
    "last_extended_at" timestamp with time zone,
    "direct_public" boolean DEFAULT false NOT NULL,
    "activated_via" "text",
    CONSTRAINT "otp_sessions_extended_count_max_2" CHECK ((("extended_count" >= 0) AND ("extended_count" <= 2)))
);


ALTER TABLE "public"."otp_sessions" OWNER TO "postgres";


COMMENT ON COLUMN "public"."otp_sessions"."is_demo" IS 'Indicates if this is a demo/public session that can be accessed without authentication';



COMMENT ON COLUMN "public"."otp_sessions"."demo_token" IS 'Unique token for accessing demo session via public URL';



COMMENT ON COLUMN "public"."otp_sessions"."demo_expires_at" IS 'Optional expiration date for the demo link (before activation)';



COMMENT ON COLUMN "public"."otp_sessions"."created_at_gmt8" IS 'GMT+8 (Asia/Manila) timezone version of created_at';



COMMENT ON COLUMN "public"."otp_sessions"."expires_at_gmt8" IS 'GMT+8 (Asia/Manila) timezone version of expires_at';



COMMENT ON COLUMN "public"."otp_sessions"."status_updated_at_gmt8" IS 'GMT+8 (Asia/Manila) timezone version of status_updated_at';



COMMENT ON COLUMN "public"."otp_sessions"."last_activity_at_gmt8" IS 'GMT+8 (Asia/Manila) timezone version of last_activity_at';



COMMENT ON COLUMN "public"."otp_sessions"."activated_at_gmt8" IS 'GMT+8 (Asia/Manila) timezone version of activated_at';



COMMENT ON COLUMN "public"."otp_sessions"."last_retry_at_gmt8" IS 'GMT+8 (Asia/Manila) timezone version of last_retry_at';



COMMENT ON COLUMN "public"."otp_sessions"."demo_expires_at_gmt8" IS 'GMT+8 (Asia/Manila) timezone version of demo_expires_at';



COMMENT ON COLUMN "public"."otp_sessions"."user_email" IS 'User email from users table, automatically synced via trigger. Preserved even when user_id is NULL for historical/audit purposes.';



COMMENT ON COLUMN "public"."otp_sessions"."locked_sim" IS 'If TRUE, SIM is locked to this session during its lifetime.';



COMMENT ON COLUMN "public"."otp_sessions"."original_app" IS 'Original app name when session was first created. Set on first app change if null, then remains unchanged.';



COMMENT ON COLUMN "public"."otp_sessions"."commission_processed" IS 'Flag to track if referral commission has been processed for this OTP session. Prevents duplicate processing.';



COMMENT ON COLUMN "public"."otp_sessions"."agent_direct" IS 'TRUE when session was created directly by an agent (private link / escrow).';



COMMENT ON COLUMN "public"."otp_sessions"."agent_user_id" IS 'Agent (users.id) that owns this session.';



COMMENT ON COLUMN "public"."otp_sessions"."agent_sim_id" IS 'SIM (sims.id) chosen by agent; must belong to an agent device.';



COMMENT ON COLUMN "public"."otp_sessions"."agent_price" IS 'Final price charged to buyer for this session (agent-set).';



COMMENT ON COLUMN "public"."otp_sessions"."site_base_price" IS 'Snapshot of site base price for this app at the time of session creation.';



COMMENT ON COLUMN "public"."otp_sessions"."guest_email" IS 'Buyer email for guest/escrow flow.';



COMMENT ON COLUMN "public"."otp_sessions"."public_token" IS 'Private link token used by buyer to open the session. Short 6-character alphanumeric token.';



COMMENT ON COLUMN "public"."otp_sessions"."price_paid" IS 'Snapshot of the price charged to the user for this OTP session at time of creation/purchase (used for refunds).';



COMMENT ON COLUMN "public"."otp_sessions"."paid_with_voucher" IS 'True when this session was paid using a voucher. Refunds are not allowed for voucher-paid sessions.';



CREATE TABLE IF NOT EXISTS "public"."payment_method_transactions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "payment_method_id" "uuid" NOT NULL,
    "direction" "text" NOT NULL,
    "amount" numeric(10,2) NOT NULL,
    "source_table" "text" NOT NULL,
    "source_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "effective_at" timestamp with time zone,
    CONSTRAINT "payment_method_transactions_amount_check" CHECK (("amount" >= (0)::numeric)),
    CONSTRAINT "payment_method_transactions_direction_check" CHECK (("direction" = ANY (ARRAY['in'::"text", 'out'::"text"])))
);


ALTER TABLE "public"."payment_method_transactions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."payment_methods" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "phone_number" "text",
    "qr_image_url" "text",
    "enabled" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "icon_url" "text",
    "account_name" "text",
    "wallet_balance" numeric(10,2) DEFAULT 0.00 NOT NULL
);


ALTER TABLE "public"."payment_methods" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."rate_limit_config" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "endpoint_path" "text" NOT NULL,
    "limit_per_window" integer DEFAULT 100 NOT NULL,
    "window_seconds" integer DEFAULT 60 NOT NULL,
    "error_message" "text",
    "description" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."rate_limit_config" OWNER TO "postgres";


COMMENT ON TABLE "public"."rate_limit_config" IS 'Dynamic rate limit configuration for API endpoints';



COMMENT ON COLUMN "public"."rate_limit_config"."endpoint_path" IS 'Endpoint path pattern. Use "global" for default, or specific paths like "/api/public/sims"';



COMMENT ON COLUMN "public"."rate_limit_config"."limit_per_window" IS 'Maximum number of requests allowed in the time window';



COMMENT ON COLUMN "public"."rate_limit_config"."window_seconds" IS 'Time window in seconds (e.g., 60 for 1 minute)';



COMMENT ON COLUMN "public"."rate_limit_config"."error_message" IS 'Custom error message when rate limit is exceeded (optional)';



COMMENT ON COLUMN "public"."rate_limit_config"."is_active" IS 'Whether this configuration is currently active';



CREATE TABLE IF NOT EXISTS "public"."rate_limit_tracking" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "identifier" "text" NOT NULL,
    "endpoint_path" "text" NOT NULL,
    "count" integer DEFAULT 1 NOT NULL,
    "reset_time" timestamp with time zone NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."rate_limit_tracking" OWNER TO "postgres";


COMMENT ON TABLE "public"."rate_limit_tracking" IS 'Tracks current rate limit state per identifier and endpoint';



COMMENT ON COLUMN "public"."rate_limit_tracking"."identifier" IS 'Client identifier (usually IP address)';



COMMENT ON COLUMN "public"."rate_limit_tracking"."endpoint_path" IS 'Endpoint path pattern being rate limited';



COMMENT ON COLUMN "public"."rate_limit_tracking"."count" IS 'Current number of requests in this window';



COMMENT ON COLUMN "public"."rate_limit_tracking"."reset_time" IS 'When this rate limit window resets';



CREATE TABLE IF NOT EXISTS "public"."referral_config" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "commission_per_otp" numeric(10,2) DEFAULT 0.20 NOT NULL,
    "milestone_settings" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "agent_invite_commission_per_session" numeric(10,2) DEFAULT 0.15 NOT NULL
);


ALTER TABLE "public"."referral_config" OWNER TO "postgres";


COMMENT ON TABLE "public"."referral_config" IS 'Admin-editable referral system configuration (commission rates and milestones)';



COMMENT ON COLUMN "public"."referral_config"."commission_per_otp" IS 'Commission amount per completed OTP (in PHP)';



CREATE TABLE IF NOT EXISTS "public"."referral_earnings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "referrer_id" "uuid" NOT NULL,
    "referred_user_id" "uuid" NOT NULL,
    "otp_session_id" "uuid" NOT NULL,
    "amount" numeric(10,2) NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "claimed_at" timestamp with time zone,
    CONSTRAINT "referral_earnings_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'claimed'::"text"])))
);


ALTER TABLE "public"."referral_earnings" OWNER TO "postgres";


COMMENT ON TABLE "public"."referral_earnings" IS 'Records per-OTP commission earnings for referrers (one record per completed OTP)';



COMMENT ON COLUMN "public"."referral_earnings"."status" IS 'pending: not yet claimed, claimed: moved to wallet';



CREATE TABLE IF NOT EXISTS "public"."referral_milestones" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "referrer_id" "uuid" NOT NULL,
    "milestone_level" integer NOT NULL,
    "required_completed_otps" integer NOT NULL,
    "bonus_amount" numeric(10,2) NOT NULL,
    "progress" integer DEFAULT 0 NOT NULL,
    "status" "text" DEFAULT 'locked'::"text" NOT NULL,
    "completed_at" timestamp with time zone,
    "claimed_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "referral_milestones_claimed_check" CHECK (((("status" = 'claimed'::"text") AND ("claimed_at" IS NOT NULL)) OR ("status" <> 'claimed'::"text"))),
    CONSTRAINT "referral_milestones_status_check" CHECK (("status" = ANY (ARRAY['locked'::"text", 'in_progress'::"text", 'completed'::"text", 'claimed'::"text"])))
);


ALTER TABLE "public"."referral_milestones" OWNER TO "postgres";


COMMENT ON CONSTRAINT "referral_milestones_claimed_check" ON "public"."referral_milestones" IS 'Ensures that when status is claimed, claimed_at timestamp must be set. Prevents inconsistent data states.';



CREATE TABLE IF NOT EXISTS "public"."review_replies" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "review_id" "uuid" NOT NULL,
    "author_id" "uuid" NOT NULL,
    "author_email" "text" NOT NULL,
    "author_role" "text" NOT NULL,
    "message" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "review_replies_author_role_check" CHECK (("author_role" = ANY (ARRAY['admin'::"text", 'user'::"text"])))
);


ALTER TABLE "public"."review_replies" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."reviews" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "user_email" "text" NOT NULL,
    "rating" integer NOT NULL,
    "comment" "text",
    "otp_session_id" "uuid",
    "is_displayed" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "app_name" "text",
    CONSTRAINT "reviews_rating_check" CHECK ((("rating" >= 1) AND ("rating" <= 5)))
);


ALTER TABLE "public"."reviews" OWNER TO "postgres";


COMMENT ON TABLE "public"."reviews" IS 'User reviews for OTP services with star ratings and admin display control';



COMMENT ON COLUMN "public"."reviews"."user_email" IS 'User email stored for display (will be privacy-protected in frontend)';



COMMENT ON COLUMN "public"."reviews"."rating" IS 'Star rating from 1 to 5';



COMMENT ON COLUMN "public"."reviews"."otp_session_id" IS 'Optional link to the OTP session that triggered this review';



COMMENT ON COLUMN "public"."reviews"."is_displayed" IS 'Admin must set to true for review to appear on main page';



CREATE TABLE IF NOT EXISTS "public"."scheduler_leases" (
    "lease_key" "text" NOT NULL,
    "leased_until" timestamp with time zone NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."scheduler_leases" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sim_app_usage" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "sim_number" "text" NOT NULL,
    "app_name" "text" NOT NULL,
    "used_at" timestamp with time zone DEFAULT "now"(),
    "session_id" "uuid",
    "used_at_gmt8" timestamp without time zone GENERATED ALWAYS AS (("used_at" AT TIME ZONE 'Asia/Manila'::"text")) STORED,
    "note" "text",
    "agent_user_id" "uuid",
    "gross_amount" numeric(12,2),
    "agent_share" numeric(12,2),
    "site_share" numeric(12,2),
    "agent_direct" boolean DEFAULT false NOT NULL
);


ALTER TABLE "public"."sim_app_usage" OWNER TO "postgres";


COMMENT ON COLUMN "public"."sim_app_usage"."used_at_gmt8" IS 'GMT+8 (Asia/Manila) timezone version of used_at';



COMMENT ON COLUMN "public"."sim_app_usage"."agent_user_id" IS 'Owner/agent (users.id) of the SIM that generated this usage';



COMMENT ON COLUMN "public"."sim_app_usage"."gross_amount" IS 'Gross revenue recorded for this SIM usage';



COMMENT ON COLUMN "public"."sim_app_usage"."agent_share" IS '60% agent share for this SIM usage';



COMMENT ON COLUMN "public"."sim_app_usage"."site_share" IS '40% site share for this SIM usage';



CREATE TABLE IF NOT EXISTS "public"."sims" (
    "id" bigint NOT NULL,
    "number" "text" NOT NULL,
    "carrier" "text",
    "slot" integer,
    "type" "text" DEFAULT 'private'::"text",
    "device_id" "text",
    "device_name" "text",
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "status" character varying(20) DEFAULT 'DISABLED'::character varying,
    "excluded_apps" "jsonb" DEFAULT '[]'::"jsonb",
    "note" "text",
    "last_seen" timestamp with time zone,
    "uptime_seconds" bigint DEFAULT 0 NOT NULL,
    "last_status_change" timestamp with time zone,
    "last_heartbeat" timestamp with time zone,
    "total_completed" integer DEFAULT 0 NOT NULL,
    "total_failed" integer DEFAULT 0 NOT NULL,
    "user_email" "text",
    "christmas_2025_failed_baseline" integer DEFAULT 0 NOT NULL,
    "christmas_2025_failed_baseline_set_at" timestamp with time zone,
    "success_rate" numeric GENERATED ALWAYS AS (
CASE
    WHEN ((COALESCE("total_completed", 0) + COALESCE("total_failed", 0)) = 0) THEN (0)::numeric
    ELSE ((COALESCE("total_completed", 0))::numeric / ((COALESCE("total_completed", 0) + COALESCE("total_failed", 0)))::numeric)
END) STORED,
    "paused_at" timestamp with time zone,
    "paused_reason" "text",
    "paused_context" "jsonb"
);


ALTER TABLE "public"."sims" OWNER TO "postgres";


COMMENT ON COLUMN "public"."sims"."status" IS 'SIM status: DISABLED, CONFIGURING, ACTIVE, IN_USE, OFFLINE, PAUSED';



COMMENT ON COLUMN "public"."sims"."excluded_apps" IS 'Array of app names that should not use this SIM';



COMMENT ON COLUMN "public"."sims"."note" IS 'Agent notes about this SIM';



COMMENT ON COLUMN "public"."sims"."last_seen" IS 'Last time this SIM was seen online';



COMMENT ON COLUMN "public"."sims"."total_completed" IS 'Total number of successfully completed sessions for this SIM';



COMMENT ON COLUMN "public"."sims"."total_failed" IS 'Total number of failed sessions for this SIM (expired with no messages, number changes, etc.)';



COMMENT ON COLUMN "public"."sims"."success_rate" IS 'Reliability score from 0..1 computed from total_completed / (total_completed + total_failed).';



CREATE OR REPLACE VIEW "public"."sim_app_earnings" AS
 SELECT "s"."id" AS "sim_id",
    "s"."number" AS "sim_number",
    "count"("u"."id") AS "total_usage",
    ("sum"(COALESCE("u"."gross_amount", ("p"."price" * ((1)::numeric - (COALESCE("p"."discount_percentage", (0)::numeric) / 100.0))), (0)::numeric)))::numeric(18,2) AS "total_earnings",
    "min"("u"."used_at") AS "first_usage_at",
    "max"("u"."used_at") AS "last_usage_at"
   FROM ((("public"."sim_app_usage" "u"
     JOIN "public"."sims" "s" ON (("s"."number" = "u"."sim_number")))
     LEFT JOIN "public"."otp_pricing" "p" ON (("p"."app_name" = "u"."app_name")))
     LEFT JOIN "public"."otp_sessions" "os" ON (("os"."id" = "u"."session_id")))
  WHERE (("os"."status" IS NULL) OR ("os"."status" = 'completed'::"text") OR ("os"."status" = 'COMPLETED'::"text"))
  GROUP BY "s"."id", "s"."number";


ALTER VIEW "public"."sim_app_earnings" OWNER TO "postgres";


COMMENT ON VIEW "public"."sim_app_earnings" IS 'Provides per-SIM earnings and usage stats. Uses gross_amount from sim_app_usage if available, otherwise calculates from otp_pricing.';



CREATE TABLE IF NOT EXISTS "public"."sim_failure_records" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "session_id" "uuid" NOT NULL,
    "sim_id" bigint NOT NULL,
    "failure_type" "text" NOT NULL,
    "recorded_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "sim_number" "text"
);


ALTER TABLE "public"."sim_failure_records" OWNER TO "postgres";


COMMENT ON TABLE "public"."sim_failure_records" IS 'Tracks which sessions have had SIM failures recorded to prevent duplicate counting';



COMMENT ON COLUMN "public"."sim_failure_records"."failure_type" IS 'Type of failure: expired, user_change, admin_change';



CREATE OR REPLACE VIEW "public"."sim_failure_records_view" AS
 SELECT "sfr"."id",
    "sfr"."session_id",
    "sfr"."sim_id",
    "s"."number" AS "sim_number",
    "os"."app_name",
    "os"."user_email",
    "sfr"."failure_type",
    "sfr"."recorded_at"
   FROM (("public"."sim_failure_records" "sfr"
     JOIN "public"."sims" "s" ON (("s"."id" = "sfr"."sim_id")))
     JOIN "public"."otp_sessions" "os" ON (("os"."id" = "sfr"."session_id")));


ALTER VIEW "public"."sim_failure_records_view" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sim_failure_streaks" (
    "sim_id" bigint NOT NULL,
    "failed_apps" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."sim_failure_streaks" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sim_group_members" (
    "group_id" "uuid" NOT NULL,
    "sim_number" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."sim_group_members" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sim_groups" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "color" "text" DEFAULT '#3b82f6'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."sim_groups" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sim_history" (
    "id" bigint NOT NULL,
    "sim_number" "text" NOT NULL,
    "device_id" "text" NOT NULL,
    "carrier" "text",
    "slot" integer,
    "action" "text" DEFAULT 'inserted'::"text",
    "timestamp" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."sim_history" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."sim_history_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."sim_history_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."sim_history_id_seq" OWNED BY "public"."sim_history"."id";



CREATE TABLE IF NOT EXISTS "public"."sim_stats" (
    "sim_id" bigint NOT NULL,
    "uptime_seconds" bigint DEFAULT 0 NOT NULL,
    "total_completed" integer DEFAULT 0 NOT NULL,
    "total_failed" integer DEFAULT 0 NOT NULL,
    "total_earnings" numeric DEFAULT 0 NOT NULL,
    "last_status_change" timestamp with time zone,
    "last_heartbeat" timestamp with time zone,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."sim_stats" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."sims_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."sims_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."sims_id_seq" OWNED BY "public"."sims"."id";



CREATE TABLE IF NOT EXISTS "public"."sms_messages" (
    "id" bigint NOT NULL,
    "sim_number" "text" NOT NULL,
    "sender" "text" NOT NULL,
    "message" "text" NOT NULL,
    "timestamp" timestamp with time zone DEFAULT "now"(),
    "consumed_by_session" "uuid",
    "timestamp_gmt8" timestamp without time zone GENERATED ALWAYS AS (("timestamp" AT TIME ZONE 'Asia/Manila'::"text")) STORED,
    "tmp_id" "uuid" DEFAULT "gen_random_uuid"(),
    "id_uuid" "uuid" DEFAULT "gen_random_uuid"(),
    "sync_status" character varying(20) DEFAULT 'synced'::character varying,
    "retry_count" integer DEFAULT 0,
    "slot" integer
);


ALTER TABLE "public"."sms_messages" OWNER TO "postgres";


COMMENT ON COLUMN "public"."sms_messages"."timestamp_gmt8" IS 'GMT+8 (Asia/Manila) timezone version of timestamp';



COMMENT ON COLUMN "public"."sms_messages"."sync_status" IS 'Sync status: synced, failed, pending';



COMMENT ON COLUMN "public"."sms_messages"."retry_count" IS 'Number of retry attempts for failed syncs';



CREATE SEQUENCE IF NOT EXISTS "public"."sms_messages_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."sms_messages_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."sms_messages_id_seq" OWNED BY "public"."sms_messages"."id";



CREATE TABLE IF NOT EXISTS "public"."system_logs" (
    "id" integer NOT NULL,
    "level" "text" NOT NULL,
    "message" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "source" "text",
    "details" "text",
    "user_id" "text",
    "ip_address" "text"
);


ALTER TABLE "public"."system_logs" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."system_logs_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."system_logs_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."system_logs_id_seq" OWNED BY "public"."system_logs"."id";



CREATE TABLE IF NOT EXISTS "public"."telegram_referral_invite_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "provider" "text" DEFAULT 'telegram'::"text" NOT NULL,
    "referrer_id" "uuid" NOT NULL,
    "referred_user_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "delivered_at" timestamp with time zone
);


ALTER TABLE "public"."telegram_referral_invite_events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."telegram_session_warning_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "provider" "text" DEFAULT 'telegram'::"text" NOT NULL,
    "session_id" "uuid" NOT NULL,
    "threshold_seconds" integer NOT NULL,
    "sent_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."telegram_session_warning_events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."telegram_sms_message_push_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "provider" "text" DEFAULT 'telegram'::"text" NOT NULL,
    "sms_message_id" bigint NOT NULL,
    "session_id" "uuid",
    "sent_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."telegram_sms_message_push_events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_chat_links" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "provider" "text" NOT NULL,
    "chat_id" "text" NOT NULL,
    "username" "text",
    "linked_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "revoked_at" timestamp with time zone
);


ALTER TABLE "public"."user_chat_links" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."users" (
    "id" "uuid" NOT NULL,
    "email" "text" NOT NULL,
    "role" "text" DEFAULT 'user'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "accepted_terms_at" timestamp with time zone,
    "accepted_privacy_at" timestamp with time zone,
    "full_name" character varying(255),
    "phone" character varying(20),
    "avatar_url" "text",
    "last_login_at" timestamp with time zone,
    "profile_completed" boolean DEFAULT false,
    "is_archived" boolean DEFAULT false,
    "archived_at" timestamp with time zone,
    "archive_reason" character varying(255),
    "archived_by" "uuid",
    "auth_provider" character varying(50) DEFAULT 'email'::character varying,
    "referral_code" "text",
    "referred_by" "uuid",
    "wallet_balance" numeric(10,2) DEFAULT 0.00 NOT NULL,
    "used_sim_numbers" "text"[] DEFAULT ARRAY[]::"text"[],
    "is_agent" boolean DEFAULT false,
    "priority" integer DEFAULT 0 NOT NULL,
    "signup_source" "text" DEFAULT 'web'::"text",
    "accepted_agent_quality_rules_at" timestamp with time zone,
    "accepted_agent_quality_rules_version" "text",
    CONSTRAINT "users_role_check" CHECK (("role" = ANY (ARRAY['admin'::"text", 'user'::"text"])))
);


ALTER TABLE "public"."users" OWNER TO "postgres";


COMMENT ON COLUMN "public"."users"."referral_code" IS 'Unique referral code (format: OP + 4 alphanumeric uppercase)';



COMMENT ON COLUMN "public"."users"."referred_by" IS 'User ID of the person who referred this user (nullable)';



COMMENT ON COLUMN "public"."users"."wallet_balance" IS 'Current wallet balance in PHP (₱)';



COMMENT ON COLUMN "public"."users"."used_sim_numbers" IS 'Array of all SIM numbers that have been used by this user across all sessions. Prevents automatic reuse until user explicitly selects one.';



COMMENT ON COLUMN "public"."users"."priority" IS 'SIM assignment override: higher number = higher priority user.';



CREATE OR REPLACE VIEW "public"."user_chat_links_with_email" AS
 SELECT "ucl"."id",
    "ucl"."user_id",
    "u"."email" AS "user_email",
    "ucl"."provider",
    "ucl"."chat_id",
    "ucl"."username",
    "ucl"."linked_at",
    "ucl"."revoked_at"
   FROM ("public"."user_chat_links" "ucl"
     JOIN "public"."users" "u" ON (("u"."id" = "ucl"."user_id")));


ALTER VIEW "public"."user_chat_links_with_email" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_push_subscriptions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "endpoint" "text" NOT NULL,
    "keys" "jsonb" NOT NULL,
    "device" "jsonb",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "last_seen_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."user_push_subscriptions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_settings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "email_notifications" boolean DEFAULT true,
    "sms_notifications" boolean DEFAULT true,
    "marketing_emails" boolean DEFAULT false,
    "security_alerts" boolean DEFAULT true,
    "two_factor_enabled" boolean DEFAULT false,
    "login_notifications" boolean DEFAULT true,
    "session_timeout" integer DEFAULT 30,
    "profile_visibility" character varying(20) DEFAULT 'private'::character varying,
    "data_sharing" boolean DEFAULT false,
    "theme" character varying(10) DEFAULT 'system'::character varying,
    "language" character varying(5) DEFAULT 'en'::character varying,
    "timezone" character varying(50) DEFAULT 'UTC'::character varying,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."user_settings" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_agent_commission_rates" AS
 SELECT "id" AS "user_id",
    "email",
    "public"."get_agent_commission_rate"("id") AS "commission_percentage",
        CASE
            WHEN (EXISTS ( SELECT 1
               FROM "public"."agent_commission_overrides"
              WHERE (("agent_commission_overrides"."user_id" = "u"."id") AND ("agent_commission_overrides"."is_active" = true) AND (("agent_commission_overrides"."expires_at" IS NULL) OR ("agent_commission_overrides"."expires_at" > "now"()))))) THEN true
            ELSE false
        END AS "has_custom_rate"
   FROM "public"."users" "u"
  WHERE ("is_agent" = true);


ALTER VIEW "public"."v_agent_commission_rates" OWNER TO "postgres";


COMMENT ON VIEW "public"."v_agent_commission_rates" IS 'View showing current commission rate for each agent (with custom overrides if any)';



CREATE OR REPLACE VIEW "public"."v_agent_transactions_auto_mature" AS
 SELECT "id",
    "user_id",
    "sim_app_usage_id",
    "sim_number",
    "app_name",
    "gross_amount",
    "agent_share",
    "site_share",
    "status",
    "available_at",
    "claimed_at",
    "created_at",
    "updated_at"
   FROM "public"."agent_transactions";


ALTER VIEW "public"."v_agent_transactions_auto_mature" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_otp_sessions_dynamic" AS
 SELECT "id",
    "user_id",
    "app_name",
    "sim_number",
    "otp_message",
    "otp_sender",
    "created_at",
    "expires_at",
    "activated_at",
        CASE
            WHEN ("status" = 'expired'::"text") THEN 'expired'::"text"
            WHEN ("status" = 'completed'::"text") THEN 'completed'::"text"
            WHEN (("status" = 'active'::"text") AND ("activated_at" IS NOT NULL) AND ("expires_at" IS NOT NULL) AND ("expires_at" < "now"())) THEN 'expired'::"text"
            WHEN (("status" = 'active'::"text") AND ("activated_at" IS NOT NULL) AND ("expires_at" IS NOT NULL) AND ("expires_at" >= "now"())) THEN 'active'::"text"
            WHEN (("status" = 'active'::"text") AND ("activated_at" IS NOT NULL) AND ("expires_at" IS NULL)) THEN 'active'::"text"
            WHEN ("status" = 'pending'::"text") THEN 'pending'::"text"
            ELSE "status"
        END AS "status",
        CASE
            WHEN (("status" = 'active'::"text") AND ("activated_at" IS NOT NULL) AND ("expires_at" IS NOT NULL) AND ("expires_at" >= "now"())) THEN GREATEST(0, (EXTRACT(epoch FROM ("expires_at" - "now"())))::integer)
            ELSE 0
        END AS "time_remaining",
    "user_email",
    "last_activity_at"
   FROM "public"."otp_sessions"
  ORDER BY "created_at" DESC;


ALTER VIEW "public"."v_otp_sessions_dynamic" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_app_availability" AS
 SELECT "app_name",
    "display_name",
    "price",
    ( SELECT "count"(*) AS "count"
           FROM "public"."sims" "s"
          WHERE (("s"."type" = 'private'::"text") AND ("s"."number" IS NOT NULL) AND (NOT ("s"."number" IN ( SELECT "v_otp_sessions_dynamic"."sim_number"
                   FROM "public"."v_otp_sessions_dynamic"
                  WHERE ("v_otp_sessions_dynamic"."status" = ANY (ARRAY['active'::"text"]))))) AND (NOT ("s"."number" IN ( SELECT "sim_app_usage"."sim_number"
                   FROM "public"."sim_app_usage"
                  WHERE ("sim_app_usage"."app_name" = "p"."app_name")))))) AS "available_sims"
   FROM "public"."otp_pricing" "p"
  ORDER BY "app_name";


ALTER VIEW "public"."v_app_availability" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_christmas_2025_uptime_leaderboard" AS
 WITH "event_cfg" AS (
         SELECT '2025-12-20 18:00:00'::timestamp without time zone AS "event_start_gmt8"
        ), "agent_base" AS (
         SELECT "u"."id" AS "user_id",
            "u"."email",
            "u"."is_agent",
            COALESCE("u"."is_archived", false) AS "is_archived"
           FROM "public"."users" "u"
        ), "auth_map" AS (
         SELECT "au"."id" AS "auth_user_id",
            "au"."email"
           FROM "auth"."users" "au"
          WHERE ("au"."email" IS NOT NULL)
        ), "tx_completed" AS (
         SELECT "at"."user_id",
            "count"(*) FILTER (WHERE ((("at"."status")::"text" <> 'cancelled'::"text") AND (("at"."created_at" AT TIME ZONE 'Asia/Manila'::"text") >= ( SELECT "event_cfg"."event_start_gmt8"
                   FROM "event_cfg")))) AS "completed_sessions"
           FROM "public"."agent_transactions" "at"
          WHERE ("at"."user_id" IS NOT NULL)
          GROUP BY "at"."user_id"
        ), "sim_failed" AS (
         SELECT "x"."public_user_id" AS "user_id",
            "sum"(GREATEST((COALESCE("x"."total_failed", 0) - COALESCE("x"."christmas_2025_failed_baseline", 0)), 0)) AS "failed_sessions"
           FROM ( SELECT "pu"."id" AS "public_user_id",
                    "s"."total_failed",
                    "s"."christmas_2025_failed_baseline"
                   FROM ((("public"."devices" "d"
                     JOIN "auth_map" "am" ON (("am"."auth_user_id" = "d"."user_id")))
                     JOIN "public"."users" "pu" ON (("lower"("pu"."email") = "lower"(("am"."email")::"text"))))
                     JOIN "public"."sims" "s" ON (("s"."device_id" = "d"."device_id")))
                  WHERE ("d"."user_id" IS NOT NULL)) "x"
          GROUP BY "x"."public_user_id"
        ), "complaints" AS (
         SELECT "at"."user_id",
            "count"(*) FILTER (WHERE ((("at"."status")::"text" = 'cancelled'::"text") AND (("at"."created_at" AT TIME ZONE 'Asia/Manila'::"text") >= ( SELECT "event_cfg"."event_start_gmt8"
                   FROM "event_cfg")))) AS "cancelled_transactions",
            COALESCE("sum"(
                CASE
                    WHEN ((("at"."status")::"text" <> 'cancelled'::"text") AND (("at"."created_at" AT TIME ZONE 'Asia/Manila'::"text") >= ( SELECT "event_cfg"."event_start_gmt8"
                       FROM "event_cfg"))) THEN "at"."agent_share"
                    ELSE (0)::numeric
                END), (0)::numeric) AS "total_profit"
           FROM "public"."agent_transactions" "at"
          GROUP BY "at"."user_id"
        ), "top_device" AS (
         SELECT "x"."public_user_id" AS "user_id",
            "x"."device_id" AS "top_device_id",
            "x"."name" AS "top_device_name",
            "x"."uptime_seconds" AS "top_uptime_seconds"
           FROM ( SELECT "pu"."id" AS "public_user_id",
                    "d"."device_id",
                    "d"."name",
                    "d"."uptime_seconds",
                    "row_number"() OVER (PARTITION BY "pu"."id" ORDER BY "d"."uptime_seconds" DESC, "d"."updated_at" DESC, "d"."device_id") AS "rn"
                   FROM (("public"."devices" "d"
                     JOIN "auth_map" "am" ON (("am"."auth_user_id" = "d"."user_id")))
                     JOIN "public"."users" "pu" ON (("lower"("pu"."email") = "lower"(("am"."email")::"text"))))
                  WHERE ("d"."user_id" IS NOT NULL)) "x"
          WHERE ("x"."rn" = 1)
        )
 SELECT "a"."user_id",
    "a"."email",
    "td"."top_device_id",
    "td"."top_device_name",
    COALESCE("td"."top_uptime_seconds", (0)::bigint) AS "top_uptime_seconds",
    COALESCE("txc"."completed_sessions", (0)::bigint) AS "completed_sessions",
    COALESCE("sf"."failed_sessions", (0)::bigint) AS "expired_sessions",
        CASE
            WHEN ((COALESCE("txc"."completed_sessions", (0)::bigint) + COALESCE("sf"."failed_sessions", (0)::bigint)) = 0) THEN (0)::numeric
            ELSE "round"((((COALESCE("txc"."completed_sessions", (0)::bigint))::numeric / NULLIF(((COALESCE("txc"."completed_sessions", (0)::bigint) + COALESCE("sf"."failed_sessions", (0)::bigint)))::numeric, (0)::numeric)) * (100)::numeric), 2)
        END AS "reliability_pct",
    COALESCE("c"."cancelled_transactions", (0)::bigint) AS "cancelled_transactions",
    COALESCE("c"."total_profit", (0)::numeric) AS "total_profit",
    (("a"."is_agent" = true) AND ("a"."is_archived" = false) AND (COALESCE("txc"."completed_sessions", (0)::bigint) >= 5) AND (COALESCE("c"."cancelled_transactions", (0)::bigint) <= 5) AND (
        CASE
            WHEN ((COALESCE("txc"."completed_sessions", (0)::bigint) + COALESCE("sf"."failed_sessions", (0)::bigint)) = 0) THEN (0)::numeric
            ELSE (((COALESCE("txc"."completed_sessions", (0)::bigint))::numeric / NULLIF(((COALESCE("txc"."completed_sessions", (0)::bigint) + COALESCE("sf"."failed_sessions", (0)::bigint)))::numeric, (0)::numeric)) * (100)::numeric)
        END >= (50)::numeric)) AS "is_eligible"
   FROM (((("agent_base" "a"
     LEFT JOIN "tx_completed" "txc" ON (("txc"."user_id" = "a"."user_id")))
     LEFT JOIN "sim_failed" "sf" ON (("sf"."user_id" = "a"."user_id")))
     LEFT JOIN "complaints" "c" ON (("c"."user_id" = "a"."user_id")))
     LEFT JOIN "top_device" "td" ON (("td"."user_id" = "a"."user_id")));


ALTER VIEW "public"."v_christmas_2025_uptime_leaderboard" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_christmas_2025_uptime_ranking_live" AS
 SELECT "user_id",
    "email",
    "top_device_id",
    "top_device_name",
    "top_uptime_seconds",
    "completed_sessions",
    "expired_sessions",
    "reliability_pct",
    "cancelled_transactions",
    "total_profit",
    "is_eligible",
    "rank"() OVER (ORDER BY "top_uptime_seconds" DESC, "reliability_pct" DESC, "total_profit" DESC, "user_id") AS "rank"
   FROM "public"."v_christmas_2025_uptime_leaderboard" "v"
  WHERE ("user_id" <> 'd10034e7-48c0-4786-a26d-e2cf94c160d4'::"uuid");


ALTER VIEW "public"."v_christmas_2025_uptime_ranking_live" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_christmas_2025_uptime_ranking" AS
 WITH "event_cfg" AS (
         SELECT '2025-12-31 00:00:00'::timestamp without time zone AS "event_end_gmt8"
        ), "snapshot_state" AS (
         SELECT (EXISTS ( SELECT 1
                   FROM "public"."christmas_2025_uptime_ranking_snapshot"
                 LIMIT 1)) AS "has_snapshot"
        )
 SELECT "s"."user_id",
    "s"."email",
    "s"."top_device_id",
    "s"."top_device_name",
    "s"."top_uptime_seconds",
    "s"."completed_sessions",
    "s"."expired_sessions",
    "s"."reliability_pct",
    "s"."cancelled_transactions",
    "s"."total_profit",
    "s"."is_eligible",
    "s"."rank"
   FROM "public"."christmas_2025_uptime_ranking_snapshot" "s"
  WHERE ((("now"() AT TIME ZONE 'Asia/Manila'::"text") >= ( SELECT "event_cfg"."event_end_gmt8"
           FROM "event_cfg")) AND (( SELECT "snapshot_state"."has_snapshot"
           FROM "snapshot_state") = true))
UNION ALL
 SELECT "v"."user_id",
    "v"."email",
    "v"."top_device_id",
    "v"."top_device_name",
    "v"."top_uptime_seconds",
    "v"."completed_sessions",
    "v"."expired_sessions",
    "v"."reliability_pct",
    "v"."cancelled_transactions",
    "v"."total_profit",
    "v"."is_eligible",
    "v"."rank"
   FROM "public"."v_christmas_2025_uptime_ranking_live" "v"
  WHERE (NOT ((("now"() AT TIME ZONE 'Asia/Manila'::"text") >= ( SELECT "event_cfg"."event_end_gmt8"
           FROM "event_cfg")) AND (( SELECT "snapshot_state"."has_snapshot"
           FROM "snapshot_state") = true)));


ALTER VIEW "public"."v_christmas_2025_uptime_ranking" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_otp_sessions_with_retry" AS
 SELECT "d"."id",
    "d"."user_id",
    "d"."app_name",
    "d"."sim_number",
    "d"."status",
    "d"."created_at",
    "d"."expires_at",
    "os"."sms_message_id",
    "d"."otp_message",
    "d"."otp_sender",
    "os"."status_updated_at",
    "os"."timeout_duration",
    "os"."last_activity_at",
    "d"."activated_at",
    "os"."retry_count",
    "os"."retry_limit",
    "os"."previous_sim_number",
    "os"."last_retry_at",
    ("os"."retry_limit" - "os"."retry_count") AS "retries_remaining",
        CASE
            WHEN (("d"."status" = 'expired'::"text") AND ("os"."retry_count" < "os"."retry_limit")) THEN true
            ELSE false
        END AS "can_retry",
        CASE
            WHEN (("d"."status" = 'expired'::"text") AND ("os"."retry_count" >= "os"."retry_limit")) THEN true
            ELSE false
        END AS "retry_limit_exceeded"
   FROM ("public"."v_otp_sessions_dynamic" "d"
     JOIN "public"."otp_sessions" "os" ON (("os"."id" = "d"."id")))
  ORDER BY "d"."created_at" DESC;


ALTER VIEW "public"."v_otp_sessions_with_retry" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_otp_sessions_with_status" AS
 SELECT "id",
    "user_id",
    "app_name",
    "sim_number",
    "otp_message",
    "otp_sender",
    "created_at",
    "expires_at",
    "activated_at",
    "status_updated_at",
    "last_activity_at",
        CASE
            WHEN ("status" = 'expired'::"text") THEN 'expired'::"text"
            WHEN ("status" = 'completed'::"text") THEN 'completed'::"text"
            WHEN (("status" = 'active'::"text") AND ("expires_at" IS NOT NULL) AND ("expires_at" < "now"())) THEN 'expired'::"text"
            WHEN (("status" = 'active'::"text") AND ("expires_at" IS NOT NULL) AND ("expires_at" >= "now"())) THEN 'active'::"text"
            WHEN (("status" = 'active'::"text") AND ("expires_at" IS NULL)) THEN 'active'::"text"
            WHEN ("status" = 'pending'::"text") THEN 'pending'::"text"
            ELSE "status"
        END AS "dynamic_status",
    "status" AS "original_status",
        CASE
            WHEN (("status" = 'active'::"text") AND ("expires_at" IS NOT NULL) AND ("expires_at" >= "now"())) THEN GREATEST(0, (EXTRACT(epoch FROM ("expires_at" - "now"())))::integer)
            ELSE 0
        END AS "time_remaining_seconds",
        CASE
            WHEN (("status" = 'active'::"text") AND ("expires_at" IS NOT NULL) AND ("expires_at" >= "now"())) THEN "concat"("floor"((EXTRACT(epoch FROM ("expires_at" - "now"())) / (60)::numeric)), 'm ', "mod"((EXTRACT(epoch FROM ("expires_at" - "now"())))::integer, 60), 's')
            ELSE '00m 00s'::"text"
        END AS "time_remaining_formatted",
        CASE
            WHEN ("status" = 'expired'::"text") THEN true
            WHEN (("status" = 'active'::"text") AND ("expires_at" IS NOT NULL) AND ("expires_at" < "now"())) THEN true
            ELSE false
        END AS "is_expired",
        CASE
            WHEN (("status" = 'active'::"text") AND (("expires_at" IS NULL) OR ("expires_at" >= "now"()))) THEN true
            ELSE false
        END AS "is_active",
        CASE
            WHEN ("status" = 'pending'::"text") THEN true
            ELSE false
        END AS "is_pending",
        CASE
            WHEN ("status" = 'completed'::"text") THEN true
            ELSE false
        END AS "is_completed"
   FROM "public"."otp_sessions"
  ORDER BY "created_at" DESC;


ALTER VIEW "public"."v_otp_sessions_with_status" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_rate_limit_config_active" AS
 SELECT "id",
    "endpoint_path",
    "limit_per_window",
    "window_seconds",
    "error_message",
    "description",
    "is_active",
    "created_at",
    "updated_at"
   FROM "public"."rate_limit_config"
  WHERE ("is_active" = true)
  ORDER BY
        CASE
            WHEN ("endpoint_path" = 'global'::"text") THEN 1
            ELSE 2
        END, "endpoint_path";


ALTER VIEW "public"."v_rate_limit_config_active" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_rate_limit_usage" AS
 SELECT "identifier",
    "endpoint_path",
    "count",
    "reset_time",
        CASE
            WHEN ("reset_time" > "now"()) THEN ("reset_time" - "now"())
            ELSE '00:00:00'::interval
        END AS "time_remaining",
    "created_at",
    "updated_at"
   FROM "public"."rate_limit_tracking"
  WHERE ("reset_time" > "now"())
  ORDER BY "updated_at" DESC;


ALTER VIEW "public"."v_rate_limit_usage" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_referral_stats" AS
 WITH "distinct_earnings" AS (
         SELECT DISTINCT ON ("re"."otp_session_id", "re"."referrer_id") "re"."referrer_id",
            "re"."otp_session_id",
            "re"."amount",
            "re"."status"
           FROM "public"."referral_earnings" "re"
          ORDER BY "re"."otp_session_id", "re"."referrer_id",
                CASE
                    WHEN ("re"."status" = 'claimed'::"text") THEN 0
                    ELSE 1
                END, "re"."created_at"
        ), "referral_counts" AS (
         SELECT "u_1"."id" AS "referrer_id",
            "count"(DISTINCT "u2"."id") AS "total_referrals"
           FROM ("public"."users" "u_1"
             LEFT JOIN "public"."users" "u2" ON (("u2"."referred_by" = "u_1"."id")))
          GROUP BY "u_1"."id"
        ), "earnings_aggregated" AS (
         SELECT "de"."referrer_id",
            "count"(DISTINCT "de"."otp_session_id") AS "total_completed_otps",
            COALESCE("sum"(
                CASE
                    WHEN ("de"."status" = 'pending'::"text") THEN "de"."amount"
                    ELSE (0)::numeric
                END), (0)::numeric) AS "unclaimed_commission",
            COALESCE("sum"(
                CASE
                    WHEN ("de"."status" = 'claimed'::"text") THEN "de"."amount"
                    ELSE (0)::numeric
                END), (0)::numeric) AS "lifetime_earnings"
           FROM "distinct_earnings" "de"
          GROUP BY "de"."referrer_id"
        )
 SELECT "u"."id" AS "referrer_id",
    "u"."referral_code",
    COALESCE("rc"."total_referrals", (0)::bigint) AS "total_referrals",
    COALESCE("ea"."total_completed_otps", (0)::bigint) AS "total_completed_otps",
    COALESCE("ea"."unclaimed_commission", (0)::numeric) AS "unclaimed_commission",
    COALESCE("ea"."lifetime_earnings", (0)::numeric) AS "lifetime_earnings"
   FROM (("public"."users" "u"
     LEFT JOIN "referral_counts" "rc" ON (("rc"."referrer_id" = "u"."id")))
     LEFT JOIN "earnings_aggregated" "ea" ON (("ea"."referrer_id" = "u"."id")));


ALTER VIEW "public"."v_referral_stats" OWNER TO "postgres";


COMMENT ON VIEW "public"."v_referral_stats" IS 'Aggregated referral statistics. Calculates referrals and earnings separately to prevent multiplication issues.';



CREATE OR REPLACE VIEW "public"."v_sims_with_status" AS
 SELECT "s"."id",
    "s"."number",
    "s"."carrier",
    "s"."slot",
    "s"."type",
    "s"."device_id",
    "s"."device_name",
    "s"."updated_at",
    "d"."status" AS "device_status",
        CASE
            WHEN ((("s"."status")::"text" = 'ACTIVE'::"text") AND ("d"."last_seen" IS NOT NULL) AND (("now"() - "d"."last_seen") < '00:05:00'::interval)) THEN 'active'::"text"
            ELSE 'offline'::"text"
        END AS "computed_status"
   FROM ("public"."sims" "s"
     LEFT JOIN "public"."devices" "d" ON (("s"."device_id" = "d"."device_id")));


ALTER VIEW "public"."v_sims_with_status" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_sim_activity_summary" AS
 SELECT "sim"."sim_number",
    "vsws"."computed_status" AS "status",
    COALESCE("otp"."total_otps", (0)::bigint) AS "total_otps",
    COALESCE("sms"."total_messages", (0)::bigint) AS "total_messages",
    COALESCE("app"."total_app_usage", (0)::bigint) AS "total_app_usage",
    "sms_latest"."timestamp" AS "last_sms_timestamp",
    "sms_latest"."message" AS "last_sms_message",
    "sms_latest"."sender" AS "last_sms_sender"
   FROM (((((( SELECT "sms_messages"."sim_number"
           FROM "public"."sms_messages"
        UNION
         SELECT "otp_sessions"."sim_number"
           FROM "public"."otp_sessions"
        UNION
         SELECT "sim_app_usage"."sim_number"
           FROM "public"."sim_app_usage") "sim"
     LEFT JOIN ( SELECT "otp_sessions"."sim_number",
            "count"(*) AS "total_otps"
           FROM "public"."otp_sessions"
          GROUP BY "otp_sessions"."sim_number") "otp" ON (("otp"."sim_number" = "sim"."sim_number")))
     LEFT JOIN ( SELECT "sms_messages"."sim_number",
            "count"(*) AS "total_messages"
           FROM "public"."sms_messages"
          GROUP BY "sms_messages"."sim_number") "sms" ON (("sms"."sim_number" = "sim"."sim_number")))
     LEFT JOIN ( SELECT "sim_app_usage"."sim_number",
            "count"(*) AS "total_app_usage"
           FROM "public"."sim_app_usage"
          GROUP BY "sim_app_usage"."sim_number") "app" ON (("app"."sim_number" = "sim"."sim_number")))
     LEFT JOIN LATERAL ( SELECT "sms_messages"."timestamp",
            "sms_messages"."message",
            "sms_messages"."sender"
           FROM "public"."sms_messages"
          WHERE ("sms_messages"."sim_number" = "sim"."sim_number")
          ORDER BY "sms_messages"."timestamp" DESC
         LIMIT 1) "sms_latest" ON (true))
     LEFT JOIN "public"."v_sims_with_status" "vsws" ON (("vsws"."number" = "sim"."sim_number")));


ALTER VIEW "public"."v_sim_activity_summary" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_sim_health_status" AS
 SELECT "s"."number" AS "sim_number",
    COALESCE("vs"."computed_status", 'unknown'::"text") AS "sim_status",
        CASE
            WHEN (COALESCE("os"."total_sessions", (0)::bigint) = 0) THEN 'inactive'::"text"
            WHEN (COALESCE("os"."success_rate", (0)::numeric) >= (80)::numeric) THEN 'healthy'::"text"
            WHEN (COALESCE("os"."success_rate", (0)::numeric) >= (60)::numeric) THEN 'warning'::"text"
            ELSE 'critical'::"text"
        END AS "health_status",
    COALESCE("os"."total_sessions", (0)::bigint) AS "total_sessions",
    COALESCE("os"."success_rate", (0)::numeric) AS "success_rate",
    COALESCE("os"."last_activity", NULL::timestamp with time zone) AS "last_activity",
    COALESCE("os"."hours_since_last_activity", NULL::numeric) AS "hours_since_last_activity"
   FROM (("public"."sims" "s"
     LEFT JOIN ( SELECT "v_otp_sessions_dynamic"."sim_number",
            "count"(*) AS "total_sessions",
            "round"(((("count"(*) FILTER (WHERE ("v_otp_sessions_dynamic"."status" = 'completed'::"text")))::numeric / ("count"(*))::numeric) * (100)::numeric), 2) AS "success_rate",
            "max"("v_otp_sessions_dynamic"."created_at") AS "last_activity",
            (EXTRACT(epoch FROM ("now"() - "max"("v_otp_sessions_dynamic"."created_at"))) / (3600)::numeric) AS "hours_since_last_activity"
           FROM "public"."v_otp_sessions_dynamic"
          WHERE ("v_otp_sessions_dynamic"."sim_number" IS NOT NULL)
          GROUP BY "v_otp_sessions_dynamic"."sim_number") "os" ON (("os"."sim_number" = "s"."number")))
     LEFT JOIN "public"."v_sims_with_status" "vs" ON (("vs"."number" = "s"."number")));


ALTER VIEW "public"."v_sim_health_status" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_sim_otp_stats" AS
 SELECT "s"."number" AS "sim_number",
    COALESCE("vs"."computed_status", 'unknown'::"text") AS "sim_status",
    COALESCE("sm"."total_sms_messages", (0)::bigint) AS "total_sms_messages",
    COALESCE("os"."total_otp_sessions", (0)::bigint) AS "total_otp_sessions",
    COALESCE("os"."total_completed", (0)::bigint) AS "total_completed",
    COALESCE("os"."total_expired", (0)::bigint) AS "total_expired",
    COALESCE("os"."total_pending", (0)::bigint) AS "total_pending",
    COALESCE("os"."total_active", (0)::bigint) AS "total_active",
    COALESCE("os"."total_failed", (0)::bigint) AS "total_failed",
    COALESCE("os"."success_rate", (0)::numeric) AS "success_rate",
    COALESCE("os"."avg_session_duration_minutes", (0)::numeric) AS "avg_session_duration_minutes",
    COALESCE("os"."last_activity", NULL::timestamp with time zone) AS "last_activity"
   FROM ((("public"."sims" "s"
     LEFT JOIN ( SELECT "sms_messages"."sim_number",
            "count"(*) AS "total_sms_messages"
           FROM "public"."sms_messages"
          GROUP BY "sms_messages"."sim_number") "sm" ON (("sm"."sim_number" = "s"."number")))
     LEFT JOIN ( SELECT "v_otp_sessions_dynamic"."sim_number",
            "count"(*) AS "total_otp_sessions",
            "count"(*) FILTER (WHERE ("v_otp_sessions_dynamic"."status" = 'completed'::"text")) AS "total_completed",
            "count"(*) FILTER (WHERE ("v_otp_sessions_dynamic"."status" = 'expired'::"text")) AS "total_expired",
            "count"(*) FILTER (WHERE ("v_otp_sessions_dynamic"."status" = 'pending'::"text")) AS "total_pending",
            "count"(*) FILTER (WHERE ("v_otp_sessions_dynamic"."status" = 'active'::"text")) AS "total_active",
            "count"(*) FILTER (WHERE (("v_otp_sessions_dynamic"."status" = 'expired'::"text") AND ("v_otp_sessions_dynamic"."activated_at" IS NOT NULL))) AS "total_failed",
                CASE
                    WHEN ("count"(*) > 0) THEN "round"(((("count"(*) FILTER (WHERE ("v_otp_sessions_dynamic"."status" = 'completed'::"text")))::numeric / ("count"(*))::numeric) * (100)::numeric), 2)
                    ELSE (0)::numeric
                END AS "success_rate",
                CASE
                    WHEN ("count"(*) FILTER (WHERE ("v_otp_sessions_dynamic"."status" = 'completed'::"text")) > 0) THEN "round"("avg"((EXTRACT(epoch FROM ("v_otp_sessions_dynamic"."activated_at" - "v_otp_sessions_dynamic"."created_at")) / (60)::numeric)) FILTER (WHERE ("v_otp_sessions_dynamic"."status" = 'completed'::"text")), 2)
                    ELSE (0)::numeric
                END AS "avg_session_duration_minutes",
            "max"("v_otp_sessions_dynamic"."created_at") AS "last_activity"
           FROM "public"."v_otp_sessions_dynamic"
          WHERE ("v_otp_sessions_dynamic"."sim_number" IS NOT NULL)
          GROUP BY "v_otp_sessions_dynamic"."sim_number") "os" ON (("os"."sim_number" = "s"."number")))
     LEFT JOIN "public"."v_sims_with_status" "vs" ON (("vs"."number" = "s"."number")));


ALTER VIEW "public"."v_sim_otp_stats" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_sim_otp_stats_recent" AS
 SELECT "s"."number" AS "sim_number",
    COALESCE("vs"."computed_status", 'unknown'::"text") AS "sim_status",
    COALESCE("os"."last_24h_sessions", (0)::bigint) AS "last_24h_sessions",
    COALESCE("os"."last_24h_completed", (0)::bigint) AS "last_24h_completed",
    COALESCE("os"."last_7d_sessions", (0)::bigint) AS "last_7d_sessions",
    COALESCE("os"."last_7d_completed", (0)::bigint) AS "last_7d_completed",
    COALESCE("os"."last_30d_sessions", (0)::bigint) AS "last_30d_sessions",
    COALESCE("os"."last_30d_completed", (0)::bigint) AS "last_30d_completed"
   FROM (("public"."sims" "s"
     LEFT JOIN ( SELECT "v_otp_sessions_dynamic"."sim_number",
            "count"(*) FILTER (WHERE ("v_otp_sessions_dynamic"."created_at" >= ("now"() - '24:00:00'::interval))) AS "last_24h_sessions",
            "count"(*) FILTER (WHERE (("v_otp_sessions_dynamic"."created_at" >= ("now"() - '24:00:00'::interval)) AND ("v_otp_sessions_dynamic"."status" = 'completed'::"text"))) AS "last_24h_completed",
            "count"(*) FILTER (WHERE ("v_otp_sessions_dynamic"."created_at" >= ("now"() - '7 days'::interval))) AS "last_7d_sessions",
            "count"(*) FILTER (WHERE (("v_otp_sessions_dynamic"."created_at" >= ("now"() - '7 days'::interval)) AND ("v_otp_sessions_dynamic"."status" = 'completed'::"text"))) AS "last_7d_completed",
            "count"(*) FILTER (WHERE ("v_otp_sessions_dynamic"."created_at" >= ("now"() - '30 days'::interval))) AS "last_30d_sessions",
            "count"(*) FILTER (WHERE (("v_otp_sessions_dynamic"."created_at" >= ("now"() - '30 days'::interval)) AND ("v_otp_sessions_dynamic"."status" = 'completed'::"text"))) AS "last_30d_completed"
           FROM "public"."v_otp_sessions_dynamic"
          WHERE ("v_otp_sessions_dynamic"."sim_number" IS NOT NULL)
          GROUP BY "v_otp_sessions_dynamic"."sim_number") "os" ON (("os"."sim_number" = "s"."number")))
     LEFT JOIN "public"."v_sims_with_status" "vs" ON (("vs"."number" = "s"."number")));


ALTER VIEW "public"."v_sim_otp_stats_recent" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_sim_performance_metrics" AS
 SELECT "s"."number" AS "sim_number",
    COALESCE("vs"."computed_status", 'unknown'::"text") AS "sim_status",
    COALESCE("os"."avg_response_time_minutes", (0)::numeric) AS "avg_response_time_minutes",
    COALESCE("os"."fastest_completion_minutes", (0)::numeric) AS "fastest_completion_minutes",
    COALESCE("os"."slowest_completion_minutes", (0)::numeric) AS "slowest_completion_minutes",
    COALESCE("os"."consecutive_failures", (0)::bigint) AS "consecutive_failures",
    COALESCE("os"."last_success", NULL::timestamp with time zone) AS "last_success",
    COALESCE("os"."last_failure", NULL::timestamp with time zone) AS "last_failure"
   FROM (("public"."sims" "s"
     LEFT JOIN ( SELECT "v_otp_sessions_dynamic"."sim_number",
            "round"("avg"((EXTRACT(epoch FROM ("v_otp_sessions_dynamic"."activated_at" - "v_otp_sessions_dynamic"."created_at")) / (60)::numeric)) FILTER (WHERE ("v_otp_sessions_dynamic"."status" = 'completed'::"text")), 2) AS "avg_response_time_minutes",
            "round"("min"((EXTRACT(epoch FROM ("v_otp_sessions_dynamic"."activated_at" - "v_otp_sessions_dynamic"."created_at")) / (60)::numeric)) FILTER (WHERE ("v_otp_sessions_dynamic"."status" = 'completed'::"text")), 2) AS "fastest_completion_minutes",
            "round"("max"((EXTRACT(epoch FROM ("v_otp_sessions_dynamic"."activated_at" - "v_otp_sessions_dynamic"."created_at")) / (60)::numeric)) FILTER (WHERE ("v_otp_sessions_dynamic"."status" = 'completed'::"text")), 2) AS "slowest_completion_minutes",
            "count"(*) FILTER (WHERE (("v_otp_sessions_dynamic"."status" = 'expired'::"text") AND ("v_otp_sessions_dynamic"."created_at" >= ("now"() - '24:00:00'::interval)))) AS "consecutive_failures",
            "max"("v_otp_sessions_dynamic"."activated_at") FILTER (WHERE ("v_otp_sessions_dynamic"."status" = 'completed'::"text")) AS "last_success",
            "max"("v_otp_sessions_dynamic"."created_at") FILTER (WHERE ("v_otp_sessions_dynamic"."status" = 'expired'::"text")) AS "last_failure"
           FROM "public"."v_otp_sessions_dynamic"
          WHERE ("v_otp_sessions_dynamic"."sim_number" IS NOT NULL)
          GROUP BY "v_otp_sessions_dynamic"."sim_number") "os" ON (("os"."sim_number" = "s"."number")))
     LEFT JOIN "public"."v_sims_with_status" "vs" ON (("vs"."number" = "s"."number")));


ALTER VIEW "public"."v_sim_performance_metrics" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_sim_stats_with_number" AS
 SELECT "ss"."sim_id",
    "s"."number" AS "sim_number",
    "s"."carrier",
    "ss"."uptime_seconds",
    "ss"."total_completed",
    "ss"."total_failed",
    "ss"."total_earnings",
    "ss"."last_status_change",
    "ss"."last_heartbeat",
    "ss"."updated_at",
        CASE
            WHEN (("ss"."total_completed" + "ss"."total_failed") > 0) THEN "round"(((("ss"."total_completed")::numeric / (("ss"."total_completed" + "ss"."total_failed"))::numeric) * (100)::numeric), 2)
            ELSE (0)::numeric
        END AS "success_rate_percent"
   FROM ("public"."sim_stats" "ss"
     JOIN "public"."sims" "s" ON (("ss"."sim_id" = "s"."id")));


ALTER VIEW "public"."v_sim_stats_with_number" OWNER TO "postgres";


COMMENT ON VIEW "public"."v_sim_stats_with_number" IS 'View of sim_stats with SIM number and carrier included for easier querying and display';



CREATE OR REPLACE VIEW "public"."v_sms_messages_full" AS
 SELECT "m"."id",
    "m"."sim_number",
    "m"."sender",
    "m"."message",
    "m"."timestamp",
    "s"."carrier",
    "s"."type" AS "sim_type",
    "s"."slot",
    "s"."device_id",
    "s"."device_name",
    "d"."status" AS "device_status",
        CASE
            WHEN ("d"."last_seen" IS NULL) THEN 'offline'::"text"
            WHEN (("now"() - "d"."last_seen") < '00:05:00'::interval) THEN 'active'::"text"
            WHEN (("now"() - "d"."last_seen") < '00:30:00'::interval) THEN 'idle'::"text"
            ELSE 'offline'::"text"
        END AS "computed_status"
   FROM (("public"."sms_messages" "m"
     LEFT JOIN "public"."sims" "s" ON (("m"."sim_number" = "s"."number")))
     LEFT JOIN "public"."devices" "d" ON (("s"."device_id" = "d"."device_id")));


ALTER VIEW "public"."v_sms_messages_full" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_user_sessions" AS
 SELECT "os"."id",
    "os"."user_id",
    "os"."app_name",
    "p"."display_name" AS "app_display_name",
    "os"."sim_number",
    "os"."status",
    "os"."otp_message",
    "os"."otp_sender",
    "os"."created_at",
    "os"."expires_at",
    "os"."status_updated_at",
        CASE
            WHEN ("os"."status" = 'pending'::"text") THEN 'Pending'::"text"
            WHEN ("os"."status" = 'active'::"text") THEN 'Active'::"text"
            WHEN ("os"."status" = 'completed'::"text") THEN 'Completed'::"text"
            WHEN ("os"."status" = 'expired'::"text") THEN 'Expired'::"text"
            ELSE 'Unknown'::"text"
        END AS "status_display",
        CASE
            WHEN (("os"."status" = 'active'::"text") AND ("os"."expires_at" IS NOT NULL)) THEN GREATEST(0, (EXTRACT(epoch FROM ("os"."expires_at" - "now"())))::integer)
            ELSE 0
        END AS "time_remaining_seconds"
   FROM ("public"."otp_sessions" "os"
     LEFT JOIN "public"."otp_pricing" "p" ON (("os"."app_name" = "p"."app_name")))
  ORDER BY "os"."created_at" DESC;


ALTER VIEW "public"."v_user_sessions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."vouchers" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "code" "text" NOT NULL,
    "balance" numeric(10,2) DEFAULT 0,
    "max_uses" integer DEFAULT 1,
    "used_count" integer DEFAULT 0,
    "active" boolean DEFAULT true,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."vouchers" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_user_transaction_logs" AS
 SELECT "mp"."id",
    "mp"."user_id",
    "mp"."app_name",
    "pm"."display_name" AS "payment_method_name",
    "mp"."amount",
    "mp"."status",
    "mp"."receipt_url",
    "v"."code" AS "voucher_code",
    "mp"."created_at",
    "mp"."approved_at"
   FROM (("public"."manual_payments" "mp"
     LEFT JOIN "public"."payment_methods" "pm" ON (("pm"."id" = "mp"."payment_method_id")))
     LEFT JOIN "public"."vouchers" "v" ON (("v"."id" = "mp"."voucher_id")))
  ORDER BY "mp"."created_at" DESC;


ALTER VIEW "public"."v_user_transaction_logs" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_vouchers_with_usage" AS
SELECT
    NULL::"uuid" AS "id",
    NULL::"text" AS "code",
    NULL::numeric(10,2) AS "balance",
    NULL::integer AS "max_uses",
    NULL::integer AS "used_count",
    NULL::numeric AS "total_used",
    NULL::numeric AS "remaining_balance",
    NULL::boolean AS "active",
    NULL::timestamp with time zone AS "created_at";


ALTER VIEW "public"."v_vouchers_with_usage" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."voucher_usage" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "voucher_id" "uuid",
    "user_id" "uuid",
    "amount_used" numeric(10,2),
    "payment_id" "uuid",
    "used_at" timestamp with time zone DEFAULT "now"(),
    "payment_token" "text",
    "payment_token_expires_at" timestamp with time zone
);


ALTER TABLE "public"."voucher_usage" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."wallet_topups" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "user_email" "text" NOT NULL,
    "payment_method_id" "text" DEFAULT 'gcash'::"text" NOT NULL,
    "amount" numeric(10,2) NOT NULL,
    "receipt_url" "text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "approved_at" timestamp with time zone,
    "approved_by" "uuid",
    "rejected_at" timestamp with time zone,
    "rejected_by" "uuid",
    "rejection_reason" "text",
    "matched_notification_id" bigint,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "sender_number" "text" NOT NULL,
    CONSTRAINT "wallet_topups_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'rejected'::"text"])))
);


ALTER TABLE "public"."wallet_topups" OWNER TO "postgres";


COMMENT ON TABLE "public"."wallet_topups" IS 'Wallet top-up requests with GCash notification matching support';



COMMENT ON COLUMN "public"."wallet_topups"."user_email" IS 'User email from users table, automatically synced via trigger';



COMMENT ON COLUMN "public"."wallet_topups"."receipt_url" IS 'Receipt image URL (required for verification)';



COMMENT ON COLUMN "public"."wallet_topups"."matched_notification_id" IS 'GCash notification that matched this top-up (for auto-approval)';



COMMENT ON COLUMN "public"."wallet_topups"."sender_number" IS 'Phone number used for payment (required for matching with gcash_notif sender_number)';



CREATE TABLE IF NOT EXISTS "public"."wallet_transactions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "type" "text" NOT NULL,
    "amount" numeric(10,2) NOT NULL,
    "description" "text",
    "referral_earning_id" "uuid",
    "referral_milestone_id" "uuid",
    "otp_session_id" "uuid",
    "payment_id" "uuid",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "balance_before" numeric(10,2),
    "balance_after" numeric(10,2),
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "processed_at" timestamp with time zone,
    "withdrawal_payment_method_id" "uuid",
    "withdrawal_account_name" character varying(255),
    "withdrawal_account_number" character varying(255),
    "withdrawal_receipt_url" "text",
    CONSTRAINT "wallet_transactions_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'success'::"text", 'failed'::"text"]))),
    CONSTRAINT "wallet_transactions_type_check" CHECK (("type" = ANY (ARRAY['commission'::"text", 'milestone'::"text", 'topup'::"text", 'withdrawal'::"text", 'purchase'::"text", 'refund'::"text", 'adjustment'::"text"])))
);


ALTER TABLE "public"."wallet_transactions" OWNER TO "postgres";


COMMENT ON TABLE "public"."wallet_transactions" IS 'Complete audit trail of all wallet transactions';



COMMENT ON COLUMN "public"."wallet_transactions"."type" IS 'commission, milestone, topup, withdrawal, purchase, refund, adjustment';



COMMENT ON COLUMN "public"."wallet_transactions"."balance_before" IS 'Wallet balance before this transaction (for audit)';



COMMENT ON COLUMN "public"."wallet_transactions"."balance_after" IS 'Wallet balance after this transaction (for audit)';



COMMENT ON COLUMN "public"."wallet_transactions"."withdrawal_payment_method_id" IS 'Payment method used for withdrawal (only for type=withdrawal)';



COMMENT ON COLUMN "public"."wallet_transactions"."withdrawal_account_name" IS 'Account holder name for withdrawal (only for type=withdrawal)';



COMMENT ON COLUMN "public"."wallet_transactions"."withdrawal_account_number" IS 'Account number/mobile number for withdrawal (only for type=withdrawal)';



COMMENT ON COLUMN "public"."wallet_transactions"."withdrawal_receipt_url" IS 'Receipt/proof of payment uploaded by admin after processing withdrawal';



CREATE TABLE IF NOT EXISTS "public"."withdrawal_payment_methods" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" character varying(100) NOT NULL,
    "display_name" character varying(100) NOT NULL,
    "description" "text",
    "account_name_label" character varying(100) DEFAULT 'Account Name'::character varying,
    "account_number_label" character varying(100) DEFAULT 'Account Number'::character varying,
    "is_active" boolean DEFAULT true,
    "sort_order" integer DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."withdrawal_payment_methods" OWNER TO "postgres";


COMMENT ON TABLE "public"."withdrawal_payment_methods" IS 'Payment methods available for wallet withdrawals (managed by admin)';



COMMENT ON COLUMN "public"."withdrawal_payment_methods"."account_name_label" IS 'Custom label for the account name input field (e.g., "Account Name", "Full Name", "Account Holder Name")';



COMMENT ON COLUMN "public"."withdrawal_payment_methods"."account_number_label" IS 'Custom label for the account number input field (e.g., "Account Number", "Mobile Number", "Account ID")';



ALTER TABLE ONLY "public"."agent_claims" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."agent_claims_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."agent_invite_earnings" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."agent_invite_earnings_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."agent_transactions" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."agent_transactions_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."notification_outbox" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."notification_outbox_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."otp_pricing" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."otp_pricing_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."sim_history" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."sim_history_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."sims" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."sims_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."sms_messages" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."sms_messages_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."system_logs" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."system_logs_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."account_deletion_tokens"
    ADD CONSTRAINT "account_deletion_tokens_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."account_deletion_tokens"
    ADD CONSTRAINT "account_deletion_tokens_token_key" UNIQUE ("token");



ALTER TABLE ONLY "public"."agent_applications"
    ADD CONSTRAINT "agent_applications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."agent_balances"
    ADD CONSTRAINT "agent_balances_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."agent_claims"
    ADD CONSTRAINT "agent_claims_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."agent_commission_config"
    ADD CONSTRAINT "agent_commission_config_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."agent_commission_overrides"
    ADD CONSTRAINT "agent_commission_overrides_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."agent_invite_earnings"
    ADD CONSTRAINT "agent_invite_earnings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."agent_transactions"
    ADD CONSTRAINT "agent_transactions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."announcement"
    ADD CONSTRAINT "announcement_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."chat_bot_states"
    ADD CONSTRAINT "chat_bot_states_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."chat_link_codes"
    ADD CONSTRAINT "chat_link_codes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."christmas_2025_uptime_ranking_snapshot"
    ADD CONSTRAINT "christmas_2025_uptime_ranking_snapshot_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."contact_submissions"
    ADD CONSTRAINT "contact_submissions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."daily_analytics_snapshots"
    ADD CONSTRAINT "daily_analytics_snapshots_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."devices"
    ADD CONSTRAINT "devices_device_id_key" UNIQUE ("device_id");



ALTER TABLE ONLY "public"."devices"
    ADD CONSTRAINT "devices_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."feedback"
    ADD CONSTRAINT "feedback_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."gcash_notif"
    ADD CONSTRAINT "gcash_notif_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."incoming_webhook_events"
    ADD CONSTRAINT "incoming_webhook_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."manual_payments"
    ADD CONSTRAINT "manual_payments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."manual_referral_assignments"
    ADD CONSTRAINT "manual_referral_assignments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."notification_outbox"
    ADD CONSTRAINT "notification_outbox_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."otp_pricing"
    ADD CONSTRAINT "otp_pricing_app_name_key" UNIQUE ("app_name");



ALTER TABLE ONLY "public"."otp_pricing"
    ADD CONSTRAINT "otp_pricing_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."otp_session_extensions"
    ADD CONSTRAINT "otp_session_extensions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."otp_session_queue"
    ADD CONSTRAINT "otp_session_queue_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."otp_sessions"
    ADD CONSTRAINT "otp_sessions_demo_token_key" UNIQUE ("demo_token");



ALTER TABLE ONLY "public"."otp_sessions"
    ADD CONSTRAINT "otp_sessions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."payment_method_transactions"
    ADD CONSTRAINT "payment_method_transactions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."payment_methods"
    ADD CONSTRAINT "payment_methods_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."rate_limit_config"
    ADD CONSTRAINT "rate_limit_config_endpoint_path_key" UNIQUE ("endpoint_path");



ALTER TABLE ONLY "public"."rate_limit_config"
    ADD CONSTRAINT "rate_limit_config_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."rate_limit_tracking"
    ADD CONSTRAINT "rate_limit_tracking_identifier_endpoint_path_key" UNIQUE ("identifier", "endpoint_path");



ALTER TABLE ONLY "public"."rate_limit_tracking"
    ADD CONSTRAINT "rate_limit_tracking_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."referral_config"
    ADD CONSTRAINT "referral_config_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."referral_earnings"
    ADD CONSTRAINT "referral_earnings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."referral_milestones"
    ADD CONSTRAINT "referral_milestones_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."referral_milestones"
    ADD CONSTRAINT "referral_milestones_referrer_id_milestone_level_key" UNIQUE ("referrer_id", "milestone_level");



ALTER TABLE ONLY "public"."review_replies"
    ADD CONSTRAINT "review_replies_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."reviews"
    ADD CONSTRAINT "reviews_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."scheduler_leases"
    ADD CONSTRAINT "scheduler_leases_pkey" PRIMARY KEY ("lease_key");



ALTER TABLE ONLY "public"."sim_app_usage"
    ADD CONSTRAINT "sim_app_usage_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sim_app_usage"
    ADD CONSTRAINT "sim_app_usage_sim_number_app_name_key" UNIQUE ("sim_number", "app_name");



ALTER TABLE ONLY "public"."sim_failure_records"
    ADD CONSTRAINT "sim_failure_records_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sim_failure_records"
    ADD CONSTRAINT "sim_failure_records_unique_session_sim_type" UNIQUE ("session_id", "sim_id", "failure_type");



COMMENT ON CONSTRAINT "sim_failure_records_unique_session_sim_type" ON "public"."sim_failure_records" IS 'Ensures each SIM can only be counted once per session per failure type (prevents double-counting when same SIM is changed multiple times)';



ALTER TABLE ONLY "public"."sim_failure_streaks"
    ADD CONSTRAINT "sim_failure_streaks_pkey" PRIMARY KEY ("sim_id");



ALTER TABLE ONLY "public"."sim_group_members"
    ADD CONSTRAINT "sim_group_members_pkey" PRIMARY KEY ("group_id", "sim_number");



ALTER TABLE ONLY "public"."sim_group_members"
    ADD CONSTRAINT "sim_group_members_sim_number_unique" UNIQUE ("sim_number");



ALTER TABLE ONLY "public"."sim_groups"
    ADD CONSTRAINT "sim_groups_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sim_history"
    ADD CONSTRAINT "sim_history_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sim_stats"
    ADD CONSTRAINT "sim_stats_pkey" PRIMARY KEY ("sim_id");



ALTER TABLE ONLY "public"."sims"
    ADD CONSTRAINT "sims_number_key" UNIQUE ("number");



ALTER TABLE ONLY "public"."sims"
    ADD CONSTRAINT "sims_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sms_messages"
    ADD CONSTRAINT "sms_messages_id_uuid_key" UNIQUE ("id_uuid");



ALTER TABLE ONLY "public"."sms_messages"
    ADD CONSTRAINT "sms_messages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."system_logs"
    ADD CONSTRAINT "system_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."telegram_referral_invite_events"
    ADD CONSTRAINT "telegram_referral_invite_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."telegram_session_warning_events"
    ADD CONSTRAINT "telegram_session_warning_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."telegram_sms_message_push_events"
    ADD CONSTRAINT "telegram_sms_message_push_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_chat_links"
    ADD CONSTRAINT "user_chat_links_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_push_subscriptions"
    ADD CONSTRAINT "user_push_subscriptions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_settings"
    ADD CONSTRAINT "user_settings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_settings"
    ADD CONSTRAINT "user_settings_user_id_key" UNIQUE ("user_id");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_email_key" UNIQUE ("email");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_referral_code_key" UNIQUE ("referral_code");



ALTER TABLE ONLY "public"."voucher_usage"
    ADD CONSTRAINT "voucher_usage_payment_token_key" UNIQUE ("payment_token");



ALTER TABLE ONLY "public"."voucher_usage"
    ADD CONSTRAINT "voucher_usage_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."vouchers"
    ADD CONSTRAINT "vouchers_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."vouchers"
    ADD CONSTRAINT "vouchers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."wallet_topups"
    ADD CONSTRAINT "wallet_topups_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."wallet_transactions"
    ADD CONSTRAINT "wallet_transactions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."withdrawal_payment_methods"
    ADD CONSTRAINT "withdrawal_payment_methods_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."withdrawal_payment_methods"
    ADD CONSTRAINT "withdrawal_payment_methods_pkey" PRIMARY KEY ("id");



CREATE INDEX "daily_analytics_snapshots_captured_at_idx" ON "public"."daily_analytics_snapshots" USING "btree" ("captured_at" DESC);



CREATE INDEX "daily_analytics_snapshots_snapshot_date_idx" ON "public"."daily_analytics_snapshots" USING "btree" ("snapshot_date" DESC);



CREATE INDEX "idx_agent_applications_created_at" ON "public"."agent_applications" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_agent_applications_email" ON "public"."agent_applications" USING "btree" ("email");



CREATE INDEX "idx_agent_applications_phone" ON "public"."agent_applications" USING "btree" ("phone");



CREATE INDEX "idx_agent_applications_status" ON "public"."agent_applications" USING "btree" ("status");



CREATE INDEX "idx_agent_claims_user_status" ON "public"."agent_claims" USING "btree" ("user_id", "status");



CREATE INDEX "idx_agent_commission_config_active" ON "public"."agent_commission_config" USING "btree" ("is_active") WHERE ("is_active" = true);



CREATE UNIQUE INDEX "idx_agent_commission_config_active_type" ON "public"."agent_commission_config" USING "btree" ("is_agent_direct") WHERE ("is_active" = true);



CREATE INDEX "idx_agent_commission_overrides_expires" ON "public"."agent_commission_overrides" USING "btree" ("expires_at") WHERE (("expires_at" IS NOT NULL) AND ("is_active" = true));



CREATE INDEX "idx_agent_commission_overrides_user" ON "public"."agent_commission_overrides" USING "btree" ("user_id");



CREATE UNIQUE INDEX "idx_agent_commission_overrides_user_active" ON "public"."agent_commission_overrides" USING "btree" ("user_id") WHERE ("is_active" = true);



CREATE INDEX "idx_agent_invite_earnings_invited_agent" ON "public"."agent_invite_earnings" USING "btree" ("invited_agent_id");



CREATE INDEX "idx_agent_invite_earnings_inviter_status" ON "public"."agent_invite_earnings" USING "btree" ("inviter_id", "status");



CREATE UNIQUE INDEX "idx_agent_invite_earnings_unique_tx" ON "public"."agent_invite_earnings" USING "btree" ("agent_transaction_id");



CREATE INDEX "idx_agent_transactions_agent_direct" ON "public"."agent_transactions" USING "btree" ("user_id", "agent_direct", "status", "created_at");



CREATE INDEX "idx_agent_transactions_available_at" ON "public"."agent_transactions" USING "btree" ("status", "available_at");



CREATE INDEX "idx_agent_transactions_sim_usage" ON "public"."agent_transactions" USING "btree" ("sim_app_usage_id");



CREATE UNIQUE INDEX "idx_agent_transactions_unique_sim_app_usage_id" ON "public"."agent_transactions" USING "btree" ("sim_app_usage_id") WHERE ("sim_app_usage_id" IS NOT NULL);



CREATE UNIQUE INDEX "idx_agent_transactions_unique_usage" ON "public"."agent_transactions" USING "btree" ("sim_app_usage_id") WHERE ("sim_app_usage_id" IS NOT NULL);



CREATE INDEX "idx_agent_transactions_user_status" ON "public"."agent_transactions" USING "btree" ("user_id", "status");



CREATE INDEX "idx_announcement_target_device" ON "public"."announcement" USING "btree" ("target_device_id");



CREATE INDEX "idx_announcement_target_email" ON "public"."announcement" USING "btree" ("target_email");



CREATE INDEX "idx_chat_bot_states_updated_at" ON "public"."chat_bot_states" USING "btree" ("updated_at");



CREATE INDEX "idx_chat_link_codes_expires_at" ON "public"."chat_link_codes" USING "btree" ("expires_at");



CREATE INDEX "idx_chat_link_codes_user_provider" ON "public"."chat_link_codes" USING "btree" ("user_id", "provider");



CREATE INDEX "idx_contact_submissions_created_at" ON "public"."contact_submissions" USING "btree" ("created_at");



CREATE INDEX "idx_contact_submissions_email" ON "public"."contact_submissions" USING "btree" ("email");



CREATE INDEX "idx_contact_submissions_priority" ON "public"."contact_submissions" USING "btree" ("priority");



CREATE INDEX "idx_contact_submissions_status" ON "public"."contact_submissions" USING "btree" ("status");



CREATE INDEX "idx_devices_user_id" ON "public"."devices" USING "btree" ("user_id");



CREATE INDEX "idx_feedback_created_at" ON "public"."feedback" USING "btree" ("created_at");



CREATE INDEX "idx_feedback_status" ON "public"."feedback" USING "btree" ("status");



CREATE INDEX "idx_gcash_notif_amount" ON "public"."gcash_notif" USING "btree" ("amount");



CREATE INDEX "idx_gcash_notif_created_at_gmt8" ON "public"."gcash_notif" USING "btree" ("created_at_gmt8");



CREATE INDEX "idx_gcash_notif_matched_topup_id" ON "public"."gcash_notif" USING "btree" ("matched_topup_id") WHERE ("matched_topup_id" IS NOT NULL);



CREATE INDEX "idx_gcash_notif_occurred_at" ON "public"."gcash_notif" USING "btree" ("occurred_at");



CREATE INDEX "idx_gcash_notif_occurred_at_gmt8" ON "public"."gcash_notif" USING "btree" ("occurred_at_gmt8");



CREATE INDEX "idx_gcash_notif_sender_number" ON "public"."gcash_notif" USING "btree" ("sender_number");



CREATE INDEX "idx_gcash_notif_status" ON "public"."gcash_notif" USING "btree" ("status");



CREATE INDEX "idx_gcash_status_occurred_at" ON "public"."gcash_notif" USING "btree" ("status", "occurred_at");



CREATE INDEX "idx_incoming_webhook_events_created_at" ON "public"."incoming_webhook_events" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_manual_amount" ON "public"."manual_payments" USING "btree" ("amount");



CREATE INDEX "idx_manual_ocr_amount" ON "public"."manual_payments" USING "btree" ("ocr_amount");



CREATE INDEX "idx_manual_payments_agent_direct" ON "public"."manual_payments" USING "btree" ("agent_user_id", "agent_direct", "status", "created_at");



CREATE INDEX "idx_manual_payments_approved_at_gmt8" ON "public"."manual_payments" USING "btree" ("approved_at_gmt8");



CREATE INDEX "idx_manual_payments_created_at_gmt8" ON "public"."manual_payments" USING "btree" ("created_at_gmt8");



CREATE INDEX "idx_manual_payments_status" ON "public"."manual_payments" USING "btree" ("status");



CREATE INDEX "idx_manual_payments_status_user_email" ON "public"."manual_payments" USING "btree" ("status", "user_email");



CREATE INDEX "idx_manual_payments_user_email" ON "public"."manual_payments" USING "btree" ("user_email");



CREATE INDEX "idx_manual_payments_user_id" ON "public"."manual_payments" USING "btree" ("user_id");



CREATE INDEX "idx_manual_referral_assigned_by" ON "public"."manual_referral_assignments" USING "btree" ("assigned_by");



CREATE INDEX "idx_manual_referral_created_at" ON "public"."manual_referral_assignments" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_manual_referral_referred_user" ON "public"."manual_referral_assignments" USING "btree" ("referred_user_id");



CREATE INDEX "idx_manual_referral_referrer" ON "public"."manual_referral_assignments" USING "btree" ("referrer_id");



CREATE INDEX "idx_manual_sender_number" ON "public"."manual_payments" USING "btree" ("sender_number");



CREATE INDEX "idx_manual_status_created_at" ON "public"."manual_payments" USING "btree" ("status", "created_at");



CREATE INDEX "idx_notification_outbox_pending" ON "public"."notification_outbox" USING "btree" ("processed_at", "created_at") WHERE ("processed_at" IS NULL);



CREATE UNIQUE INDEX "idx_notification_outbox_unique_event" ON "public"."notification_outbox" USING "btree" ("event_type", "record_id");



CREATE INDEX "idx_otp_pricing_allowed_carriers" ON "public"."otp_pricing" USING "gin" ("allowed_carriers") WHERE ("allowed_carriers" IS NOT NULL);



CREATE UNIQUE INDEX "idx_otp_pricing_app_name_lower" ON "public"."otp_pricing" USING "btree" ("lower"("app_name"));



CREATE INDEX "idx_otp_pricing_discount" ON "public"."otp_pricing" USING "btree" ("discount_percentage") WHERE (("discount_percentage" IS NOT NULL) AND ("discount_percentage" > (0)::numeric));



CREATE INDEX "idx_otp_pricing_max_quantity" ON "public"."otp_pricing" USING "btree" ("max_quantity") WHERE ("max_quantity" IS NOT NULL);



CREATE UNIQUE INDEX "idx_otp_session_queue_payment_unique" ON "public"."otp_session_queue" USING "btree" ("payment_id");



CREATE INDEX "idx_otp_session_queue_unprocessed" ON "public"."otp_session_queue" USING "btree" ("processed", "created_at") WHERE (NOT "processed");



CREATE INDEX "idx_otp_sessions_activated_at_gmt8" ON "public"."otp_sessions" USING "btree" ("activated_at_gmt8");



CREATE INDEX "idx_otp_sessions_agent_user" ON "public"."otp_sessions" USING "btree" ("agent_user_id", "agent_direct", "status", "created_at");



CREATE INDEX "idx_otp_sessions_commission_processed" ON "public"."otp_sessions" USING "btree" ("commission_processed") WHERE ("commission_processed" = false);



CREATE INDEX "idx_otp_sessions_created_at_gmt8" ON "public"."otp_sessions" USING "btree" ("created_at_gmt8");



CREATE INDEX "idx_otp_sessions_demo_token" ON "public"."otp_sessions" USING "btree" ("demo_token") WHERE ("is_demo" = true);



CREATE INDEX "idx_otp_sessions_direct_public" ON "public"."otp_sessions" USING "btree" ("direct_public", "status", "created_at");



CREATE INDEX "idx_otp_sessions_expires_at" ON "public"."otp_sessions" USING "btree" ("expires_at");



CREATE INDEX "idx_otp_sessions_expires_at_gmt8" ON "public"."otp_sessions" USING "btree" ("expires_at_gmt8");



CREATE INDEX "idx_otp_sessions_message_count" ON "public"."otp_sessions" USING "btree" ("message_count");



CREATE INDEX "idx_otp_sessions_original_app" ON "public"."otp_sessions" USING "btree" ("original_app");



CREATE INDEX "idx_otp_sessions_previous_sim" ON "public"."otp_sessions" USING "btree" ("previous_sim_number");



CREATE UNIQUE INDEX "idx_otp_sessions_public_token" ON "public"."otp_sessions" USING "btree" ("public_token") WHERE ("public_token" IS NOT NULL);



CREATE INDEX "idx_otp_sessions_retry_count" ON "public"."otp_sessions" USING "btree" ("retry_count");



CREATE INDEX "idx_otp_sessions_status" ON "public"."otp_sessions" USING "btree" ("status");



CREATE INDEX "idx_otp_sessions_status_expires" ON "public"."otp_sessions" USING "btree" ("status", "expires_at");



CREATE INDEX "idx_otp_sessions_status_user_email" ON "public"."otp_sessions" USING "btree" ("status", "user_email");



CREATE INDEX "idx_otp_sessions_user_email" ON "public"."otp_sessions" USING "btree" ("user_email");



CREATE INDEX "idx_otp_sessions_user_id_user_email" ON "public"."otp_sessions" USING "btree" ("user_id", "user_email");



CREATE INDEX "idx_otp_sessions_user_status" ON "public"."otp_sessions" USING "btree" ("user_id", "status");



CREATE INDEX "idx_payment_method_transactions_payment_method_id" ON "public"."payment_method_transactions" USING "btree" ("payment_method_id", "created_at" DESC);



CREATE UNIQUE INDEX "idx_payment_method_transactions_unique_source" ON "public"."payment_method_transactions" USING "btree" ("source_table", "source_id", "direction");



CREATE INDEX "idx_rate_limit_config_endpoint" ON "public"."rate_limit_config" USING "btree" ("endpoint_path") WHERE ("is_active" = true);



CREATE INDEX "idx_rate_limit_tracking_lookup" ON "public"."rate_limit_tracking" USING "btree" ("identifier", "endpoint_path");



CREATE INDEX "idx_rate_limit_tracking_reset_time" ON "public"."rate_limit_tracking" USING "btree" ("reset_time");



CREATE INDEX "idx_referral_config_active" ON "public"."referral_config" USING "btree" ("is_active") WHERE ("is_active" = true);



CREATE INDEX "idx_referral_earnings_created_at" ON "public"."referral_earnings" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_referral_earnings_otp_session_id" ON "public"."referral_earnings" USING "btree" ("otp_session_id");



CREATE INDEX "idx_referral_earnings_referred_user_id" ON "public"."referral_earnings" USING "btree" ("referred_user_id");



CREATE INDEX "idx_referral_earnings_referrer_id" ON "public"."referral_earnings" USING "btree" ("referrer_id");



CREATE INDEX "idx_referral_earnings_referrer_status" ON "public"."referral_earnings" USING "btree" ("referrer_id", "status");



CREATE INDEX "idx_referral_earnings_status" ON "public"."referral_earnings" USING "btree" ("status");



CREATE UNIQUE INDEX "idx_referral_earnings_unique_otp" ON "public"."referral_earnings" USING "btree" ("otp_session_id", "referrer_id");



CREATE INDEX "idx_referral_milestones_referrer_id" ON "public"."referral_milestones" USING "btree" ("referrer_id");



CREATE INDEX "idx_referral_milestones_referrer_level" ON "public"."referral_milestones" USING "btree" ("referrer_id", "milestone_level");



CREATE INDEX "idx_referral_milestones_status" ON "public"."referral_milestones" USING "btree" ("status");



CREATE INDEX "idx_review_replies_created_at" ON "public"."review_replies" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_review_replies_review_id" ON "public"."review_replies" USING "btree" ("review_id");



CREATE INDEX "idx_reviews_app_name" ON "public"."reviews" USING "btree" ("app_name");



CREATE INDEX "idx_reviews_created_at" ON "public"."reviews" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_reviews_is_displayed" ON "public"."reviews" USING "btree" ("is_displayed") WHERE ("is_displayed" = true);



CREATE INDEX "idx_reviews_otp_session_id" ON "public"."reviews" USING "btree" ("otp_session_id") WHERE ("otp_session_id" IS NOT NULL);



CREATE INDEX "idx_reviews_rating" ON "public"."reviews" USING "btree" ("rating");



CREATE INDEX "idx_reviews_user_id" ON "public"."reviews" USING "btree" ("user_id");



CREATE INDEX "idx_sim_app_usage_agent" ON "public"."sim_app_usage" USING "btree" ("agent_user_id");



CREATE INDEX "idx_sim_app_usage_agent_direct" ON "public"."sim_app_usage" USING "btree" ("agent_direct", "agent_user_id", "app_name");



CREATE INDEX "idx_sim_app_usage_sim_app" ON "public"."sim_app_usage" USING "btree" ("sim_number", "app_name");



CREATE UNIQUE INDEX "idx_sim_app_usage_unique" ON "public"."sim_app_usage" USING "btree" ("sim_number", "app_name");



CREATE INDEX "idx_sim_app_usage_used_at_gmt8" ON "public"."sim_app_usage" USING "btree" ("used_at_gmt8");



CREATE INDEX "idx_sim_failure_records_session_id" ON "public"."sim_failure_records" USING "btree" ("session_id");



CREATE INDEX "idx_sim_failure_records_sim_id" ON "public"."sim_failure_records" USING "btree" ("sim_id");



CREATE INDEX "idx_sim_failure_records_type" ON "public"."sim_failure_records" USING "btree" ("failure_type");



CREATE INDEX "idx_sim_failure_streaks_updated_at" ON "public"."sim_failure_streaks" USING "btree" ("updated_at" DESC);



CREATE INDEX "idx_sim_group_members_group_id" ON "public"."sim_group_members" USING "btree" ("group_id");



CREATE INDEX "idx_sim_group_members_sim_number" ON "public"."sim_group_members" USING "btree" ("sim_number");



CREATE INDEX "idx_sim_history_device_id" ON "public"."sim_history" USING "btree" ("device_id");



CREATE INDEX "idx_sim_history_sim_number" ON "public"."sim_history" USING "btree" ("sim_number");



CREATE INDEX "idx_sim_stats_updated_at" ON "public"."sim_stats" USING "btree" ("updated_at" DESC);



CREATE INDEX "idx_sims_completed_desc" ON "public"."sims" USING "btree" ("total_completed" DESC);



CREATE INDEX "idx_sims_device_id" ON "public"."sims" USING "btree" ("device_id");



CREATE INDEX "idx_sims_failed_asc" ON "public"."sims" USING "btree" ("total_failed");



CREATE INDEX "idx_sims_number" ON "public"."sims" USING "btree" ("number");



CREATE INDEX "idx_sims_paused_at" ON "public"."sims" USING "btree" ("paused_at" DESC);



CREATE INDEX "idx_sims_paused_reason" ON "public"."sims" USING "btree" ("paused_reason");



CREATE INDEX "idx_sims_status" ON "public"."sims" USING "btree" ("status");



CREATE INDEX "idx_sims_success_rate_desc" ON "public"."sims" USING "btree" ("success_rate" DESC);



CREATE INDEX "idx_sims_total_completed" ON "public"."sims" USING "btree" ("total_completed" DESC);



CREATE INDEX "idx_sims_total_failed" ON "public"."sims" USING "btree" ("total_failed" DESC);



CREATE INDEX "idx_sims_type_number" ON "public"."sims" USING "btree" ("type", "number");



CREATE INDEX "idx_sms_messages_sim_timestamp_gmt8" ON "public"."sms_messages" USING "btree" ("sim_number", "timestamp_gmt8" DESC);



CREATE INDEX "idx_sms_messages_sim_ts" ON "public"."sms_messages" USING "btree" ("sim_number", "timestamp" DESC);



CREATE INDEX "idx_sms_messages_sync_status" ON "public"."sms_messages" USING "btree" ("sync_status");



CREATE INDEX "idx_sms_messages_timestamp_gmt8" ON "public"."sms_messages" USING "btree" ("timestamp_gmt8");



CREATE INDEX "idx_sms_sim_number" ON "public"."sms_messages" USING "btree" ("sim_number");



CREATE INDEX "idx_system_logs_level" ON "public"."system_logs" USING "btree" ("level");



CREATE INDEX "idx_system_logs_timestamp" ON "public"."system_logs" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_user_chat_links_user_provider" ON "public"."user_chat_links" USING "btree" ("user_id", "provider");



CREATE INDEX "idx_users_archived" ON "public"."users" USING "btree" ("is_archived") WHERE ("is_archived" = false);



CREATE INDEX "idx_users_priority_desc" ON "public"."users" USING "btree" ("priority" DESC);



CREATE INDEX "idx_users_referral_code" ON "public"."users" USING "btree" ("referral_code") WHERE ("referral_code" IS NOT NULL);



CREATE INDEX "idx_users_referred_by" ON "public"."users" USING "btree" ("referred_by") WHERE ("referred_by" IS NOT NULL);



CREATE INDEX "idx_users_used_sim_numbers" ON "public"."users" USING "gin" ("used_sim_numbers");



CREATE INDEX "idx_voucher_usage_payment_token" ON "public"."voucher_usage" USING "btree" ("payment_token") WHERE ("payment_token" IS NOT NULL);



CREATE INDEX "idx_voucher_usage_token_expires" ON "public"."voucher_usage" USING "btree" ("payment_token_expires_at") WHERE ("payment_token_expires_at" IS NOT NULL);



CREATE INDEX "idx_voucher_usage_user_id" ON "public"."voucher_usage" USING "btree" ("user_id");



CREATE INDEX "idx_voucher_usage_voucher_id" ON "public"."voucher_usage" USING "btree" ("voucher_id");



CREATE INDEX "idx_wallet_topups_created_at" ON "public"."wallet_topups" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_wallet_topups_matched_notification_id" ON "public"."wallet_topups" USING "btree" ("matched_notification_id") WHERE ("matched_notification_id" IS NOT NULL);



CREATE INDEX "idx_wallet_topups_sender_number" ON "public"."wallet_topups" USING "btree" ("sender_number");



CREATE INDEX "idx_wallet_topups_status" ON "public"."wallet_topups" USING "btree" ("status");



CREATE INDEX "idx_wallet_topups_user_id" ON "public"."wallet_topups" USING "btree" ("user_id");



CREATE INDEX "idx_wallet_transactions_created_at" ON "public"."wallet_transactions" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_wallet_transactions_status" ON "public"."wallet_transactions" USING "btree" ("status");



CREATE INDEX "idx_wallet_transactions_type" ON "public"."wallet_transactions" USING "btree" ("type");



CREATE UNIQUE INDEX "idx_wallet_transactions_unique_milestone" ON "public"."wallet_transactions" USING "btree" ("referral_milestone_id") WHERE (("referral_milestone_id" IS NOT NULL) AND ("type" = 'milestone'::"text") AND ("status" = 'success'::"text"));



COMMENT ON INDEX "public"."idx_wallet_transactions_unique_milestone" IS 'Prevents duplicate milestone bonus transactions for the same milestone. Only one successful milestone transaction per referral_milestone_id is allowed.';



CREATE INDEX "idx_wallet_transactions_user_created" ON "public"."wallet_transactions" USING "btree" ("user_id", "created_at" DESC);



CREATE INDEX "idx_wallet_transactions_user_id" ON "public"."wallet_transactions" USING "btree" ("user_id");



CREATE INDEX "idx_wallet_transactions_withdrawal_method" ON "public"."wallet_transactions" USING "btree" ("withdrawal_payment_method_id") WHERE ("withdrawal_payment_method_id" IS NOT NULL);



CREATE INDEX "idx_wallet_transactions_withdrawal_receipt" ON "public"."wallet_transactions" USING "btree" ("withdrawal_receipt_url") WHERE ("withdrawal_receipt_url" IS NOT NULL);



CREATE INDEX "idx_withdrawal_payment_methods_active" ON "public"."withdrawal_payment_methods" USING "btree" ("is_active", "sort_order");



CREATE INDEX "idx_withdrawal_payment_methods_name" ON "public"."withdrawal_payment_methods" USING "btree" ("name");



CREATE INDEX "otp_session_extensions_session_id_idx" ON "public"."otp_session_extensions" USING "btree" ("session_id");



CREATE INDEX "otp_session_extensions_user_id_idx" ON "public"."otp_session_extensions" USING "btree" ("user_id");



CREATE INDEX "otp_sessions_activated_via_idx" ON "public"."otp_sessions" USING "btree" ("activated_via");



CREATE INDEX "telegram_referral_invite_events_delivered_at_idx" ON "public"."telegram_referral_invite_events" USING "btree" ("delivered_at");



CREATE INDEX "telegram_referral_invite_events_referrer_id_idx" ON "public"."telegram_referral_invite_events" USING "btree" ("referrer_id");



CREATE UNIQUE INDEX "telegram_referral_invite_events_unique" ON "public"."telegram_referral_invite_events" USING "btree" ("provider", "referred_user_id");



CREATE INDEX "telegram_session_warning_events_session_id_idx" ON "public"."telegram_session_warning_events" USING "btree" ("session_id");



CREATE UNIQUE INDEX "telegram_session_warning_events_unique" ON "public"."telegram_session_warning_events" USING "btree" ("provider", "session_id", "threshold_seconds");



CREATE INDEX "telegram_sms_message_push_events_session_id_idx" ON "public"."telegram_sms_message_push_events" USING "btree" ("session_id");



CREATE UNIQUE INDEX "telegram_sms_message_push_events_unique" ON "public"."telegram_sms_message_push_events" USING "btree" ("provider", "sms_message_id");



CREATE UNIQUE INDEX "uniq_christmas_2025_snapshot_once" ON "public"."christmas_2025_uptime_ranking_snapshot" USING "btree" ("user_id");



CREATE UNIQUE INDEX "uq_chat_bot_states_provider_chat_id" ON "public"."chat_bot_states" USING "btree" ("provider", "chat_id");



CREATE UNIQUE INDEX "uq_chat_link_codes_provider_code" ON "public"."chat_link_codes" USING "btree" ("provider", "code");



CREATE UNIQUE INDEX "uq_user_chat_links_provider_chat_id" ON "public"."user_chat_links" USING "btree" ("provider", "chat_id");



CREATE UNIQUE INDEX "uq_user_chat_links_provider_user_id" ON "public"."user_chat_links" USING "btree" ("provider", "user_id");



CREATE UNIQUE INDEX "user_push_subscriptions_endpoint_key" ON "public"."user_push_subscriptions" USING "btree" ("endpoint");



CREATE INDEX "user_push_subscriptions_user_id_idx" ON "public"."user_push_subscriptions" USING "btree" ("user_id");



CREATE INDEX "users_signup_source_idx" ON "public"."users" USING "btree" ("signup_source");



CREATE OR REPLACE VIEW "public"."v_vouchers_with_usage" AS
 SELECT "v"."id",
    "v"."code",
    "v"."balance",
    "v"."max_uses",
    "v"."used_count",
    COALESCE("sum"("u"."amount_used"), (0)::numeric) AS "total_used",
    ("v"."balance" - COALESCE("sum"("u"."amount_used"), (0)::numeric)) AS "remaining_balance",
    "v"."active",
    "v"."created_at"
   FROM ("public"."vouchers" "v"
     LEFT JOIN "public"."voucher_usage" "u" ON (("u"."voucher_id" = "v"."id")))
  GROUP BY "v"."id";



CREATE OR REPLACE TRIGGER "auto_link_sms_trigger" AFTER INSERT ON "public"."sms_messages" FOR EACH ROW EXECUTE FUNCTION "public"."trigger_auto_link_sms"();



CREATE OR REPLACE TRIGGER "trg_accumulate_device_uptime" BEFORE UPDATE OF "last_heartbeat" ON "public"."devices" FOR EACH ROW EXECUTE FUNCTION "public"."fn_accumulate_device_uptime"();



CREATE OR REPLACE TRIGGER "trg_accumulate_sim_uptime" BEFORE UPDATE OF "last_heartbeat" ON "public"."sims" FOR EACH ROW EXECUTE FUNCTION "public"."fn_accumulate_sim_uptime"();



CREATE OR REPLACE TRIGGER "trg_apply_sim_failure_streak_on_failure_record" AFTER INSERT ON "public"."sim_failure_records" FOR EACH ROW EXECUTE FUNCTION "public"."apply_sim_failure_streak_on_failure_record"();



CREATE OR REPLACE TRIGGER "trg_auto_link_sms_to_session" AFTER INSERT OR UPDATE OF "sms_message_id" ON "public"."otp_sessions" FOR EACH ROW WHEN (("new"."sms_message_id" IS NOT NULL)) EXECUTE FUNCTION "public"."auto_link_sms_to_session"();



CREATE OR REPLACE TRIGGER "trg_clear_expires_at_if_pending" BEFORE INSERT ON "public"."otp_sessions" FOR EACH ROW EXECUTE FUNCTION "public"."clear_expires_at_if_pending"();



CREATE OR REPLACE TRIGGER "trg_clear_expires_at_if_pending_insert" BEFORE INSERT ON "public"."otp_sessions" FOR EACH ROW EXECUTE FUNCTION "public"."clear_expires_at_if_pending"();



CREATE OR REPLACE TRIGGER "trg_clear_expires_at_if_pending_update" BEFORE UPDATE OF "status", "expires_at" ON "public"."otp_sessions" FOR EACH ROW EXECUTE FUNCTION "public"."clear_expires_at_if_pending"();



CREATE OR REPLACE TRIGGER "trg_create_agent_transaction_from_usage" AFTER INSERT OR UPDATE OF "agent_user_id", "gross_amount", "agent_share", "site_share" ON "public"."sim_app_usage" FOR EACH ROW EXECUTE FUNCTION "public"."create_agent_transaction_from_usage"();



CREATE OR REPLACE TRIGGER "trg_detect_carrier" AFTER INSERT OR UPDATE OF "number" ON "public"."sims" FOR EACH ROW EXECUTE FUNCTION "public"."detect_carrier_from_number_after"();



CREATE OR REPLACE TRIGGER "trg_enqueue_manual_payment_auto_approved" AFTER INSERT OR UPDATE OF "status" ON "public"."manual_payments" FOR EACH ROW EXECUTE FUNCTION "public"."enqueue_manual_payment_auto_approved"();



CREATE OR REPLACE TRIGGER "trg_enqueue_otp_on_approval" AFTER UPDATE OF "status" ON "public"."manual_payments" FOR EACH ROW EXECUTE FUNCTION "public"."enqueue_otp_on_approval"();



CREATE OR REPLACE TRIGGER "trg_enqueue_telegram_referral_invite_event" AFTER INSERT ON "public"."users" FOR EACH ROW EXECUTE FUNCTION "public"."enqueue_telegram_referral_invite_event"();



CREATE OR REPLACE TRIGGER "trg_enqueue_wallet_topup_auto_approved" AFTER INSERT OR UPDATE OF "status" ON "public"."wallet_topups" FOR EACH ROW EXECUTE FUNCTION "public"."enqueue_wallet_topup_auto_approved"();



CREATE OR REPLACE TRIGGER "trg_fn_update_device_status_from_last_seen" AFTER INSERT OR UPDATE OF "last_seen" ON "public"."devices" FOR EACH ROW EXECUTE FUNCTION "public"."fn_update_device_status_from_last_seen"();



CREATE OR REPLACE TRIGGER "trg_handle_expired_session_with_messages" BEFORE UPDATE OF "status" ON "public"."otp_sessions" FOR EACH ROW WHEN ((("new"."status" = 'expired'::"text") AND (("old"."status" IS NULL) OR ("old"."status" <> 'expired'::"text")))) EXECUTE FUNCTION "public"."handle_expired_session_with_messages"();



CREATE OR REPLACE TRIGGER "trg_manual_payments_apply_payment_method_balance" AFTER INSERT OR UPDATE OF "status" ON "public"."manual_payments" FOR EACH ROW EXECUTE FUNCTION "public"."trg_manual_payments_apply_payment_method_balance"();



CREATE OR REPLACE TRIGGER "trg_match_from_gcash" AFTER INSERT ON "public"."gcash_notif" FOR EACH ROW EXECUTE FUNCTION "public"."match_from_gcash"();



CREATE OR REPLACE TRIGGER "trg_match_from_gcash_update" AFTER UPDATE ON "public"."gcash_notif" FOR EACH ROW WHEN ((("new"."status" = 'RECEIVED'::"text") AND ("new"."matched_payment_id" IS NULL))) EXECUTE FUNCTION "public"."match_from_gcash"();



CREATE OR REPLACE TRIGGER "trg_match_from_manual" AFTER INSERT ON "public"."manual_payments" FOR EACH ROW EXECUTE FUNCTION "public"."match_from_manual"();



CREATE OR REPLACE TRIGGER "trg_match_gcash_to_wallet_topup" AFTER INSERT ON "public"."gcash_notif" FOR EACH ROW WHEN (("new"."status" = 'RECEIVED'::"text")) EXECUTE FUNCTION "public"."match_gcash_notif_to_wallet_topup"();



CREATE OR REPLACE TRIGGER "trg_match_wallet_topup_gcash" BEFORE INSERT OR UPDATE ON "public"."wallet_topups" FOR EACH ROW WHEN (("new"."status" = 'pending'::"text")) EXECUTE FUNCTION "public"."match_wallet_topup_with_gcash_notif"();



CREATE OR REPLACE TRIGGER "trg_pause_sim_on_excessive_excluded_apps" BEFORE UPDATE OF "excluded_apps" ON "public"."sims" FOR EACH ROW EXECUTE FUNCTION "public"."pause_sim_on_excessive_excluded_apps"();



CREATE OR REPLACE TRIGGER "trg_process_agent_earnings_on_otp_complete" AFTER UPDATE OF "status" ON "public"."otp_sessions" FOR EACH ROW WHEN ((("new"."status" = 'completed'::"text") AND (("old"."status" IS NULL) OR ("old"."status" <> 'completed'::"text")))) EXECUTE FUNCTION "public"."process_agent_earnings_on_otp_complete"();



CREATE OR REPLACE TRIGGER "trg_record_sim_completion_from_usage" AFTER INSERT ON "public"."sim_app_usage" FOR EACH ROW EXECUTE FUNCTION "public"."record_sim_completion_from_usage"();



CREATE OR REPLACE TRIGGER "trg_record_sim_failure_on_expire" AFTER UPDATE OF "status" ON "public"."otp_sessions" FOR EACH ROW WHEN ((("new"."status" = 'expired'::"text") AND (("old"."status" IS NULL) OR ("old"."status" <> 'expired'::"text")))) EXECUTE FUNCTION "public"."record_sim_failure_on_expire"();



CREATE OR REPLACE TRIGGER "trg_reset_sim_failure_streak_on_success_usage" AFTER INSERT ON "public"."sim_app_usage" FOR EACH ROW EXECUTE FUNCTION "public"."reset_sim_failure_streak_on_success_usage"();



CREATE OR REPLACE TRIGGER "trg_sync_manual_payment_user_email_insert" BEFORE INSERT ON "public"."manual_payments" FOR EACH ROW EXECUTE FUNCTION "public"."sync_manual_payment_user_email"();



CREATE OR REPLACE TRIGGER "trg_sync_manual_payment_user_email_update" BEFORE UPDATE OF "user_id" ON "public"."manual_payments" FOR EACH ROW WHEN (("old"."user_id" IS DISTINCT FROM "new"."user_id")) EXECUTE FUNCTION "public"."sync_manual_payment_user_email"();



CREATE OR REPLACE TRIGGER "trg_sync_otp_session_user_email_insert" BEFORE INSERT ON "public"."otp_sessions" FOR EACH ROW EXECUTE FUNCTION "public"."sync_otp_session_user_email"();



CREATE OR REPLACE TRIGGER "trg_sync_otp_session_user_email_update" BEFORE UPDATE OF "user_id" ON "public"."otp_sessions" FOR EACH ROW WHEN (("old"."user_id" IS DISTINCT FROM "new"."user_id")) EXECUTE FUNCTION "public"."sync_otp_session_user_email"();



CREATE OR REPLACE TRIGGER "trg_sync_sim_user_email" BEFORE INSERT OR UPDATE OF "device_id" ON "public"."sims" FOR EACH ROW EXECUTE FUNCTION "public"."sync_sim_user_email"();



CREATE OR REPLACE TRIGGER "trg_sync_sim_user_email_from_device" AFTER UPDATE OF "user_id" ON "public"."devices" FOR EACH ROW EXECUTE FUNCTION "public"."sync_sim_user_email_from_device"();



CREATE OR REPLACE TRIGGER "trg_sync_sim_user_email_from_user" AFTER UPDATE OF "email" ON "public"."users" FOR EACH ROW EXECUTE FUNCTION "public"."sync_sim_user_email_from_user"();



CREATE OR REPLACE TRIGGER "trg_sync_voucher_code" BEFORE INSERT OR UPDATE OF "voucher_id" ON "public"."manual_payments" FOR EACH ROW EXECUTE FUNCTION "public"."sync_voucher_code"();



CREATE OR REPLACE TRIGGER "trg_sync_wallet_topup_user_email_insert" BEFORE INSERT ON "public"."wallet_topups" FOR EACH ROW EXECUTE FUNCTION "public"."sync_wallet_topup_user_email"();



CREATE OR REPLACE TRIGGER "trg_sync_wallet_topup_user_email_update" BEFORE UPDATE ON "public"."wallet_topups" FOR EACH ROW WHEN (("old"."user_id" IS DISTINCT FROM "new"."user_id")) EXECUTE FUNCTION "public"."sync_wallet_topup_user_email"();



CREATE OR REPLACE TRIGGER "trg_update_agent_balance_on_delete" AFTER DELETE ON "public"."agent_transactions" FOR EACH ROW EXECUTE FUNCTION "public"."update_agent_balance_on_transaction_change"();



CREATE OR REPLACE TRIGGER "trg_update_agent_balance_on_insert" AFTER INSERT ON "public"."agent_transactions" FOR EACH ROW EXECUTE FUNCTION "public"."update_agent_balance_on_transaction_change"();



CREATE OR REPLACE TRIGGER "trg_update_agent_balance_on_update" AFTER UPDATE OF "status", "agent_share" ON "public"."agent_transactions" FOR EACH ROW EXECUTE FUNCTION "public"."update_agent_balance_on_transaction_change"();



CREATE OR REPLACE TRIGGER "trg_update_device_and_sims_status" AFTER UPDATE OF "last_heartbeat" ON "public"."devices" FOR EACH ROW EXECUTE FUNCTION "public"."update_device_and_sim_status"();



CREATE OR REPLACE TRIGGER "trg_update_device_name" BEFORE INSERT OR UPDATE ON "public"."sims" FOR EACH ROW EXECUTE FUNCTION "public"."update_device_name_in_sims"();



CREATE OR REPLACE TRIGGER "trg_update_gcash_notif_after_topup" AFTER INSERT OR UPDATE ON "public"."wallet_topups" FOR EACH ROW WHEN ((("new"."status" = 'approved'::"text") AND ("new"."matched_notification_id" IS NOT NULL))) EXECUTE FUNCTION "public"."update_gcash_notif_after_topup_match"();



CREATE OR REPLACE TRIGGER "trg_update_withdrawal_payment_methods_updated_at" BEFORE UPDATE ON "public"."withdrawal_payment_methods" FOR EACH ROW EXECUTE FUNCTION "public"."update_withdrawal_payment_methods_updated_at"();



CREATE OR REPLACE TRIGGER "trg_wallet_topups_apply_payment_method_balance" AFTER INSERT OR UPDATE OF "status" ON "public"."wallet_topups" FOR EACH ROW EXECUTE FUNCTION "public"."trg_wallet_topups_apply_payment_method_balance"();



CREATE OR REPLACE TRIGGER "trg_wallet_withdrawals_apply_payment_method_balance" AFTER INSERT OR UPDATE OF "status" ON "public"."wallet_transactions" FOR EACH ROW EXECUTE FUNCTION "public"."trg_wallet_withdrawals_apply_payment_method_balance"();



CREATE OR REPLACE TRIGGER "trigger_agent_invite_earning_on_insert" AFTER INSERT ON "public"."agent_transactions" FOR EACH ROW EXECUTE FUNCTION "public"."trigger_agent_invite_earning_on_insert"();



CREATE OR REPLACE TRIGGER "trigger_agent_invite_earning_on_status_update" AFTER UPDATE OF "status" ON "public"."agent_transactions" FOR EACH ROW EXECUTE FUNCTION "public"."trigger_agent_invite_earning_on_status_update"();



CREATE OR REPLACE TRIGGER "trigger_auto_generate_referral_code" BEFORE INSERT ON "public"."users" FOR EACH ROW WHEN (("new"."referral_code" IS NULL)) EXECUTE FUNCTION "public"."auto_generate_referral_code"();



CREATE OR REPLACE TRIGGER "trigger_otp_completed_referral" AFTER UPDATE OF "status" ON "public"."otp_sessions" FOR EACH ROW WHEN ((("new"."status" = 'completed'::"text") AND (("old"."status" IS NULL) OR ("old"."status" <> 'completed'::"text")))) EXECUTE FUNCTION "public"."trigger_process_referral_on_otp_complete"();



CREATE OR REPLACE TRIGGER "trigger_prevent_claimed_status_change" BEFORE UPDATE ON "public"."referral_milestones" FOR EACH ROW EXECUTE FUNCTION "public"."prevent_claimed_status_change"();



CREATE OR REPLACE TRIGGER "trigger_update_agent_applications_updated_at" BEFORE UPDATE ON "public"."agent_applications" FOR EACH ROW EXECUTE FUNCTION "public"."update_agent_applications_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_update_agent_commission_config_updated_at" BEFORE UPDATE ON "public"."agent_commission_config" FOR EACH ROW EXECUTE FUNCTION "public"."update_agent_commission_config_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_update_agent_commission_overrides_updated_at" BEFORE UPDATE ON "public"."agent_commission_overrides" FOR EACH ROW EXECUTE FUNCTION "public"."update_agent_commission_overrides_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_update_contact_submissions_updated_at" BEFORE UPDATE ON "public"."contact_submissions" FOR EACH ROW EXECUTE FUNCTION "public"."update_contact_submissions_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_update_last_activity" BEFORE UPDATE ON "public"."otp_sessions" FOR EACH ROW EXECUTE FUNCTION "public"."update_last_activity"();



CREATE OR REPLACE TRIGGER "trigger_update_milestones_on_config_change" AFTER UPDATE ON "public"."referral_config" FOR EACH ROW EXECUTE FUNCTION "public"."update_milestones_on_config_change"();



CREATE OR REPLACE TRIGGER "trigger_update_milestones_on_config_insert" AFTER INSERT ON "public"."referral_config" FOR EACH ROW EXECUTE FUNCTION "public"."update_milestones_on_config_change"();



CREATE OR REPLACE TRIGGER "trigger_update_rate_limit_config_updated_at" BEFORE UPDATE ON "public"."rate_limit_config" FOR EACH ROW EXECUTE FUNCTION "public"."update_rate_limit_config_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_update_rate_limit_tracking_updated_at" BEFORE UPDATE ON "public"."rate_limit_tracking" FOR EACH ROW EXECUTE FUNCTION "public"."update_rate_limit_tracking_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_update_referral_config_updated_at" BEFORE UPDATE ON "public"."referral_config" FOR EACH ROW EXECUTE FUNCTION "public"."update_referral_config_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_update_referral_milestones_updated_at" BEFORE UPDATE ON "public"."referral_milestones" FOR EACH ROW EXECUTE FUNCTION "public"."update_referral_milestones_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_update_review_replies_updated_at" BEFORE UPDATE ON "public"."review_replies" FOR EACH ROW EXECUTE FUNCTION "public"."update_review_replies_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_update_reviews_updated_at" BEFORE UPDATE ON "public"."reviews" FOR EACH ROW EXECUTE FUNCTION "public"."update_reviews_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_update_user_settings_updated_at" BEFORE UPDATE ON "public"."user_settings" FOR EACH ROW EXECUTE FUNCTION "public"."update_user_settings_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_update_users_updated_at" BEFORE UPDATE ON "public"."users" FOR EACH ROW EXECUTE FUNCTION "public"."update_users_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_update_wallet_topups_updated_at" BEFORE UPDATE ON "public"."wallet_topups" FOR EACH ROW EXECUTE FUNCTION "public"."update_wallet_topups_updated_at"();



ALTER TABLE ONLY "public"."account_deletion_tokens"
    ADD CONSTRAINT "account_deletion_tokens_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."agent_applications"
    ADD CONSTRAINT "agent_applications_reviewed_by_fkey" FOREIGN KEY ("reviewed_by") REFERENCES "public"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."agent_balances"
    ADD CONSTRAINT "agent_balances_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."agent_claims"
    ADD CONSTRAINT "agent_claims_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."agent_commission_config"
    ADD CONSTRAINT "agent_commission_config_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "public"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."agent_commission_overrides"
    ADD CONSTRAINT "agent_commission_overrides_set_by_fkey" FOREIGN KEY ("set_by") REFERENCES "public"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."agent_commission_overrides"
    ADD CONSTRAINT "agent_commission_overrides_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."agent_invite_earnings"
    ADD CONSTRAINT "agent_invite_earnings_agent_transaction_id_fkey" FOREIGN KEY ("agent_transaction_id") REFERENCES "public"."agent_transactions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."agent_invite_earnings"
    ADD CONSTRAINT "agent_invite_earnings_invited_agent_id_fkey" FOREIGN KEY ("invited_agent_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."agent_invite_earnings"
    ADD CONSTRAINT "agent_invite_earnings_inviter_id_fkey" FOREIGN KEY ("inviter_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."agent_transactions"
    ADD CONSTRAINT "agent_transactions_sim_app_usage_id_fkey" FOREIGN KEY ("sim_app_usage_id") REFERENCES "public"."sim_app_usage"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."agent_transactions"
    ADD CONSTRAINT "agent_transactions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."announcement"
    ADD CONSTRAINT "announcement_target_device_id_fkey" FOREIGN KEY ("target_device_id") REFERENCES "public"."devices"("device_id");



ALTER TABLE ONLY "public"."chat_link_codes"
    ADD CONSTRAINT "chat_link_codes_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."devices"
    ADD CONSTRAINT "devices_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."otp_session_queue"
    ADD CONSTRAINT "fk_otp_session_queue_payment" FOREIGN KEY ("payment_id") REFERENCES "public"."manual_payments"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."gcash_notif"
    ADD CONSTRAINT "gcash_notif_matched_topup_id_fkey" FOREIGN KEY ("matched_topup_id") REFERENCES "public"."wallet_topups"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."manual_payments"
    ADD CONSTRAINT "manual_payments_agent_user_id_fkey" FOREIGN KEY ("agent_user_id") REFERENCES "public"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."manual_payments"
    ADD CONSTRAINT "manual_payments_approved_by_fkey" FOREIGN KEY ("approved_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."manual_payments"
    ADD CONSTRAINT "manual_payments_otp_session_id_fkey" FOREIGN KEY ("otp_session_id") REFERENCES "public"."otp_sessions"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."manual_payments"
    ADD CONSTRAINT "manual_payments_payment_method_id_fkey" FOREIGN KEY ("payment_method_id") REFERENCES "public"."payment_methods"("id");



ALTER TABLE ONLY "public"."manual_payments"
    ADD CONSTRAINT "manual_payments_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."manual_payments"
    ADD CONSTRAINT "manual_payments_voucher_id_fkey" FOREIGN KEY ("voucher_id") REFERENCES "public"."vouchers"("id");



ALTER TABLE ONLY "public"."manual_referral_assignments"
    ADD CONSTRAINT "manual_referral_assignments_assigned_by_fkey" FOREIGN KEY ("assigned_by") REFERENCES "public"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."manual_referral_assignments"
    ADD CONSTRAINT "manual_referral_assignments_previous_referrer_id_fkey" FOREIGN KEY ("previous_referrer_id") REFERENCES "public"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."manual_referral_assignments"
    ADD CONSTRAINT "manual_referral_assignments_referred_user_id_fkey" FOREIGN KEY ("referred_user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."manual_referral_assignments"
    ADD CONSTRAINT "manual_referral_assignments_referrer_id_fkey" FOREIGN KEY ("referrer_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."otp_session_queue"
    ADD CONSTRAINT "otp_session_queue_payment_id_fkey" FOREIGN KEY ("payment_id") REFERENCES "public"."manual_payments"("id");



ALTER TABLE ONLY "public"."otp_sessions"
    ADD CONSTRAINT "otp_sessions_agent_sim_id_fkey" FOREIGN KEY ("agent_sim_id") REFERENCES "public"."sims"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."otp_sessions"
    ADD CONSTRAINT "otp_sessions_agent_user_id_fkey" FOREIGN KEY ("agent_user_id") REFERENCES "public"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."otp_sessions"
    ADD CONSTRAINT "otp_sessions_sim_number_fkey" FOREIGN KEY ("sim_number") REFERENCES "public"."sims"("number");



ALTER TABLE ONLY "public"."otp_sessions"
    ADD CONSTRAINT "otp_sessions_sms_message_id_fkey" FOREIGN KEY ("sms_message_id") REFERENCES "public"."sms_messages"("id");



ALTER TABLE ONLY "public"."otp_sessions"
    ADD CONSTRAINT "otp_sessions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."payment_method_transactions"
    ADD CONSTRAINT "payment_method_transactions_payment_method_id_fkey" FOREIGN KEY ("payment_method_id") REFERENCES "public"."payment_methods"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."referral_earnings"
    ADD CONSTRAINT "referral_earnings_otp_session_id_fkey" FOREIGN KEY ("otp_session_id") REFERENCES "public"."otp_sessions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."referral_earnings"
    ADD CONSTRAINT "referral_earnings_referred_user_id_fkey" FOREIGN KEY ("referred_user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."referral_earnings"
    ADD CONSTRAINT "referral_earnings_referrer_id_fkey" FOREIGN KEY ("referrer_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."referral_milestones"
    ADD CONSTRAINT "referral_milestones_referrer_id_fkey" FOREIGN KEY ("referrer_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."review_replies"
    ADD CONSTRAINT "review_replies_author_id_fkey" FOREIGN KEY ("author_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."review_replies"
    ADD CONSTRAINT "review_replies_review_id_fkey" FOREIGN KEY ("review_id") REFERENCES "public"."reviews"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."reviews"
    ADD CONSTRAINT "reviews_otp_session_id_fkey" FOREIGN KEY ("otp_session_id") REFERENCES "public"."otp_sessions"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."reviews"
    ADD CONSTRAINT "reviews_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sim_app_usage"
    ADD CONSTRAINT "sim_app_usage_agent_user_id_fkey" FOREIGN KEY ("agent_user_id") REFERENCES "public"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."sim_app_usage"
    ADD CONSTRAINT "sim_app_usage_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."otp_sessions"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."sim_app_usage"
    ADD CONSTRAINT "sim_app_usage_sim_number_fkey" FOREIGN KEY ("sim_number") REFERENCES "public"."sims"("number") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sim_failure_records"
    ADD CONSTRAINT "sim_failure_records_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."otp_sessions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sim_failure_records"
    ADD CONSTRAINT "sim_failure_records_sim_id_fkey" FOREIGN KEY ("sim_id") REFERENCES "public"."sims"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sim_failure_streaks"
    ADD CONSTRAINT "sim_failure_streaks_sim_id_fkey" FOREIGN KEY ("sim_id") REFERENCES "public"."sims"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sim_group_members"
    ADD CONSTRAINT "sim_group_members_group_id_fkey" FOREIGN KEY ("group_id") REFERENCES "public"."sim_groups"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sim_group_members"
    ADD CONSTRAINT "sim_group_members_sim_number_fkey" FOREIGN KEY ("sim_number") REFERENCES "public"."sims"("number") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sim_history"
    ADD CONSTRAINT "sim_history_device_id_fkey" FOREIGN KEY ("device_id") REFERENCES "public"."devices"("device_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sim_stats"
    ADD CONSTRAINT "sim_stats_sim_id_fkey" FOREIGN KEY ("sim_id") REFERENCES "public"."sims"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sims"
    ADD CONSTRAINT "sims_device_id_fkey" FOREIGN KEY ("device_id") REFERENCES "public"."devices"("device_id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."sms_messages"
    ADD CONSTRAINT "sms_messages_consumed_by_session_fkey" FOREIGN KEY ("consumed_by_session") REFERENCES "public"."otp_sessions"("id");



ALTER TABLE ONLY "public"."telegram_referral_invite_events"
    ADD CONSTRAINT "telegram_referral_invite_events_referred_user_id_fkey" FOREIGN KEY ("referred_user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."telegram_referral_invite_events"
    ADD CONSTRAINT "telegram_referral_invite_events_referrer_id_fkey" FOREIGN KEY ("referrer_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."telegram_session_warning_events"
    ADD CONSTRAINT "telegram_session_warning_events_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."otp_sessions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."telegram_sms_message_push_events"
    ADD CONSTRAINT "telegram_sms_message_push_events_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."otp_sessions"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."telegram_sms_message_push_events"
    ADD CONSTRAINT "telegram_sms_message_push_events_sms_message_id_fkey" FOREIGN KEY ("sms_message_id") REFERENCES "public"."sms_messages"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_chat_links"
    ADD CONSTRAINT "user_chat_links_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_push_subscriptions"
    ADD CONSTRAINT "user_push_subscriptions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_settings"
    ADD CONSTRAINT "user_settings_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_archived_by_fkey" FOREIGN KEY ("archived_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_referred_by_fkey" FOREIGN KEY ("referred_by") REFERENCES "public"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."voucher_usage"
    ADD CONSTRAINT "voucher_usage_payment_id_fkey" FOREIGN KEY ("payment_id") REFERENCES "public"."manual_payments"("id");



ALTER TABLE ONLY "public"."voucher_usage"
    ADD CONSTRAINT "voucher_usage_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."voucher_usage"
    ADD CONSTRAINT "voucher_usage_voucher_id_fkey" FOREIGN KEY ("voucher_id") REFERENCES "public"."vouchers"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."vouchers"
    ADD CONSTRAINT "vouchers_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."wallet_topups"
    ADD CONSTRAINT "wallet_topups_approved_by_fkey" FOREIGN KEY ("approved_by") REFERENCES "public"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."wallet_topups"
    ADD CONSTRAINT "wallet_topups_matched_notification_id_fkey" FOREIGN KEY ("matched_notification_id") REFERENCES "public"."gcash_notif"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."wallet_topups"
    ADD CONSTRAINT "wallet_topups_rejected_by_fkey" FOREIGN KEY ("rejected_by") REFERENCES "public"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."wallet_topups"
    ADD CONSTRAINT "wallet_topups_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."wallet_transactions"
    ADD CONSTRAINT "wallet_transactions_otp_session_id_fkey" FOREIGN KEY ("otp_session_id") REFERENCES "public"."otp_sessions"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."wallet_transactions"
    ADD CONSTRAINT "wallet_transactions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."wallet_transactions"
    ADD CONSTRAINT "wallet_transactions_withdrawal_payment_method_id_fkey" FOREIGN KEY ("withdrawal_payment_method_id") REFERENCES "public"."withdrawal_payment_methods"("id") ON DELETE SET NULL;



CREATE POLICY "Users can delete their own settings" ON "public"."user_settings" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert their own profile" ON "public"."users" FOR INSERT WITH CHECK ((("auth"."uid"() = "id") AND ("is_archived" = false)));



CREATE POLICY "Users can insert their own settings" ON "public"."user_settings" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can see their own archived account" ON "public"."users" FOR SELECT USING (("auth"."uid"() = "id"));



CREATE POLICY "Users can update their own profile" ON "public"."users" FOR UPDATE USING ((("auth"."uid"() = "id") AND ("is_archived" = false)));



CREATE POLICY "Users can update their own settings" ON "public"."user_settings" FOR UPDATE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view their own profile" ON "public"."users" FOR SELECT USING ((("auth"."uid"() = "id") AND ("is_archived" = false)));



CREATE POLICY "Users can view their own settings" ON "public"."user_settings" FOR SELECT USING (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."user_settings" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";








GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";














































































































































































GRANT ALL ON FUNCTION "public"."acquire_scheduler_lease"("p_lease_key" "text", "p_ttl_seconds" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."acquire_scheduler_lease"("p_lease_key" "text", "p_ttl_seconds" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."acquire_scheduler_lease"("p_lease_key" "text", "p_ttl_seconds" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."apply_payment_method_txn"("p_payment_method_id" "uuid", "p_direction" "text", "p_amount" numeric, "p_source_table" "text", "p_source_id" "uuid", "p_effective_at" timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."apply_payment_method_txn"("p_payment_method_id" "uuid", "p_direction" "text", "p_amount" numeric, "p_source_table" "text", "p_source_id" "uuid", "p_effective_at" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."apply_payment_method_txn"("p_payment_method_id" "uuid", "p_direction" "text", "p_amount" numeric, "p_source_table" "text", "p_source_id" "uuid", "p_effective_at" timestamp with time zone) TO "service_role";



GRANT ALL ON FUNCTION "public"."apply_sim_failure_streak_on_failure_record"() TO "anon";
GRANT ALL ON FUNCTION "public"."apply_sim_failure_streak_on_failure_record"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."apply_sim_failure_streak_on_failure_record"() TO "service_role";



GRANT ALL ON FUNCTION "public"."assign_default_referrer_on_insert"() TO "anon";
GRANT ALL ON FUNCTION "public"."assign_default_referrer_on_insert"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."assign_default_referrer_on_insert"() TO "service_role";



GRANT ALL ON FUNCTION "public"."auto_generate_referral_code"() TO "anon";
GRANT ALL ON FUNCTION "public"."auto_generate_referral_code"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."auto_generate_referral_code"() TO "service_role";



GRANT ALL ON FUNCTION "public"."auto_link_sms_to_otp_session"("p_sim_number" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."auto_link_sms_to_otp_session"("p_sim_number" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."auto_link_sms_to_otp_session"("p_sim_number" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."auto_link_sms_to_session"() TO "anon";
GRANT ALL ON FUNCTION "public"."auto_link_sms_to_session"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."auto_link_sms_to_session"() TO "service_role";



GRANT ALL ON FUNCTION "public"."auto_mature_on_query"() TO "anon";
GRANT ALL ON FUNCTION "public"."auto_mature_on_query"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."auto_mature_on_query"() TO "service_role";



GRANT ALL ON FUNCTION "public"."auto_mature_pending_transactions"() TO "anon";
GRANT ALL ON FUNCTION "public"."auto_mature_pending_transactions"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."auto_mature_pending_transactions"() TO "service_role";



GRANT ALL ON FUNCTION "public"."backfill_sim_stats_from_usage"() TO "anon";
GRANT ALL ON FUNCTION "public"."backfill_sim_stats_from_usage"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."backfill_sim_stats_from_usage"() TO "service_role";



GRANT ALL ON FUNCTION "public"."check_otp_message"("p_session_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."check_otp_message"("p_session_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_otp_message"("p_session_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."cleanup_expired_rate_limits"() TO "anon";
GRANT ALL ON FUNCTION "public"."cleanup_expired_rate_limits"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."cleanup_expired_rate_limits"() TO "service_role";



GRANT ALL ON FUNCTION "public"."clear_expires_at_if_pending"() TO "anon";
GRANT ALL ON FUNCTION "public"."clear_expires_at_if_pending"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."clear_expires_at_if_pending"() TO "service_role";



GRANT ALL ON FUNCTION "public"."create_agent_invite_earning_for_tx"("p_agent_transaction_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."create_agent_invite_earning_for_tx"("p_agent_transaction_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_agent_invite_earning_for_tx"("p_agent_transaction_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."create_agent_transaction_from_usage"() TO "anon";
GRANT ALL ON FUNCTION "public"."create_agent_transaction_from_usage"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_agent_transaction_from_usage"() TO "service_role";



GRANT ALL ON FUNCTION "public"."create_otp_session"("p_user_id" "uuid", "p_app_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_otp_session"("p_user_id" "uuid", "p_app_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_otp_session"("p_user_id" "uuid", "p_app_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."delete_expired_otps"() TO "anon";
GRANT ALL ON FUNCTION "public"."delete_expired_otps"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_expired_otps"() TO "service_role";



GRANT ALL ON FUNCTION "public"."detect_carrier_from_number"() TO "anon";
GRANT ALL ON FUNCTION "public"."detect_carrier_from_number"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."detect_carrier_from_number"() TO "service_role";



GRANT ALL ON FUNCTION "public"."detect_carrier_from_number_after"() TO "anon";
GRANT ALL ON FUNCTION "public"."detect_carrier_from_number_after"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."detect_carrier_from_number_after"() TO "service_role";



GRANT ALL ON FUNCTION "public"."enqueue_manual_payment_auto_approved"() TO "anon";
GRANT ALL ON FUNCTION "public"."enqueue_manual_payment_auto_approved"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."enqueue_manual_payment_auto_approved"() TO "service_role";



GRANT ALL ON FUNCTION "public"."enqueue_otp_on_approval"() TO "anon";
GRANT ALL ON FUNCTION "public"."enqueue_otp_on_approval"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."enqueue_otp_on_approval"() TO "service_role";



GRANT ALL ON FUNCTION "public"."enqueue_telegram_referral_invite_event"() TO "anon";
GRANT ALL ON FUNCTION "public"."enqueue_telegram_referral_invite_event"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."enqueue_telegram_referral_invite_event"() TO "service_role";



GRANT ALL ON FUNCTION "public"."enqueue_wallet_topup_auto_approved"() TO "anon";
GRANT ALL ON FUNCTION "public"."enqueue_wallet_topup_auto_approved"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."enqueue_wallet_topup_auto_approved"() TO "service_role";



GRANT ALL ON FUNCTION "public"."expire_old_sessions"() TO "anon";
GRANT ALL ON FUNCTION "public"."expire_old_sessions"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."expire_old_sessions"() TO "service_role";



GRANT ALL ON FUNCTION "public"."expire_otp_sessions"() TO "anon";
GRANT ALL ON FUNCTION "public"."expire_otp_sessions"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."expire_otp_sessions"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_accumulate_device_uptime"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_accumulate_device_uptime"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_accumulate_device_uptime"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_accumulate_sim_uptime"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_accumulate_sim_uptime"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_accumulate_sim_uptime"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_update_device_status_from_last_seen"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_update_device_status_from_last_seen"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_update_device_status_from_last_seen"() TO "service_role";



GRANT ALL ON FUNCTION "public"."generate_referral_code"() TO "anon";
GRANT ALL ON FUNCTION "public"."generate_referral_code"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_referral_code"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_agent_commission_rate"("p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_agent_commission_rate"("p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_agent_commission_rate"("p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_agent_transactions_with_auto_mature"("p_user_id" "uuid", "p_status" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."get_agent_transactions_with_auto_mature"("p_user_id" "uuid", "p_status" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_agent_transactions_with_auto_mature"("p_user_id" "uuid", "p_status" character varying) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_device_status_from_heartbeat"("heartbeat_time" timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."get_device_status_from_heartbeat"("heartbeat_time" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_device_status_from_heartbeat"("heartbeat_time" timestamp with time zone) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_or_create_rate_limit"("p_identifier" "text", "p_endpoint_path" "text", "p_window_seconds" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_or_create_rate_limit"("p_identifier" "text", "p_endpoint_path" "text", "p_window_seconds" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_or_create_rate_limit"("p_identifier" "text", "p_endpoint_path" "text", "p_window_seconds" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_session_time_remaining"("session_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_session_time_remaining"("session_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_session_time_remaining"("session_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_user_role"("user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_user_role"("user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_role"("user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_user_sessions"("p_user_id" "uuid", "p_limit" integer, "p_offset" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_user_sessions"("p_user_id" "uuid", "p_limit" integer, "p_offset" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_sessions"("p_user_id" "uuid", "p_limit" integer, "p_offset" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_expired_session_with_messages"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_expired_session_with_messages"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_expired_session_with_messages"() TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_manual_payment_status"("p_payment_id" "uuid", "p_status" "text", "p_approved_by" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."handle_manual_payment_status"("p_payment_id" "uuid", "p_status" "text", "p_approved_by" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_manual_payment_status"("p_payment_id" "uuid", "p_status" "text", "p_approved_by" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."increment_sim_failed"("p_sim_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."increment_sim_failed"("p_sim_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."increment_sim_failed"("p_sim_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."is_admin"("user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_admin"("user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_admin"("user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."is_app_allowlisted"("p_app_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."is_app_allowlisted"("p_app_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_app_allowlisted"("p_app_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."log_sim_app_usage"("p_sim_number" "text", "p_app_name" "text", "p_session_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."log_sim_app_usage"("p_sim_number" "text", "p_app_name" "text", "p_session_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."log_sim_app_usage"("p_sim_number" "text", "p_app_name" "text", "p_session_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."manual_expire_sessions"() TO "anon";
GRANT ALL ON FUNCTION "public"."manual_expire_sessions"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."manual_expire_sessions"() TO "service_role";



GRANT ALL ON FUNCTION "public"."match_from_gcash"() TO "anon";
GRANT ALL ON FUNCTION "public"."match_from_gcash"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."match_from_gcash"() TO "service_role";



GRANT ALL ON FUNCTION "public"."match_from_manual"() TO "anon";
GRANT ALL ON FUNCTION "public"."match_from_manual"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."match_from_manual"() TO "service_role";



GRANT ALL ON FUNCTION "public"."match_gcash_notif_to_wallet_topup"() TO "anon";
GRANT ALL ON FUNCTION "public"."match_gcash_notif_to_wallet_topup"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."match_gcash_notif_to_wallet_topup"() TO "service_role";



GRANT ALL ON FUNCTION "public"."match_wallet_topup_with_gcash_notif"() TO "anon";
GRANT ALL ON FUNCTION "public"."match_wallet_topup_with_gcash_notif"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."match_wallet_topup_with_gcash_notif"() TO "service_role";



GRANT ALL ON FUNCTION "public"."pause_sim_on_excessive_excluded_apps"() TO "anon";
GRANT ALL ON FUNCTION "public"."pause_sim_on_excessive_excluded_apps"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."pause_sim_on_excessive_excluded_apps"() TO "service_role";



GRANT ALL ON FUNCTION "public"."preserve_private_sims"() TO "anon";
GRANT ALL ON FUNCTION "public"."preserve_private_sims"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."preserve_private_sims"() TO "service_role";



GRANT ALL ON FUNCTION "public"."prevent_claimed_status_change"() TO "anon";
GRANT ALL ON FUNCTION "public"."prevent_claimed_status_change"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."prevent_claimed_status_change"() TO "service_role";



GRANT ALL ON FUNCTION "public"."process_agent_earnings_on_otp_complete"() TO "anon";
GRANT ALL ON FUNCTION "public"."process_agent_earnings_on_otp_complete"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."process_agent_earnings_on_otp_complete"() TO "service_role";



GRANT ALL ON FUNCTION "public"."process_referral_commission"("p_otp_session_id" "uuid", "p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."process_referral_commission"("p_otp_session_id" "uuid", "p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."process_referral_commission"("p_otp_session_id" "uuid", "p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."recalculate_agent_balance_from_transactions"("p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."recalculate_agent_balance_from_transactions"("p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."recalculate_agent_balance_from_transactions"("p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."recalculate_all_agent_balances"() TO "anon";
GRANT ALL ON FUNCTION "public"."recalculate_all_agent_balances"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."recalculate_all_agent_balances"() TO "service_role";



GRANT ALL ON FUNCTION "public"."recalculate_sim_stats"("p_sim_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."recalculate_sim_stats"("p_sim_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."recalculate_sim_stats"("p_sim_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."record_sim_completion_from_usage"() TO "anon";
GRANT ALL ON FUNCTION "public"."record_sim_completion_from_usage"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."record_sim_completion_from_usage"() TO "service_role";



GRANT ALL ON FUNCTION "public"."record_sim_failure_on_expire"() TO "anon";
GRANT ALL ON FUNCTION "public"."record_sim_failure_on_expire"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."record_sim_failure_on_expire"() TO "service_role";



GRANT ALL ON FUNCTION "public"."record_sim_heartbeat"("p_sim_number" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."record_sim_heartbeat"("p_sim_number" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."record_sim_heartbeat"("p_sim_number" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."reset_sim_failure_streak_on_success_usage"() TO "anon";
GRANT ALL ON FUNCTION "public"."reset_sim_failure_streak_on_success_usage"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."reset_sim_failure_streak_on_success_usage"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_default_referrer_for_users"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_default_referrer_for_users"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_default_referrer_for_users"() TO "service_role";



GRANT ALL ON FUNCTION "public"."snapshot_christmas_2025_failed_baseline"() TO "anon";
GRANT ALL ON FUNCTION "public"."snapshot_christmas_2025_failed_baseline"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."snapshot_christmas_2025_failed_baseline"() TO "service_role";



GRANT ALL ON FUNCTION "public"."snapshot_christmas_2025_uptime_ranking"() TO "anon";
GRANT ALL ON FUNCTION "public"."snapshot_christmas_2025_uptime_ranking"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."snapshot_christmas_2025_uptime_ranking"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_all_milestones_from_config"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_all_milestones_from_config"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_all_milestones_from_config"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_manual_payment_user_email"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_manual_payment_user_email"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_manual_payment_user_email"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_otp_session_user_email"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_otp_session_user_email"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_otp_session_user_email"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_sim_user_email"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_sim_user_email"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_sim_user_email"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_sim_user_email_from_device"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_sim_user_email_from_device"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_sim_user_email_from_device"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_sim_user_email_from_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_sim_user_email_from_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_sim_user_email_from_user"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_voucher_code"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_voucher_code"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_voucher_code"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_wallet_topup_user_email"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_wallet_topup_user_email"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_wallet_topup_user_email"() TO "service_role";



GRANT ALL ON FUNCTION "public"."transition_otp_session_status"("session_id" "uuid", "new_status" "text", "timeout_minutes" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."transition_otp_session_status"("session_id" "uuid", "new_status" "text", "timeout_minutes" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."transition_otp_session_status"("session_id" "uuid", "new_status" "text", "timeout_minutes" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_manual_payments_apply_payment_method_balance"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_manual_payments_apply_payment_method_balance"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_manual_payments_apply_payment_method_balance"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_wallet_topups_apply_payment_method_balance"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_wallet_topups_apply_payment_method_balance"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_wallet_topups_apply_payment_method_balance"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_wallet_withdrawals_apply_payment_method_balance"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_wallet_withdrawals_apply_payment_method_balance"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_wallet_withdrawals_apply_payment_method_balance"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trigger_agent_invite_earning_on_insert"() TO "anon";
GRANT ALL ON FUNCTION "public"."trigger_agent_invite_earning_on_insert"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trigger_agent_invite_earning_on_insert"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trigger_agent_invite_earning_on_status_update"() TO "anon";
GRANT ALL ON FUNCTION "public"."trigger_agent_invite_earning_on_status_update"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trigger_agent_invite_earning_on_status_update"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trigger_auto_link_sms"() TO "anon";
GRANT ALL ON FUNCTION "public"."trigger_auto_link_sms"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trigger_auto_link_sms"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trigger_process_referral_on_otp_complete"() TO "anon";
GRANT ALL ON FUNCTION "public"."trigger_process_referral_on_otp_complete"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trigger_process_referral_on_otp_complete"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_agent_applications_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_agent_applications_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_agent_applications_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_agent_balance_mature"("p_user_id" "uuid", "p_amount" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."update_agent_balance_mature"("p_user_id" "uuid", "p_amount" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_agent_balance_mature"("p_user_id" "uuid", "p_amount" numeric) TO "service_role";



GRANT ALL ON FUNCTION "public"."update_agent_balance_on_transaction_change"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_agent_balance_on_transaction_change"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_agent_balance_on_transaction_change"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_agent_commission_config_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_agent_commission_config_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_agent_commission_config_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_agent_commission_overrides_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_agent_commission_overrides_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_agent_commission_overrides_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_contact_submissions_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_contact_submissions_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_contact_submissions_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_device_and_sim_status"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_device_and_sim_status"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_device_and_sim_status"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_device_name_in_sims"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_device_name_in_sims"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_device_name_in_sims"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_gcash_notif_after_topup_match"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_gcash_notif_after_topup_match"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_gcash_notif_after_topup_match"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_last_activity"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_last_activity"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_last_activity"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_last_login"("user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."update_last_login"("user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_last_login"("user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_messages_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_messages_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_messages_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_milestone_progress"("p_referrer_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."update_milestone_progress"("p_referrer_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_milestone_progress"("p_referrer_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_milestones_on_config_change"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_milestones_on_config_change"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_milestones_on_config_change"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_rate_limit_config_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_rate_limit_config_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_rate_limit_config_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_rate_limit_tracking_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_rate_limit_tracking_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_rate_limit_tracking_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_referral_config_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_referral_config_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_referral_config_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_referral_milestones_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_referral_milestones_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_referral_milestones_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_review_replies_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_review_replies_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_review_replies_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_reviews_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_reviews_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_reviews_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_user_referral"("p_referred_user_id" "uuid", "p_referrer_id" "uuid", "p_assigned_by" "uuid", "p_reason" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."update_user_referral"("p_referred_user_id" "uuid", "p_referrer_id" "uuid", "p_assigned_by" "uuid", "p_reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_user_referral"("p_referred_user_id" "uuid", "p_referrer_id" "uuid", "p_assigned_by" "uuid", "p_reason" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_user_settings_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_user_settings_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_user_settings_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_users_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_users_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_users_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_wallet_topups_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_wallet_topups_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_wallet_topups_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_withdrawal_payment_methods_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_withdrawal_payment_methods_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_withdrawal_payment_methods_updated_at"() TO "service_role";
























GRANT ALL ON TABLE "public"."account_deletion_tokens" TO "anon";
GRANT ALL ON TABLE "public"."account_deletion_tokens" TO "authenticated";
GRANT ALL ON TABLE "public"."account_deletion_tokens" TO "service_role";



GRANT ALL ON TABLE "public"."agent_applications" TO "anon";
GRANT ALL ON TABLE "public"."agent_applications" TO "authenticated";
GRANT ALL ON TABLE "public"."agent_applications" TO "service_role";



GRANT ALL ON TABLE "public"."agent_balances" TO "anon";
GRANT ALL ON TABLE "public"."agent_balances" TO "authenticated";
GRANT ALL ON TABLE "public"."agent_balances" TO "service_role";



GRANT ALL ON TABLE "public"."agent_claims" TO "anon";
GRANT ALL ON TABLE "public"."agent_claims" TO "authenticated";
GRANT ALL ON TABLE "public"."agent_claims" TO "service_role";



GRANT ALL ON SEQUENCE "public"."agent_claims_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."agent_claims_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."agent_claims_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."agent_commission_config" TO "anon";
GRANT ALL ON TABLE "public"."agent_commission_config" TO "authenticated";
GRANT ALL ON TABLE "public"."agent_commission_config" TO "service_role";



GRANT ALL ON TABLE "public"."agent_commission_overrides" TO "anon";
GRANT ALL ON TABLE "public"."agent_commission_overrides" TO "authenticated";
GRANT ALL ON TABLE "public"."agent_commission_overrides" TO "service_role";



GRANT ALL ON TABLE "public"."agent_invite_earnings" TO "anon";
GRANT ALL ON TABLE "public"."agent_invite_earnings" TO "authenticated";
GRANT ALL ON TABLE "public"."agent_invite_earnings" TO "service_role";



GRANT ALL ON SEQUENCE "public"."agent_invite_earnings_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."agent_invite_earnings_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."agent_invite_earnings_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."agent_transactions" TO "anon";
GRANT ALL ON TABLE "public"."agent_transactions" TO "authenticated";
GRANT ALL ON TABLE "public"."agent_transactions" TO "service_role";



GRANT ALL ON SEQUENCE "public"."agent_transactions_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."agent_transactions_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."agent_transactions_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."announcement" TO "anon";
GRANT ALL ON TABLE "public"."announcement" TO "authenticated";
GRANT ALL ON TABLE "public"."announcement" TO "service_role";



GRANT ALL ON TABLE "public"."chat_bot_states" TO "anon";
GRANT ALL ON TABLE "public"."chat_bot_states" TO "authenticated";
GRANT ALL ON TABLE "public"."chat_bot_states" TO "service_role";



GRANT ALL ON TABLE "public"."chat_link_codes" TO "anon";
GRANT ALL ON TABLE "public"."chat_link_codes" TO "authenticated";
GRANT ALL ON TABLE "public"."chat_link_codes" TO "service_role";



GRANT ALL ON TABLE "public"."christmas_2025_uptime_ranking_snapshot" TO "anon";
GRANT ALL ON TABLE "public"."christmas_2025_uptime_ranking_snapshot" TO "authenticated";
GRANT ALL ON TABLE "public"."christmas_2025_uptime_ranking_snapshot" TO "service_role";



GRANT ALL ON TABLE "public"."contact_submissions" TO "anon";
GRANT ALL ON TABLE "public"."contact_submissions" TO "authenticated";
GRANT ALL ON TABLE "public"."contact_submissions" TO "service_role";



GRANT ALL ON TABLE "public"."daily_analytics_snapshots" TO "anon";
GRANT ALL ON TABLE "public"."daily_analytics_snapshots" TO "authenticated";
GRANT ALL ON TABLE "public"."daily_analytics_snapshots" TO "service_role";



GRANT ALL ON SEQUENCE "public"."daily_analytics_snapshots_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."daily_analytics_snapshots_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."daily_analytics_snapshots_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."devices" TO "anon";
GRANT ALL ON TABLE "public"."devices" TO "authenticated";
GRANT ALL ON TABLE "public"."devices" TO "service_role";



GRANT ALL ON TABLE "public"."device_status" TO "anon";
GRANT ALL ON TABLE "public"."device_status" TO "authenticated";
GRANT ALL ON TABLE "public"."device_status" TO "service_role";



GRANT ALL ON TABLE "public"."feedback" TO "anon";
GRANT ALL ON TABLE "public"."feedback" TO "authenticated";
GRANT ALL ON TABLE "public"."feedback" TO "service_role";



GRANT ALL ON TABLE "public"."gcash_notif" TO "anon";
GRANT ALL ON TABLE "public"."gcash_notif" TO "authenticated";
GRANT ALL ON TABLE "public"."gcash_notif" TO "service_role";



GRANT ALL ON SEQUENCE "public"."gcash_notif_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."gcash_notif_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."gcash_notif_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."incoming_webhook_events" TO "anon";
GRANT ALL ON TABLE "public"."incoming_webhook_events" TO "authenticated";
GRANT ALL ON TABLE "public"."incoming_webhook_events" TO "service_role";



GRANT ALL ON TABLE "public"."manual_payments" TO "anon";
GRANT ALL ON TABLE "public"."manual_payments" TO "authenticated";
GRANT ALL ON TABLE "public"."manual_payments" TO "service_role";



GRANT ALL ON TABLE "public"."manual_referral_assignments" TO "anon";
GRANT ALL ON TABLE "public"."manual_referral_assignments" TO "authenticated";
GRANT ALL ON TABLE "public"."manual_referral_assignments" TO "service_role";



GRANT ALL ON TABLE "public"."notification_outbox" TO "anon";
GRANT ALL ON TABLE "public"."notification_outbox" TO "authenticated";
GRANT ALL ON TABLE "public"."notification_outbox" TO "service_role";



GRANT ALL ON SEQUENCE "public"."notification_outbox_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."notification_outbox_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."notification_outbox_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."otp_pricing" TO "anon";
GRANT ALL ON TABLE "public"."otp_pricing" TO "authenticated";
GRANT ALL ON TABLE "public"."otp_pricing" TO "service_role";



GRANT ALL ON SEQUENCE "public"."otp_pricing_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."otp_pricing_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."otp_pricing_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."otp_session_extensions" TO "anon";
GRANT ALL ON TABLE "public"."otp_session_extensions" TO "authenticated";
GRANT ALL ON TABLE "public"."otp_session_extensions" TO "service_role";



GRANT ALL ON TABLE "public"."otp_session_queue" TO "anon";
GRANT ALL ON TABLE "public"."otp_session_queue" TO "authenticated";
GRANT ALL ON TABLE "public"."otp_session_queue" TO "service_role";



GRANT ALL ON TABLE "public"."otp_sessions" TO "anon";
GRANT ALL ON TABLE "public"."otp_sessions" TO "authenticated";
GRANT ALL ON TABLE "public"."otp_sessions" TO "service_role";



GRANT ALL ON TABLE "public"."payment_method_transactions" TO "anon";
GRANT ALL ON TABLE "public"."payment_method_transactions" TO "authenticated";
GRANT ALL ON TABLE "public"."payment_method_transactions" TO "service_role";



GRANT ALL ON TABLE "public"."payment_methods" TO "anon";
GRANT ALL ON TABLE "public"."payment_methods" TO "authenticated";
GRANT ALL ON TABLE "public"."payment_methods" TO "service_role";



GRANT ALL ON TABLE "public"."rate_limit_config" TO "anon";
GRANT ALL ON TABLE "public"."rate_limit_config" TO "authenticated";
GRANT ALL ON TABLE "public"."rate_limit_config" TO "service_role";



GRANT ALL ON TABLE "public"."rate_limit_tracking" TO "anon";
GRANT ALL ON TABLE "public"."rate_limit_tracking" TO "authenticated";
GRANT ALL ON TABLE "public"."rate_limit_tracking" TO "service_role";



GRANT ALL ON TABLE "public"."referral_config" TO "anon";
GRANT ALL ON TABLE "public"."referral_config" TO "authenticated";
GRANT ALL ON TABLE "public"."referral_config" TO "service_role";



GRANT ALL ON TABLE "public"."referral_earnings" TO "anon";
GRANT ALL ON TABLE "public"."referral_earnings" TO "authenticated";
GRANT ALL ON TABLE "public"."referral_earnings" TO "service_role";



GRANT ALL ON TABLE "public"."referral_milestones" TO "anon";
GRANT ALL ON TABLE "public"."referral_milestones" TO "authenticated";
GRANT ALL ON TABLE "public"."referral_milestones" TO "service_role";



GRANT ALL ON TABLE "public"."review_replies" TO "anon";
GRANT ALL ON TABLE "public"."review_replies" TO "authenticated";
GRANT ALL ON TABLE "public"."review_replies" TO "service_role";



GRANT ALL ON TABLE "public"."reviews" TO "anon";
GRANT ALL ON TABLE "public"."reviews" TO "authenticated";
GRANT ALL ON TABLE "public"."reviews" TO "service_role";



GRANT ALL ON TABLE "public"."scheduler_leases" TO "anon";
GRANT ALL ON TABLE "public"."scheduler_leases" TO "authenticated";
GRANT ALL ON TABLE "public"."scheduler_leases" TO "service_role";



GRANT ALL ON TABLE "public"."sim_app_usage" TO "anon";
GRANT ALL ON TABLE "public"."sim_app_usage" TO "authenticated";
GRANT ALL ON TABLE "public"."sim_app_usage" TO "service_role";



GRANT ALL ON TABLE "public"."sims" TO "anon";
GRANT ALL ON TABLE "public"."sims" TO "authenticated";
GRANT ALL ON TABLE "public"."sims" TO "service_role";



GRANT ALL ON TABLE "public"."sim_app_earnings" TO "anon";
GRANT ALL ON TABLE "public"."sim_app_earnings" TO "authenticated";
GRANT ALL ON TABLE "public"."sim_app_earnings" TO "service_role";



GRANT ALL ON TABLE "public"."sim_failure_records" TO "anon";
GRANT ALL ON TABLE "public"."sim_failure_records" TO "authenticated";
GRANT ALL ON TABLE "public"."sim_failure_records" TO "service_role";



GRANT ALL ON TABLE "public"."sim_failure_records_view" TO "anon";
GRANT ALL ON TABLE "public"."sim_failure_records_view" TO "authenticated";
GRANT ALL ON TABLE "public"."sim_failure_records_view" TO "service_role";



GRANT ALL ON TABLE "public"."sim_failure_streaks" TO "anon";
GRANT ALL ON TABLE "public"."sim_failure_streaks" TO "authenticated";
GRANT ALL ON TABLE "public"."sim_failure_streaks" TO "service_role";



GRANT ALL ON TABLE "public"."sim_group_members" TO "anon";
GRANT ALL ON TABLE "public"."sim_group_members" TO "authenticated";
GRANT ALL ON TABLE "public"."sim_group_members" TO "service_role";



GRANT ALL ON TABLE "public"."sim_groups" TO "anon";
GRANT ALL ON TABLE "public"."sim_groups" TO "authenticated";
GRANT ALL ON TABLE "public"."sim_groups" TO "service_role";



GRANT ALL ON TABLE "public"."sim_history" TO "anon";
GRANT ALL ON TABLE "public"."sim_history" TO "authenticated";
GRANT ALL ON TABLE "public"."sim_history" TO "service_role";



GRANT ALL ON SEQUENCE "public"."sim_history_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."sim_history_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."sim_history_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."sim_stats" TO "anon";
GRANT ALL ON TABLE "public"."sim_stats" TO "authenticated";
GRANT ALL ON TABLE "public"."sim_stats" TO "service_role";



GRANT ALL ON SEQUENCE "public"."sims_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."sims_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."sims_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."sms_messages" TO "anon";
GRANT ALL ON TABLE "public"."sms_messages" TO "authenticated";
GRANT ALL ON TABLE "public"."sms_messages" TO "service_role";



GRANT ALL ON SEQUENCE "public"."sms_messages_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."sms_messages_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."sms_messages_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."system_logs" TO "anon";
GRANT ALL ON TABLE "public"."system_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."system_logs" TO "service_role";



GRANT ALL ON SEQUENCE "public"."system_logs_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."system_logs_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."system_logs_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."telegram_referral_invite_events" TO "anon";
GRANT ALL ON TABLE "public"."telegram_referral_invite_events" TO "authenticated";
GRANT ALL ON TABLE "public"."telegram_referral_invite_events" TO "service_role";



GRANT ALL ON TABLE "public"."telegram_session_warning_events" TO "anon";
GRANT ALL ON TABLE "public"."telegram_session_warning_events" TO "authenticated";
GRANT ALL ON TABLE "public"."telegram_session_warning_events" TO "service_role";



GRANT ALL ON TABLE "public"."telegram_sms_message_push_events" TO "anon";
GRANT ALL ON TABLE "public"."telegram_sms_message_push_events" TO "authenticated";
GRANT ALL ON TABLE "public"."telegram_sms_message_push_events" TO "service_role";



GRANT ALL ON TABLE "public"."user_chat_links" TO "anon";
GRANT ALL ON TABLE "public"."user_chat_links" TO "authenticated";
GRANT ALL ON TABLE "public"."user_chat_links" TO "service_role";



GRANT ALL ON TABLE "public"."users" TO "anon";
GRANT ALL ON TABLE "public"."users" TO "authenticated";
GRANT ALL ON TABLE "public"."users" TO "service_role";



GRANT ALL ON TABLE "public"."user_chat_links_with_email" TO "anon";
GRANT ALL ON TABLE "public"."user_chat_links_with_email" TO "authenticated";
GRANT ALL ON TABLE "public"."user_chat_links_with_email" TO "service_role";



GRANT ALL ON TABLE "public"."user_push_subscriptions" TO "anon";
GRANT ALL ON TABLE "public"."user_push_subscriptions" TO "authenticated";
GRANT ALL ON TABLE "public"."user_push_subscriptions" TO "service_role";



GRANT ALL ON TABLE "public"."user_settings" TO "anon";
GRANT ALL ON TABLE "public"."user_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."user_settings" TO "service_role";



GRANT ALL ON TABLE "public"."v_agent_commission_rates" TO "anon";
GRANT ALL ON TABLE "public"."v_agent_commission_rates" TO "authenticated";
GRANT ALL ON TABLE "public"."v_agent_commission_rates" TO "service_role";



GRANT ALL ON TABLE "public"."v_agent_transactions_auto_mature" TO "anon";
GRANT ALL ON TABLE "public"."v_agent_transactions_auto_mature" TO "authenticated";
GRANT ALL ON TABLE "public"."v_agent_transactions_auto_mature" TO "service_role";



GRANT ALL ON TABLE "public"."v_otp_sessions_dynamic" TO "anon";
GRANT ALL ON TABLE "public"."v_otp_sessions_dynamic" TO "authenticated";
GRANT ALL ON TABLE "public"."v_otp_sessions_dynamic" TO "service_role";



GRANT ALL ON TABLE "public"."v_app_availability" TO "anon";
GRANT ALL ON TABLE "public"."v_app_availability" TO "authenticated";
GRANT ALL ON TABLE "public"."v_app_availability" TO "service_role";



GRANT ALL ON TABLE "public"."v_christmas_2025_uptime_leaderboard" TO "anon";
GRANT ALL ON TABLE "public"."v_christmas_2025_uptime_leaderboard" TO "authenticated";
GRANT ALL ON TABLE "public"."v_christmas_2025_uptime_leaderboard" TO "service_role";



GRANT ALL ON TABLE "public"."v_christmas_2025_uptime_ranking_live" TO "anon";
GRANT ALL ON TABLE "public"."v_christmas_2025_uptime_ranking_live" TO "authenticated";
GRANT ALL ON TABLE "public"."v_christmas_2025_uptime_ranking_live" TO "service_role";



GRANT ALL ON TABLE "public"."v_christmas_2025_uptime_ranking" TO "anon";
GRANT ALL ON TABLE "public"."v_christmas_2025_uptime_ranking" TO "authenticated";
GRANT ALL ON TABLE "public"."v_christmas_2025_uptime_ranking" TO "service_role";



GRANT ALL ON TABLE "public"."v_otp_sessions_with_retry" TO "anon";
GRANT ALL ON TABLE "public"."v_otp_sessions_with_retry" TO "authenticated";
GRANT ALL ON TABLE "public"."v_otp_sessions_with_retry" TO "service_role";



GRANT ALL ON TABLE "public"."v_otp_sessions_with_status" TO "anon";
GRANT ALL ON TABLE "public"."v_otp_sessions_with_status" TO "authenticated";
GRANT ALL ON TABLE "public"."v_otp_sessions_with_status" TO "service_role";



GRANT ALL ON TABLE "public"."v_rate_limit_config_active" TO "anon";
GRANT ALL ON TABLE "public"."v_rate_limit_config_active" TO "authenticated";
GRANT ALL ON TABLE "public"."v_rate_limit_config_active" TO "service_role";



GRANT ALL ON TABLE "public"."v_rate_limit_usage" TO "anon";
GRANT ALL ON TABLE "public"."v_rate_limit_usage" TO "authenticated";
GRANT ALL ON TABLE "public"."v_rate_limit_usage" TO "service_role";



GRANT ALL ON TABLE "public"."v_referral_stats" TO "anon";
GRANT ALL ON TABLE "public"."v_referral_stats" TO "authenticated";
GRANT ALL ON TABLE "public"."v_referral_stats" TO "service_role";



GRANT ALL ON TABLE "public"."v_sims_with_status" TO "anon";
GRANT ALL ON TABLE "public"."v_sims_with_status" TO "authenticated";
GRANT ALL ON TABLE "public"."v_sims_with_status" TO "service_role";



GRANT ALL ON TABLE "public"."v_sim_activity_summary" TO "anon";
GRANT ALL ON TABLE "public"."v_sim_activity_summary" TO "authenticated";
GRANT ALL ON TABLE "public"."v_sim_activity_summary" TO "service_role";



GRANT ALL ON TABLE "public"."v_sim_health_status" TO "anon";
GRANT ALL ON TABLE "public"."v_sim_health_status" TO "authenticated";
GRANT ALL ON TABLE "public"."v_sim_health_status" TO "service_role";



GRANT ALL ON TABLE "public"."v_sim_otp_stats" TO "anon";
GRANT ALL ON TABLE "public"."v_sim_otp_stats" TO "authenticated";
GRANT ALL ON TABLE "public"."v_sim_otp_stats" TO "service_role";



GRANT ALL ON TABLE "public"."v_sim_otp_stats_recent" TO "anon";
GRANT ALL ON TABLE "public"."v_sim_otp_stats_recent" TO "authenticated";
GRANT ALL ON TABLE "public"."v_sim_otp_stats_recent" TO "service_role";



GRANT ALL ON TABLE "public"."v_sim_performance_metrics" TO "anon";
GRANT ALL ON TABLE "public"."v_sim_performance_metrics" TO "authenticated";
GRANT ALL ON TABLE "public"."v_sim_performance_metrics" TO "service_role";



GRANT ALL ON TABLE "public"."v_sim_stats_with_number" TO "anon";
GRANT ALL ON TABLE "public"."v_sim_stats_with_number" TO "authenticated";
GRANT ALL ON TABLE "public"."v_sim_stats_with_number" TO "service_role";



GRANT ALL ON TABLE "public"."v_sms_messages_full" TO "anon";
GRANT ALL ON TABLE "public"."v_sms_messages_full" TO "authenticated";
GRANT ALL ON TABLE "public"."v_sms_messages_full" TO "service_role";



GRANT ALL ON TABLE "public"."v_user_sessions" TO "anon";
GRANT ALL ON TABLE "public"."v_user_sessions" TO "authenticated";
GRANT ALL ON TABLE "public"."v_user_sessions" TO "service_role";



GRANT ALL ON TABLE "public"."vouchers" TO "anon";
GRANT ALL ON TABLE "public"."vouchers" TO "authenticated";
GRANT ALL ON TABLE "public"."vouchers" TO "service_role";



GRANT ALL ON TABLE "public"."v_user_transaction_logs" TO "anon";
GRANT ALL ON TABLE "public"."v_user_transaction_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."v_user_transaction_logs" TO "service_role";



GRANT ALL ON TABLE "public"."v_vouchers_with_usage" TO "anon";
GRANT ALL ON TABLE "public"."v_vouchers_with_usage" TO "authenticated";
GRANT ALL ON TABLE "public"."v_vouchers_with_usage" TO "service_role";



GRANT ALL ON TABLE "public"."voucher_usage" TO "anon";
GRANT ALL ON TABLE "public"."voucher_usage" TO "authenticated";
GRANT ALL ON TABLE "public"."voucher_usage" TO "service_role";



GRANT ALL ON TABLE "public"."wallet_topups" TO "anon";
GRANT ALL ON TABLE "public"."wallet_topups" TO "authenticated";
GRANT ALL ON TABLE "public"."wallet_topups" TO "service_role";



GRANT ALL ON TABLE "public"."wallet_transactions" TO "anon";
GRANT ALL ON TABLE "public"."wallet_transactions" TO "authenticated";
GRANT ALL ON TABLE "public"."wallet_transactions" TO "service_role";



GRANT ALL ON TABLE "public"."withdrawal_payment_methods" TO "anon";
GRANT ALL ON TABLE "public"."withdrawal_payment_methods" TO "authenticated";
GRANT ALL ON TABLE "public"."withdrawal_payment_methods" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";































