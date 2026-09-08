-- Punkte-App: Einladungscodes für einen gemeinsamen Haushalt

create table if not exists public.household_invites (
    id uuid primary key default gen_random_uuid(),
    household_id uuid not null references public.households(id) on delete cascade,
    code text not null unique,
    created_by uuid not null references auth.users(id) on delete cascade,
    created_at timestamptz not null default now(),
    expires_at timestamptz not null default (now() + interval '7 days'),
    used_by uuid references auth.users(id) on delete set null,
    used_at timestamptz
);

alter table public.household_invites enable row level security;

create or replace function public.create_household_invite(requested_household_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
    invite_code text;
begin
    if auth.uid() is null then
        raise exception 'Not authenticated';
    end if;

    if not public.is_household_member(requested_household_id)
       and not public.is_household_owner(requested_household_id) then
        raise exception 'Not a household member';
    end if;

    loop
        invite_code := upper(substr(encode(gen_random_bytes(6), 'hex'), 1, 8));
        exit when not exists (
            select 1 from public.household_invites where code = invite_code
        );
    end loop;

    insert into public.household_invites (household_id, code, created_by)
    values (requested_household_id, invite_code, auth.uid());

    return invite_code;
end;
$$;

create or replace function public.join_household_by_code(invite_code text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
    target_household uuid;
begin
    if auth.uid() is null then
        raise exception 'Not authenticated';
    end if;

    select household_id
      into target_household
      from public.household_invites
     where code = upper(trim(invite_code))
       and used_at is null
       and expires_at > now()
     limit 1
     for update;

    if target_household is null then
        raise exception 'Invite code invalid or expired';
    end if;

    insert into public.household_members (household_id, user_id, role)
    values (target_household, auth.uid(), 'member')
    on conflict (household_id, user_id) do nothing;

    update public.household_invites
       set used_by = auth.uid(), used_at = now()
     where code = upper(trim(invite_code))
       and used_at is null;

    return target_household;
end;
$$;

grant execute on function public.create_household_invite(uuid) to authenticated;
grant execute on function public.join_household_by_code(text) to authenticated;
