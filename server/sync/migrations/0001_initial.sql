CREATE TABLE IF NOT EXISTS library (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton), id uuid NOT NULL UNIQUE,
  state text NOT NULL CHECK (state IN ('uploading','ready')), seq bigint NOT NULL DEFAULT 0,
  uploader_device_id uuid NOT NULL, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS records (
  kind text NOT NULL CHECK (kind IN ('note','folder')), id uuid NOT NULL,
  rev integer NOT NULL CHECK (rev > 0), seq bigint NOT NULL, digest text NOT NULL CHECK (digest ~ '^[0-9a-f]{64}$'), row jsonb NOT NULL CHECK (jsonb_typeof(row) = 'object'),
  PRIMARY KEY(kind,id)
);
CREATE INDEX IF NOT EXISTS records_seq_idx ON records(seq);
CREATE TABLE IF NOT EXISTS blobs (
  hash text PRIMARY KEY CHECK (hash ~ '^[0-9a-f]{64}$'), mime text NOT NULL, size bigint NOT NULL,
  data bytea NOT NULL DEFAULT ''::bytea, complete boolean NOT NULL DEFAULT false
);
CREATE TABLE IF NOT EXISTS devices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text NOT NULL, refresh_hash text NOT NULL,
  previous_refresh_hash text, previous_until timestamptz, created_at timestamptz NOT NULL DEFAULT now(),
  last_seen timestamptz NOT NULL DEFAULT now(), revoked_at timestamptz
);
CREATE TABLE IF NOT EXISTS schema_migrations(version text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now());

CREATE OR REPLACE FUNCTION sync_push(p_library uuid, p_device uuid, p_rows jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE lib library%ROWTYPE; item jsonb; current_row records%ROWTYPE; conflicts jsonb := '[]'::jsonb;
        results jsonb := '[]'::jsonb; next_seq bigint; out_rev integer; out_seq bigint; unchanged boolean;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM devices WHERE id=p_device AND revoked_at IS NULL) THEN RETURN jsonb_build_object('error','auth'); END IF;
  SELECT * INTO lib FROM library WHERE singleton FOR UPDATE;
  IF NOT FOUND OR lib.id <> p_library THEN RETURN jsonb_build_object('error','library'); END IF;
  IF lib.state = 'uploading' AND lib.uploader_device_id <> p_device THEN RETURN jsonb_build_object('error','uploading'); END IF;
  IF jsonb_typeof(p_rows) <> 'array' OR jsonb_array_length(p_rows) > 50 THEN RETURN jsonb_build_object('error','input'); END IF;
  FOR item IN SELECT value FROM jsonb_array_elements(p_rows) LOOP
    SELECT * INTO current_row FROM records WHERE kind=item->>'kind' AND id=(item->>'id')::uuid;
    IF FOUND THEN
      IF current_row.digest <> item->>'digest' AND current_row.rev <> (item->>'baseRev')::integer THEN
        conflicts := conflicts || jsonb_build_array(jsonb_build_object('kind',current_row.kind,'id',current_row.id,'rev',current_row.rev,'seq',current_row.seq,'digest',current_row.digest,'row',current_row.row));
      END IF;
    ELSIF (item->>'baseRev')::integer <> 0 THEN
      conflicts := conflicts || jsonb_build_array(jsonb_build_object('kind',item->>'kind','id',item->>'id','missing',true));
    END IF;
  END LOOP;
  IF jsonb_array_length(conflicts)>0 THEN RETURN jsonb_build_object('conflicts',conflicts); END IF;
  FOR item IN SELECT value FROM jsonb_array_elements(p_rows) LOOP
    SELECT * INTO current_row FROM records WHERE kind=item->>'kind' AND id=(item->>'id')::uuid;
    unchanged := FOUND AND current_row.digest=item->>'digest';
    IF unchanged THEN out_rev:=current_row.rev; out_seq:=current_row.seq;
    ELSE
      UPDATE library SET seq=seq+1 WHERE singleton RETURNING seq INTO next_seq;
      out_rev:=CASE WHEN current_row.id IS NULL THEN 1 ELSE current_row.rev+1 END; out_seq:=next_seq;
      INSERT INTO records(kind,id,rev,seq,digest,row) VALUES(item->>'kind',(item->>'id')::uuid,out_rev,out_seq,item->>'digest',item->'row')
        ON CONFLICT(kind,id) DO UPDATE SET rev=excluded.rev,seq=excluded.seq,digest=excluded.digest,row=excluded.row;
    END IF;
    results:=results || jsonb_build_array(jsonb_build_object('kind',item->>'kind','id',item->>'id','rev',out_rev,'seq',out_seq,'unchanged',unchanged));
  END LOOP;
  SELECT * INTO lib FROM library WHERE singleton;
  RETURN jsonb_build_object('results',results,'head',jsonb_build_object('libraryId',lib.id,'state',lib.state,'seq',lib.seq));
END $$;

CREATE OR REPLACE FUNCTION sync_changes(p_since bigint,p_limit integer)
RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('libraryId',l.id,'rows',coalesce((SELECT jsonb_agg(jsonb_build_object('kind',r.kind,'id',r.id,'rev',r.rev,'seq',r.seq,'digest',r.digest,'row',r.row) ORDER BY r.seq) FROM (SELECT * FROM records WHERE seq>p_since ORDER BY seq LIMIT p_limit) r),'[]'::jsonb),
    'head',l.seq) FROM library l WHERE l.singleton
$$;

CREATE OR REPLACE FUNCTION sync_blob_append(p_hash text,p_offset bigint,p_size bigint,p_mime text,p_data text,p_device uuid)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE b blobs%ROWTYPE; chunk bytea; new_data bytea; lib library%ROWTYPE;
BEGIN
  IF p_size<0 OR p_size>20971520 OR length(p_data)>131072 THEN RETURN jsonb_build_object('error','size'); END IF;
  IF NOT EXISTS (SELECT 1 FROM devices WHERE id=p_device AND revoked_at IS NULL) THEN RETURN jsonb_build_object('error','auth'); END IF;
  SELECT * INTO lib FROM library WHERE singleton;
  IF NOT FOUND THEN RETURN jsonb_build_object('error','library'); END IF;
  IF lib.state='uploading' AND lib.uploader_device_id<>p_device THEN RETURN jsonb_build_object('error','uploading'); END IF;
  INSERT INTO blobs(hash,mime,size,data,complete) VALUES(p_hash,p_mime,p_size,''::bytea,false) ON CONFLICT(hash) DO NOTHING;
  SELECT * INTO b FROM blobs WHERE hash=p_hash FOR UPDATE;
  IF b.complete THEN RETURN jsonb_build_object('offset',b.size,'complete',true); END IF;
  IF b.size<>p_size OR b.mime<>p_mime OR octet_length(b.data)<>p_offset THEN RETURN jsonb_build_object('offset',octet_length(b.data)); END IF;
  chunk:=decode(p_data,'base64');
  IF octet_length(b.data)+octet_length(chunk)>p_size THEN RETURN jsonb_build_object('error','size'); END IF;
  new_data:=b.data||chunk;
  IF octet_length(new_data)=p_size THEN
    IF encode(sha256(new_data),'hex')<>p_hash THEN DELETE FROM blobs WHERE hash=p_hash; RETURN jsonb_build_object('error','hash'); END IF;
    UPDATE blobs SET data=new_data,complete=true WHERE hash=p_hash;
    RETURN jsonb_build_object('offset',p_size,'complete',true);
  END IF;
  UPDATE blobs SET data=new_data WHERE hash=p_hash;
  RETURN jsonb_build_object('offset',octet_length(new_data),'complete',false);
END $$;

CREATE OR REPLACE FUNCTION sync_reset()
RETURNS boolean LANGUAGE plpgsql AS $$ BEGIN DELETE FROM records; DELETE FROM blobs; DELETE FROM library; RETURN true; END $$;
