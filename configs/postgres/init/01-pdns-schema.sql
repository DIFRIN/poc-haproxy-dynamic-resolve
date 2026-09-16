-- ===========================================================================
-- PowerDNS authoritative schema (gsql/PostgreSQL backend).
--
-- Standard schema, dumped from the running database so it matches exactly
-- what the servers were validated against. Applied automatically by the
-- postgres image on first initialisation of an empty data directory.
--
-- IF YOU RE-DUMP THIS FILE, REMOVE THE pg_dump GUARD LINES. Modern pg_dump
-- brackets its output with `\restrict <token>` ... `\unrestrict <token>`.
-- A dump restored through psql by hand is fine, but this file is fed to psql
-- by the postgres image with ON_ERROR_STOP=1, and a lone `\unrestrict` aborts
-- the whole initialisation with
--   \unrestrict: not currently in restricted mode
-- taking the container down with exit 3 and leaving an EMPTY database. That
-- happens whenever the leading `\restrict` is absent or stripped -- which it
-- is here, since the file opens with this comment block. Both guard lines
-- must go; they carry no schema meaning.
-- ===========================================================================

CREATE TABLE public.comments (
    id integer NOT NULL,
    domain_id integer NOT NULL,
    name character varying(255) NOT NULL,
    type character varying(10) NOT NULL,
    modified_at integer NOT NULL,
    account character varying(40) DEFAULT NULL::character varying,
    comment character varying(65535) NOT NULL,
    CONSTRAINT c_lowercase_name CHECK (((name)::text = lower((name)::text)))
);
CREATE SEQUENCE public.comments_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
ALTER SEQUENCE public.comments_id_seq OWNED BY public.comments.id;
CREATE TABLE public.cryptokeys (
    id integer NOT NULL,
    domain_id integer,
    flags integer NOT NULL,
    active boolean,
    published boolean DEFAULT true,
    content text
);
CREATE SEQUENCE public.cryptokeys_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
ALTER SEQUENCE public.cryptokeys_id_seq OWNED BY public.cryptokeys.id;
CREATE TABLE public.domainmetadata (
    id integer NOT NULL,
    domain_id integer,
    kind character varying(32),
    content text
);
CREATE SEQUENCE public.domainmetadata_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
ALTER SEQUENCE public.domainmetadata_id_seq OWNED BY public.domainmetadata.id;
CREATE TABLE public.domains (
    id integer NOT NULL,
    name character varying(255) NOT NULL,
    master character varying(128) DEFAULT NULL::character varying,
    last_check integer,
    type text NOT NULL,
    notified_serial bigint,
    account character varying(40) DEFAULT NULL::character varying,
    options text,
    catalog text,
    CONSTRAINT c_lowercase_name CHECK (((name)::text = lower((name)::text)))
);
CREATE SEQUENCE public.domains_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
ALTER SEQUENCE public.domains_id_seq OWNED BY public.domains.id;
CREATE TABLE public.records (
    id bigint NOT NULL,
    domain_id integer,
    name character varying(255) DEFAULT NULL::character varying,
    type character varying(10) DEFAULT NULL::character varying,
    content character varying(65535) DEFAULT NULL::character varying,
    ttl integer,
    prio integer,
    disabled boolean DEFAULT false,
    ordername character varying(255),
    auth boolean DEFAULT true,
    CONSTRAINT c_lowercase_name CHECK (((name)::text = lower((name)::text)))
);
CREATE SEQUENCE public.records_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
ALTER SEQUENCE public.records_id_seq OWNED BY public.records.id;
CREATE TABLE public.supermasters (
    ip inet NOT NULL,
    nameserver character varying(255) NOT NULL,
    account character varying(40) NOT NULL
);
CREATE TABLE public.tsigkeys (
    id integer NOT NULL,
    name character varying(255),
    algorithm character varying(50),
    secret character varying(255),
    CONSTRAINT c_lowercase_name CHECK (((name)::text = lower((name)::text)))
);
CREATE SEQUENCE public.tsigkeys_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
ALTER SEQUENCE public.tsigkeys_id_seq OWNED BY public.tsigkeys.id;
ALTER TABLE ONLY public.comments ALTER COLUMN id SET DEFAULT nextval('public.comments_id_seq'::regclass);
ALTER TABLE ONLY public.cryptokeys ALTER COLUMN id SET DEFAULT nextval('public.cryptokeys_id_seq'::regclass);
ALTER TABLE ONLY public.domainmetadata ALTER COLUMN id SET DEFAULT nextval('public.domainmetadata_id_seq'::regclass);
ALTER TABLE ONLY public.domains ALTER COLUMN id SET DEFAULT nextval('public.domains_id_seq'::regclass);
ALTER TABLE ONLY public.records ALTER COLUMN id SET DEFAULT nextval('public.records_id_seq'::regclass);
ALTER TABLE ONLY public.tsigkeys ALTER COLUMN id SET DEFAULT nextval('public.tsigkeys_id_seq'::regclass);
ALTER TABLE ONLY public.comments
    ADD CONSTRAINT comments_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.cryptokeys
    ADD CONSTRAINT cryptokeys_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.domainmetadata
    ADD CONSTRAINT domainmetadata_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.domains
    ADD CONSTRAINT domains_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.records
    ADD CONSTRAINT records_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.supermasters
    ADD CONSTRAINT supermasters_pkey PRIMARY KEY (ip, nameserver);
ALTER TABLE ONLY public.tsigkeys
    ADD CONSTRAINT tsigkeys_pkey PRIMARY KEY (id);
CREATE INDEX catalog_idx ON public.domains USING btree (catalog);
CREATE INDEX comments_domain_id_idx ON public.comments USING btree (domain_id);
CREATE INDEX comments_name_type_idx ON public.comments USING btree (name, type);
CREATE INDEX comments_order_idx ON public.comments USING btree (domain_id, modified_at);
CREATE INDEX domain_id ON public.records USING btree (domain_id);
CREATE INDEX domainidindex ON public.cryptokeys USING btree (domain_id);
CREATE INDEX domainidmetaindex ON public.domainmetadata USING btree (domain_id);
CREATE UNIQUE INDEX name_index ON public.domains USING btree (name);
CREATE UNIQUE INDEX namealgoindex ON public.tsigkeys USING btree (name, algorithm);
CREATE INDEX nametype_index ON public.records USING btree (name, type);
CREATE INDEX rec_name_index ON public.records USING btree (name);
CREATE INDEX recordorder ON public.records USING btree (domain_id, ordername text_pattern_ops);
ALTER TABLE ONLY public.cryptokeys
    ADD CONSTRAINT cryptokeys_domain_id_fkey FOREIGN KEY (domain_id) REFERENCES public.domains(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.comments
    ADD CONSTRAINT domain_exists FOREIGN KEY (domain_id) REFERENCES public.domains(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.records
    ADD CONSTRAINT domain_exists FOREIGN KEY (domain_id) REFERENCES public.domains(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.domainmetadata
    ADD CONSTRAINT domainmetadata_domain_id_fkey FOREIGN KEY (domain_id) REFERENCES public.domains(id) ON DELETE CASCADE;
