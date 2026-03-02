-- ─────────────────────────────────────────────────────────────────────────────
-- Weekly Planner — RLS Fix
-- Run this in Supabase SQL Editor (Database → SQL Editor)
--
-- Root cause: room_members_read policy queries room_members itself → infinite
-- recursion. planner_room_read depends on it → also 500s. Fix: break
-- recursion with SECURITY DEFINER helper functions.
-- ─────────────────────────────────────────────────────────────────────────────


-- ── Step 1: Drop the three recursive / broken policies ───────────────────────

DROP POLICY IF EXISTS "room_members_read" ON public.room_members;
DROP POLICY IF EXISTS "planner_room_read" ON public.planner_data;
DROP POLICY IF EXISTS "rooms_member_read" ON public.rooms;


-- ── Step 2: SECURITY DEFINER helpers (bypass RLS → no recursion) ─────────────

-- Returns TRUE if the calling user is a member of the given room.
CREATE OR REPLACE FUNCTION public.rls_is_room_member(p_room_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.room_members
    WHERE room_id = p_room_id
      AND user_id = auth.uid()
  );
$$;

-- Returns TRUE if the calling user shares any room with another user.
CREATE OR REPLACE FUNCTION public.rls_shares_room_with(p_other UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER STABLE
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.room_members a
    JOIN public.room_members b ON a.room_id = b.room_id
    WHERE a.user_id = auth.uid()
      AND b.user_id = p_other
  );
$$;


-- ── Step 3: Re-create the three policies using the helpers ────────────────────

-- room_members: a member can see the other members of their own rooms
CREATE POLICY "room_members_read" ON public.room_members
  FOR SELECT
  USING ( public.rls_is_room_member(room_members.room_id) );

-- planner_data: room-mates can read each other's planner rows
CREATE POLICY "planner_room_read" ON public.planner_data
  FOR SELECT
  USING ( public.rls_shares_room_with(planner_data.user_id) );

-- rooms: a member can read the room they belong to
CREATE POLICY "rooms_member_read" ON public.rooms
  FOR SELECT
  USING ( public.rls_is_room_member(rooms.id) );


-- ── Step 4: Guarantee the UNIQUE constraint needed for upsert ─────────────────
-- PostgREST's onConflict:'user_id,week_start' requires this constraint.
-- The DO block is idempotent — safe to re-run.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'public.planner_data'::regclass
       AND contype  = 'u'
       AND conname  = 'planner_data_user_id_week_start_key'
  ) THEN
    ALTER TABLE public.planner_data
      ADD CONSTRAINT planner_data_user_id_week_start_key
      UNIQUE (user_id, week_start);
  END IF;
END;
$$;


-- ── Verification queries (optional, run separately to confirm) ────────────────
-- SELECT policyname, cmd, qual FROM pg_policies WHERE tablename IN ('room_members','planner_data','rooms');
-- SELECT conname FROM pg_constraint WHERE conrelid = 'public.planner_data'::regclass AND contype = 'u';
