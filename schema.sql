-- PostgreSQL schema for Todo App
-- ============================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- create roles
do
$$
begin
    if not exists(select 1 FROM pg_roles WHERE rolname = 'anon') then
        CREATE ROLE anon;
    end if;
end
$$ language plpgsql;

create role authenticator noinherit;
grant anon to authenticator;

do
$$
begin
    if not exists(select 1 FROM pg_roles WHERE rolname = 'author') then
        create role author;
    end if;
end
$$ language plpgsql;

grant author to authenticator;


-- We put things inside the basic_auth schema to hide
-- them from public view. Certain public procs/views will
-- refer to helpers and tables inside.
create schema if not exists basic_auth;

create table if not exists
basic_auth.users (
  email    text primary key check ( email ~* '^.+@.+\..+$' ),
  pass     text not null check (length(pass) < 512),
  name     text not null default '' check (length(name) < 512),
  role     name not null check (length(role) < 512),
  verified boolean not null default false
  -- If you like add more columns, or a json column
);


-- role related operations

create or replace function
basic_auth.check_role_exists() returns trigger
  language plpgsql
  as $$
begin
  if not exists (select 1 from pg_roles as r where r.rolname = new.role) then
    raise foreign_key_violation using message =
      'unknown database role: ' || new.role;
    return null;
  end if;
  return new;
end
$$;

drop trigger if exists ensure_user_role_exists on basic_auth.users;
create constraint trigger ensure_user_role_exists
  after insert or update on basic_auth.users
  for each row
  execute procedure basic_auth.check_role_exists();

-- user - password related operations

create or replace function
basic_auth.encrypt_pass() returns trigger
  language plpgsql
  as $$
begin
  if tg_op = 'INSERT' or new.pass <> old.pass then
    new.pass = crypt(new.pass, gen_salt('bf'));
  end if;
  return new;
end
$$;

drop trigger if exists encrypt_pass on basic_auth.users;
create trigger encrypt_pass
  before insert or update on basic_auth.users
  for each row
  execute procedure basic_auth.encrypt_pass();

-- get the role for a given email/password

create or replace function
basic_auth.user_role(email text, pass text) returns name
  language plpgsql
  as $$
begin
  return (
  select role from basic_auth.users
   where users.email = user_role.email
     and users.pass = crypt(user_role.pass, users.pass)
  );
end;
$$;

-- tokens table for validating new users and reset password requests

drop type if exists token_type_enum cascade;
create type token_type_enum as enum ('validation', 'reset');

create table if not exists
basic_auth.tokens (
  token       uuid primary key,
  token_type  token_type_enum not null,
  email       text not null references basic_auth.users (email)
                on delete cascade on update cascade,
  created_at  timestamptz not null default current_date
);



-- email validation

create or replace function
basic_auth.send_validation() returns trigger
  language plpgsql
  as $$
declare
  tok uuid;
begin
  select uuid_generate_v4() into tok;
  insert into basic_auth.tokens (token, token_type, email)
         values (tok, 'validation', new.email);
  perform pg_notify('validate',
    json_build_object(
      'email', new.email,
      'token', tok,
      'token_type', 'validation'
    )::text
  );
  return new;
end
$$;

drop trigger if exists send_validation on basic_auth.users;
create trigger send_validation
  after insert on basic_auth.users
  for each row
  execute procedure basic_auth.send_validation();

-- check if current user has a given role

create or replace function
basic_auth.clearance_for_role(u name) returns void as
$$
declare
  ok boolean;
begin
  select exists (
    select rolname
      from pg_authid
     where pg_has_role(current_user, oid, 'member')
       and rolname = u
  ) into ok;
  if not ok then
    raise invalid_password using message =
      'current user not member of role ' || u;
  end if;
end
$$ LANGUAGE plpgsql;



-- Main schema
-- =============
-- send password reset mail.

create or replace function
request_password_reset(email text) returns void
  language plpgsql
  as $$
declare
  tok uuid;
begin
  delete from basic_auth.tokens
   where token_type = 'reset'
     and tokens.email = request_password_reset.email;

  select uuid_generate_v4() into tok;
  insert into basic_auth.tokens (token, token_type, email)
         values (tok, 'reset', request_password_reset.email);
  perform pg_notify('reset',
    json_build_object(
      'email', request_password_reset.email,
      'token', tok,
      'token_type', 'reset'
    )::text
  );
end;
$$;

-- the actual reset action

create or replace function
reset_password(email text, token uuid, pass text)
  returns void
  language plpgsql
  as $$
declare
  tok uuid;
begin
  if exists(select 1 from basic_auth.tokens
             where tokens.email = reset_password.email
               and tokens.token = reset_password.token
               and token_type = 'reset') then
    update basic_auth.users set pass=reset_password.pass
     where users.email = reset_password.email;

    delete from basic_auth.tokens
     where tokens.email = reset_password.email
       and tokens.token = reset_password.token
       and token_type = 'reset';
  else
    raise invalid_password using message =
      'invalid user or token';
  end if;
  delete from basic_auth.tokens
   where token_type = 'reset'
     and tokens.email = reset_password.email;

  select uuid_generate_v4() into tok;
  insert into basic_auth.tokens (token, token_type, email)
         values (tok, 'reset', reset_password.email);
  perform pg_notify('reset',
    json_build_object(
      'email', reset_password.email,
      'token', tok
    )::text
  );
end;
$$;

-- redacted users view

create or replace function
basic_auth.current_email() returns text
  language plpgsql
  as $$
begin
  return current_setting('postgrest.claims.email');
exception
  -- handle unrecognized configuration parameter error
  when undefined_object then return '';
end;
$$;


create or replace view users as
select actual.role as role,
       '***'::text as pass,
       actual.email as email,
       actual.verified as verified
from basic_auth.users as actual,
     (select rolname
        from pg_authid
       where pg_has_role(current_user, oid, 'member')
     ) as member_of
where actual.role = member_of.rolname
  and (
     actual.role <> 'author'
     or email = basic_auth.current_email()
);


-- update users

create or replace function
update_users() returns trigger
language plpgsql
AS $$
begin
  if tg_op = 'INSERT' then
    perform basic_auth.clearance_for_role(new.role);

    insert into basic_auth.users
      (role, pass, email, verified)
    values
      (new.role, new.pass, new.email,
      coalesce(new.verified, false));
    return new;
  elsif tg_op = 'UPDATE' then
    -- no need to check clearance for old.role because
    -- an ineligible row would not have been available to update (http 404)
    perform basic_auth.clearance_for_role(new.role);

    update basic_auth.users set
      email  = new.email,
      role   = new.role,
      pass   = new.pass,
      verified = coalesce(new.verified, old.verified, false)
      where email = old.email;
    return new;
  elsif tg_op = 'DELETE' then
    -- no need to check clearance for old.role (see previous case)

    delete from basic_auth.users
     where basic_auth.email = old.email;
    return null;
  end if;
end
$$;

drop trigger if exists update_users on users;
create trigger update_users
  instead of insert or update or delete on
    users for each row execute procedure update_users();

-- signup

create or replace function
signup(email text, pass text) returns void
as $$
  insert into basic_auth.users (email, pass, role) values
    (signup.email, signup.pass, 'author');
$$ language sql;


-- login

drop type if exists basic_auth.jwt_claims cascade;
create type basic_auth.jwt_claims AS (role text, email text);

create or replace function
login(email text, pass text) returns basic_auth.jwt_claims
  language plpgsql
  as $$
declare
  _role name;
  result basic_auth.jwt_claims;
begin
  select basic_auth.user_role(email, pass) into _role;
  if _role is null then
    raise invalid_password using message = 'invalid user or password';
  end if;
  -- TODO; check verified flag if you care whether users
  -- have validated their emails
  select _role as role, login.email as email into result;
  return result;
end;
$$;

-- Todo App
-- ======
-- Todos

CREATE TABLE IF NOT EXISTS
todos (
    id serial NOT NULL PRIMARY KEY,
    created timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    title varchar(250) NOT NULL,
    author text NOT NULL DEFAULT basic_auth.current_email() REFERENCES basic_auth.users (email)
               ON DELETE CASCADE ON UPDATE CASCADE
);

-- permissions

grant insert on table basic_auth.users, basic_auth.tokens to anon;
grant usage on schema public, basic_auth to anon, author;


grant select on table pg_authid, basic_auth.users to anon;

grant execute on function
  login(text,text),
  request_password_reset(text),
  reset_password(text,uuid,text),
  signup(text, text)
  to anon;



grant select, insert, update, delete
  on basic_auth.tokens, basic_auth.users to author;
grant select, insert, update, delete
  on table todos to author;
grant usage, select on sequence todos_id_seq to author;


-- grant select on todos to anon;
revoke select on todos from anon;

ALTER TABLE todos ENABLE ROW LEVEL SECURITY;

-- drop policy if exists todos_select_unsecure on todos;
-- create policy todos_select_unsecure on todos for select
--   using (true);

CREATE POLICY own_todos ON todos  
  USING(author = basic_auth.current_email());


drop policy if exists authors_eigencreate on todos;
create policy authors_eigencreate on todos for insert
  with check (
    author = basic_auth.current_email()
  );

drop policy if exists authors_eigenedit on todos;
create policy authors_eigenedit on todos for update
  using (author = basic_auth.current_email())
  with check (
    author = basic_auth.current_email()
  );


drop policy if exists authors_eigendelete on todos;
create policy authors_eigendelete on todos for delete
  using (author = basic_auth.current_email());
