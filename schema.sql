-- ─────────────────────────────────────────────────────────────────────────────
-- Weekly Planner — Supabase Schema
-- Run this entire file in the Supabase SQL Editor (Database → SQL Editor)
-- ─────────────────────────────────────────────────────────────────────────────

-- ── Tables ────────────────────────────────────────────────────────────────────

-- User profiles (auto-populated from auth.users on signup)
CREATE TABLE IF NOT EXISTS public.profiles (
  id          UUID        PRIMARY KEY REFERENCES auth.users ON DELETE CASCADE,
  email       TEXT,
  full_name   TEXT,
  avatar_url  TEXT,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Planner data — one row per user per week
CREATE TABLE IF NOT EXISTS public.planner_data (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID        NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  week_start  DATE        NOT NULL,
  activities  JSONB       NOT NULL DEFAULT '[]',
  sessions    JSONB       NOT NULL DEFAULT '[]',
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, week_start)
);

-- Sharing rooms
CREATE TABLE IF NOT EXISTS public.rooms (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  code        TEXT        NOT NULL UNIQUE,
  created_by  UUID        NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Room memberships
CREATE TABLE IF NOT EXISTS public.room_members (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  room_id     UUID        NOT NULL REFERENCES public.rooms ON DELETE CASCADE,
  user_id     UUID        NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  joined_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (room_id, user_id)
);

-- ── Realtime ──────────────────────────────────────────────────────────────────

-- Full replica identity so UPDATE/DELETE events carry the old row for filtering
ALTER TABLE public.planner_data  REPLICA IDENTITY FULL;
ALTER TABLE public.room_members  REPLICA IDENTITY FULL;

-- Add tables to the default realtime publication
ALTER PUBLICATION supabase_realtime ADD TABLE public.planner_data;
ALTER PUBLICATION supabase_realtime ADD TABLE public.room_members;

-- ── Row Level Security ────────────────────────────────────────────────────────

ALTER TABLE public.profiles     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.planner_data ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rooms        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.room_members ENABLE ROW LEVEL SECURITY;

-- profiles: readable by any authenticated user; writable only by owner
CREATE POLICY "profiles_select" ON public.profiles
  FOR SELECT USING (auth.role() = 'authenticated');

CREATE POLICY "profiles_upsert" ON public.profiles
  FOR ALL USING (auth.uid() = id) WITH CHECK (auth.uid() = id);

-- planner_data: full access to own rows
CREATE POLICY "planner_own" ON public.planner_data
  FOR ALL USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

-- planner_data: room members can read each other's rows
CREATE POLICY "planner_room_read" ON public.planner_data
  FOR SELECT USING (
    EXISTS (
      SELECT 1
      FROM public.room_members rm1
      JOIN public.room_members rm2 ON rm1.room_id = rm2.room_id
      WHERE rm1.user_id = auth.uid()
        AND rm2.user_id = planner_data.user_id
    )
  );

-- rooms: creator has full control
CREATE POLICY "rooms_creator" ON public.rooms
  FOR ALL USING (auth.uid() = created_by) WITH CHECK (auth.uid() = created_by);

-- rooms: members can read their room
CREATE POLICY "rooms_member_read" ON public.rooms
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.room_members
      WHERE room_id = rooms.id AND user_id = auth.uid()
    )
  );

-- room_members: members can see who else is in their rooms
CREATE POLICY "room_members_read" ON public.room_members
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.room_members rm
      WHERE rm.room_id = room_members.room_id AND rm.user_id = auth.uid()
    )
  );

-- room_members: users can join rooms (insert themselves)
CREATE POLICY "room_members_join" ON public.room_members
  FOR INSERT WITH CHECK (auth.uid() = user_id);

-- room_members: users can leave rooms (delete themselves)
CREATE POLICY "room_members_leave" ON public.room_members
  FOR DELETE USING (auth.uid() = user_id);

-- ── Trigger: auto-create profile on first sign-in ─────────────────────────────

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  INSERT INTO public.profiles (id, email, full_name, avatar_url)
  VALUES (
    new.id,
    new.email,
    new.raw_user_meta_data ->> 'full_name',
    new.raw_user_meta_data ->> 'avatar_url'
  )
  ON CONFLICT (id) DO UPDATE SET
    email      = EXCLUDED.email,
    full_name  = EXCLUDED.full_name,
    avatar_url = EXCLUDED.avatar_url,
    updated_at = now();
  RETURN new;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- ── RPC: join a room by invite code ──────────────────────────────────────────
-- SECURITY DEFINER lets it read the rooms table regardless of the caller's RLS,
-- so users can look up a room before becoming a member.

CREATE OR REPLACE FUNCTION public.join_room(p_code TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_room_id UUID;
  v_code    TEXT;
BEGIN
  SELECT id, code INTO v_room_id, v_code
  FROM public.rooms
  WHERE UPPER(rooms.code) = UPPER(p_code);

  IF v_room_id IS NULL THEN
    RETURN jsonb_build_object('error', 'Room not found');
  END IF;

  INSERT INTO public.room_members (room_id, user_id)
  VALUES (v_room_id, auth.uid())
  ON CONFLICT (room_id, user_id) DO NOTHING;

  RETURN jsonb_build_object('room_id', v_room_id, 'code', v_code);
END;
$$;
