CREATE OR REPLACE FUNCTION sync_changes(p_since bigint,p_limit integer)
RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('libraryId',l.id,'rows',coalesce((
    SELECT jsonb_agg(jsonb_build_object(
      'kind',r.kind,'id',r.id,'rev',r.rev,'seq',r.seq,'digest',r.digest,
      'row',r.row,'bytes',octet_length(r.row::text)
    ) ORDER BY r.seq)
    FROM (SELECT * FROM records WHERE seq>p_since ORDER BY seq LIMIT p_limit) r
  ),'[]'::jsonb),'head',l.seq)
  FROM library l WHERE l.singleton
$$;
