CREATE OR REPLACE FUNCTION grest.pool_opcert(_pool_bech32 text)
RETURNS JSON STABLE LANGUAGE PLPGSQL AS $$
BEGIN
    RETURN ( SELECT json_build_object(
        'op_cert', b.op_cert,
        'op_cert_counter', b.op_cert_counter
    )
    FROM public.block AS b
    INNER JOIN public.slot_leader AS sl ON b.slot_leader_id = sl.id
    INNER JOIN public.pool_hash AS ph ON sl.pool_hash_id = ph.id
    WHERE ph.view = _pool_bech32
    ORDER BY b.slot_no DESC
    LIMIT 1
    );
END; $$;
