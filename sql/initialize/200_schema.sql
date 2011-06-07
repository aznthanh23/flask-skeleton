-- module home's models
CREATE TABLE public.h1 (
  id SERIAL,
  val TEXT,
  PRIMARY KEY(id)
);

CREATE TABLE public.h2 (
  id SERIAL,
  val TEXT,
  val2 TEXT,
  PRIMARY KEY(id)
);

-- module mod1's models
CREATE SCHEMA mod1;
CREATE TABLE mod1.h1 (
  id SERIAL,
  val2 TEXT,
  PRIMARY KEY(id)
);

-- module mod3's models
CREATE TABLE public.page (
  id SERIAL,
  url TEXT,
  PRIMARY KEY(id)
);
CREATE UNIQUE INDEX page_url_udx ON public.page(LOWER(url));

CREATE TABLE public.tag (
  id SERIAL,
  name TEXT,
  PRIMARY KEY(id)
);
CREATE UNIQUE INDEX tag_name_udx ON public.tag(LOWER(name));

CREATE TABLE public.page_tags (
  page_id INT NOT NULL,
  tag_id INT NOT NULL,
  PRIMARY KEY(page_id, tag_id),
  FOREIGN KEY(page_id) REFERENCES public.page(id),
  FOREIGN KEY(tag_id) REFERENCES public.tag(id)
);
CREATE UNIQUE INDEX page_tags_tag_page_id_udx ON public.page_tags (tag_id, page_id);


-- BEGIN: aaa's schema
CREATE SCHEMA aaa;
CREATE SCHEMA email;
CREATE SCHEMA shadow;

CREATE TABLE shadow.aaa_email (
  id SERIAL,
  email TEXT NOT NULL,
  user_id INT NOT NULL,
  PRIMARY KEY(id)
);
CREATE UNIQUE INDEX email_email_lower_udx ON shadow.aaa_email(LOWER(email));

CREATE TABLE shadow.aaa_email_confirmation_log (
  id SERIAL NOT NULL,
  email_id INT NOT NULL,
  timestamp_sent TIMESTAMP WITH TIME ZONE NOT NULL,
  ttl INTERVAL NOT NULL DEFAULT '8 hours'::INTERVAL,
  confirmation_code UUID NOT NULL,
  confirmed BOOL NOT NULL DEFAULT FALSE,
  ip_address INET,
  timestamp_confirmed TIMESTAMP WITH TIME ZONE,
  CHECK(confirmed = FALSE OR (confirmed = TRUE AND ip_address IS NOT NULL AND timestamp_confirmed IS NOT NULL)),
  CHECK(EXTRACT(TIMEZONE FROM timestamp_sent) = 0.0),
  -- If timestamp_confirmed IS NULL, the CHECK should pass, otherwise make
  -- sure that we stored the data in UTC.
  CHECK(timestamp_confirmed IS NULL OR EXTRACT(TIMEZONE FROM timestamp_confirmed) = 0.0),
  PRIMARY KEY(id),
  FOREIGN KEY(email_id) REFERENCES shadow.aaa_email(id)
);
CREATE INDEX aaa_email_confirmation_log_email_idx ON shadow.aaa_email_confirmation_log(email_id);
CREATE INDEX aaa_email_confirmation_log_confirmation_code_idx ON shadow.aaa_email_confirmation_log(confirmation_code);

CREATE TABLE shadow.aaa_user (
  id SERIAL,
  hashpass TEXT NOT NULL,
  active BOOL NOT NULL,
  primary_email_id INT NOT NULL,
  registration_utc TIMESTAMP WITH TIME ZONE NOT NULL,
  registration_ip INET NOT NULL,
  max_concurrent_sessions INT NOT NULL DEFAULT 1,
  PRIMARY KEY(id),
  FOREIGN KEY(primary_email_id) REFERENCES shadow.aaa_email(id),
  CHECK(max_concurrent_sessions >= 0),
  CHECK(EXTRACT(TIMEZONE FROM registration_utc) = 0.0)
);
CREATE UNIQUE INDEX aaa_user_primary_email_udx ON shadow.aaa_user(primary_email_id);
ALTER TABLE shadow.aaa_email ADD CONSTRAINT email_user_fk FOREIGN KEY(user_id) REFERENCES shadow.aaa_user(id) INITIALLY DEFERRED;

CREATE TABLE shadow.aaa_login_attempts (
  id SERIAL,
  user_id INT NOT NULL,
  login_utc TIMESTAMP WITH TIME ZONE NOT NULL,
  logout_utc TIMESTAMP WITH TIME ZONE,
  ip_address INET NOT NULL,
  success BOOL NOT NULL,
  notes TEXT,
  PRIMARY KEY(id),
  FOREIGN KEY(user_id) REFERENCES shadow.aaa_user(id),
  CHECK(success OR (NOT success AND notes IS NOT NULL)),
  CHECK(EXTRACT(TIMEZONE FROM login_utc) = 0.0),
  CHECK(logout_utc IS NULL OR EXTRACT(TIMEZONE FROM logout_utc) = 0.0)
);
CREATE INDEX aaa_login_attempts_user_login_idx ON shadow.aaa_login_attempts(user_id, login_utc);

-- Backing store for session information. Column notes: session_id is
-- generated by Flask. start_utc is when the session was created. end_utc is
-- the current planned expiration date of the session. A session can be
-- renewed and have the expiration time pushed out further in the
-- future. When a user logs out, end_utc is reset to NOW() and valid is set
-- to FALSE. If end_utc is moved backwards, its session_id must be
-- invalidated from the cache. renewal_interval is the amount of time that a
-- given end_utc is pushed out. The renewal_interval is tracked on a
-- per-session_id basis because some users may log in from home, work or a
-- friend's computer and will want different session lifetimes based on the
-- physical security and trust that they have with regards to unauthorized
-- access. A session should be cached for half of renewal_interval's life
-- (e.g. if the default is 4hrs, only cache the session for 2hrs so that if a
-- user accesses the site within the last two hours of their session, it will
-- automatically be renewed for another 4hrs hours).
CREATE TABLE shadow.aaa_session (
  session_id TEXT NOT NULL,
  user_id INT NOT NULL,
  ip_addr INET NOT NULL,
  valid BOOL NOT NULL,
  start_utc TIMESTAMP WITH TIME ZONE NOT NULL,
  end_utc TIMESTAMP WITH TIME ZONE NOT NULL,
  renewal_interval INTERVAL NOT NULL DEFAULT '4 hours'::INTERVAL,
  session_type TEXT,
  FOREIGN KEY(user_id) REFERENCES shadow.aaa_user(id),
  CHECK(start_utc < end_utc AND
        end_utc > NOW() AND
        renewal_interval > '0'::INTERVAL),
  CHECK(EXTRACT(TIMEZONE FROM start_utc) = 0.0 AND EXTRACT(TIMEZONE FROM end_utc) = 0.0)
);
-- Indexed for obvious reasons
CREATE UNIQUE INDEX aaa_session_id_valid_udx ON shadow.aaa_session(session_id) WHERE valid = TRUE;

-- A periodic cronjob should mark session invalid based on 'end_utc < NOW()'
CREATE INDEX aaa_session_end_utc_idx ON shadow.aaa_session(end_utc) WHERE valid = TRUE;

-- Use an index scan for a particular user_id to make sure that the number of
-- concurrent session for a user is less than the user's configured max
-- number of concurrent sessions.
CREATE INDEX aaa_session_user_id_idx ON shadow.aaa_session(user_id) WHERE valid = TRUE;



-- Enable this view in the email schema since access to email data should
-- only be done via functions. Under no circumstances should a web process be
-- able to do a 'SELECT *' on email or user information. email batch jobs
-- have access to this data via the email schema (the web user does not have
-- access to this schema, just like the email role does not have access to
-- the rest of the schemas).
CREATE VIEW email.email (id, email, user_id) AS
  SELECT
    e.id, e.email, e.user_id
  FROM
    shadow.aaa_email AS e, shadow.aaa_email_confirmation_log AS ecl
  WHERE
    e.id = ecl.email_id AND ecl.confirmed = TRUE;

-- Only show active users. Easy low hanging fruit to prevent accidents.
CREATE VIEW email."user" (id, primary_email_id) AS
  SELECT id, primary_email_id
  FROM shadow.aaa_user
  WHERE active = TRUE;

-- Note this view is created from a JOIN of two VIEWs. Again, in the email
-- schema because no one web process should have access to see every email
-- address in the system.
CREATE VIEW email.user_emails (user_id, email_id, email, user_primary_email_id) AS
  SELECT u.id, e.id, e.email, u.primary_email_id
  FROM email.email AS e, email."user" AS u
  WHERE e.user_id = u.id;
-- END: aaa's schema
