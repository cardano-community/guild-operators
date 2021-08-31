DROP TABLE IF EXISTS grest.pool_info_cache;

CREATE TABLE grest.pool_info_cache (
    id SERIAL PRIMARY KEY,
    tx_id bigint NOT NULL,
    tx_hash text,
    block_time timestamp without time zone,
    pool_hash_id bigint NOT NULL,
    pool_id_bech32 character varying NOT NULL,
    pool_id_hex text NOT NULL,
    active_epoch_no bigint NOT NULL,
    vrf_key_hash text NOT NULL,
    margin double precision NOT NULL,
    fixed_cost lovelace NOT NULL,
    pledge lovelace NOT NULL,
    reward_addr character varying,
    owners character varying [],
    relays jsonb [],
    meta_url character varying,
    meta_hash text,
    pool_status text,
    retiring_epoch uinteger,
    unixtime bigint NOT NULL
);

COMMENT ON TABLE grest.pool_info_cache IS 'A summary of all pool parameters and updates';


DROP FUNCTION IF EXISTS grest.pool_info_insert CASCADE;

CREATE FUNCTION grest.pool_info_insert (
        _update_id bigint,
        _tx_id bigint,
        _hash_id bigint,
        _active_epoch_no bigint,
        _vrf_key_hash hash32type,
        _margin double precision,
        _fixed_cost lovelace,
        _pledge lovelace,
        _reward_addr addr29type,
        _meta_id bigint,
        _unixtime bigint
    )
    RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    _current_epoch_no uinteger;
    _retiring_epoch uinteger;
    _pool_status text;
BEGIN
    SELECT COALESCE(MAX(no), 0) INTO _current_epoch_no FROM public.epoch;

    SELECT pr.retiring_epoch INTO _retiring_epoch
    FROM public.pool_retire AS pr
    WHERE pr.hash_id = _hash_id
    AND pr.announced_tx_id > _tx_id
    ORDER BY pr.id
    LIMIT 1;

    IF _retiring_epoch IS NULL THEN 
        _pool_status := 'registered';
    ELSIF _retiring_epoch > _current_epoch_no THEN
        _pool_status := 'retiring';
    ELSE
        _pool_status := 'retired';
    END IF;

    INSERT INTO grest.pool_info_cache (
        tx_id,
        tx_hash,
        block_time,
        pool_hash_id,
        pool_id_bech32, 
        pool_id_hex,
        active_epoch_no,
        vrf_key_hash,
        margin,
        fixed_cost,
        pledge,
        reward_addr,
        owners,
        relays,
        meta_url,
        meta_hash,
        pool_status,
        retiring_epoch,
        unixtime
    )
    SELECT
        _tx_id,
        encode(tx.hash::bytea, 'hex'), 
        b.time,
        _hash_id,
        ph.view,
        encode(ph.hash_raw::bytea, 'hex'),
        _active_epoch_no,
        encode(_vrf_key_hash::bytea, 'hex'),
        _margin,
        _fixed_cost,
        _pledge,
        sa.view,
        ARRAY(
            SELECT 
                sa.view
            FROM public.pool_owner AS po
            INNER JOIN public.stake_address AS sa ON sa.id = po.addr_id
            WHERE po.registered_tx_id = _tx_id
        ),
        ARRAY(
            SELECT json_build_object(
                'ipv4', pr.ipv4,
                'ipv6', pr.ipv6,
                'dns', pr.dns_name,
                'srv', pr.dns_srv_name,
                'port', pr.port
            ) relay
            FROM public.pool_relay AS pr
            WHERE pr.update_id = _update_id
        ),
        pmr.url,
        encode(pmr.hash::bytea, 'hex'),
        _pool_status,
        _retiring_epoch,
        _unixtime
    FROM public.pool_hash AS ph
    INNER JOIN public.tx ON tx.id = _tx_id
    INNER JOIN public.block AS b ON b.id = tx.block_id
    LEFT JOIN public.pool_metadata_ref AS pmr ON pmr.id = _meta_id
    LEFT JOIN public.stake_address AS sa ON sa.hash_raw = _reward_addr
    WHERE ph.id = _hash_id;
END;
$$;

COMMENT ON FUNCTION grest.pool_info_insert IS 'Internal function to insert a single pool update';


DROP FUNCTION IF EXISTS grest.pool_info_retire_status CASCADE;

CREATE FUNCTION grest.pool_info_retire_status ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE grest.pool_info_cache
    SET
        pool_status = 'retired'
    WHERE
        pool_status = 'retiring'
        AND
        retiring_epoch <= NEW.no;
    RETURN NULL;
END;
$$;

COMMENT ON FUNCTION grest.pool_info_retire_status IS 'Internal function to update pool_info_cache with new retire status based on epoch switch';


DROP FUNCTION IF EXISTS grest.pool_info_retire_update CASCADE;

CREATE FUNCTION grest.pool_info_retire_update (
        _hash_id bigint,
        _announced_tx_id bigint,
        _retiring_epoch uinteger,
        _unixtime bigint
    )
    RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    _current_epoch_no uinteger;
    _pool_status text;
BEGIN
    SELECT COALESCE(MAX(no), 0) INTO _current_epoch_no FROM public.epoch;

    IF _retiring_epoch > _current_epoch_no THEN
        _pool_status := 'retiring';
    ELSE
        _pool_status := 'retired';
    END IF;

    UPDATE grest.pool_info_cache
    SET
        pool_status = _pool_status,
        retiring_epoch = _retiring_epoch,
        unixtime = _unixtime
    WHERE
        pool_hash_id = _hash_id
        AND
        tx_id < _announced_tx_id
        AND
        tx_id = (SELECT MAX(tx_id) FROM grest.pool_info_cache);
END;
$$;

COMMENT ON FUNCTION grest.pool_info_retire_update IS 'Internal function to update pool_info_cache with new retire status based on new retire entries';


DROP FUNCTION IF EXISTS grest.pool_info_update CASCADE;

CREATE FUNCTION grest.pool_info_update ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    _latest_pool_info_tx_id bigint;
    _latest_unixtime_cache bigint;
    _current_unixtime bigint;
    _current_pool_update_block_id bigint DEFAULT NULL;
    rec RECORD;
BEGIN
    SELECT COALESCE(MAX(tx_id), 0) INTO _latest_pool_info_tx_id FROM grest.pool_info_cache;
    SELECT COALESCE(MAX(unixtime), 0) INTO _latest_unixtime_cache FROM grest.pool_info_cache;
    SELECT EXTRACT(EPOCH FROM NOW()) INTO _current_unixtime;
    IF (_current_unixtime - _latest_unixtime_cache) > 300 THEN
        -- Add all new entries in pool_update table older than 5 blocks
        FOR rec IN (SELECT * FROM public.pool_update AS pu WHERE pu.registered_tx_id > _latest_pool_info_tx_id) LOOP
            SELECT block_id INTO _current_pool_update_block_id FROM public.tx AS t WHERE t.id = rec.registered_tx_id;
            IF _current_pool_update_block_id IS NOT NULL AND (NEW.id - _current_pool_update_block_id) > 5 THEN
                PERFORM grest.pool_info_insert(
                    rec.id,
                    rec.registered_tx_id,
                    rec.hash_id,
                    rec.active_epoch_no,
                    rec.vrf_key_hash,
                    rec.margin,
                    rec.fixed_cost,
                    rec.pledge,
                    rec.reward_addr,
                    rec.meta_id,
                    _current_unixtime
                );
            END IF;
        END LOOP;
        -- Check all new entries in pool_retire table older than 5 blocks
        FOR rec IN (SELECT * FROM public.pool_retire AS pr WHERE pr.announced_tx_id > _latest_pool_info_tx_id) LOOP
            SELECT block_id INTO _current_pool_update_block_id FROM public.tx AS t WHERE t.id = rec.announced_tx_id;
            IF _current_pool_update_block_id IS NOT NULL AND (NEW.id - _current_pool_update_block_id) > 5 THEN
                PERFORM grest.pool_info_retire_update(
                    rec.hash_id,
                    rec.announced_tx_id,
                    rec.retiring_epoch,
                    _current_unixtime
                );
            END IF;
        END LOOP;
    END IF;
    RETURN NULL;
END;
$$;

COMMENT ON FUNCTION grest.pool_info_update IS 'Internal function to insert all new pool updates into pool_info cache table';


-- Create pool_info_cache trigger based on new blocks
DROP TRIGGER IF EXISTS pool_info_update_trigger ON public.block;

CREATE TRIGGER pool_info_update_trigger
    AFTER INSERT ON public.block
    FOR EACH ROW
        EXECUTE PROCEDURE grest.pool_info_update ();

-- Create pool_info_cache trigger based on new epoch for retire status update
DROP TRIGGER IF EXISTS pool_info_retire_status_trigger ON public.epoch;

CREATE TRIGGER pool_info_retire_status_trigger
    AFTER INSERT ON public.epoch
    FOR EACH ROW
        EXECUTE PROCEDURE grest.pool_info_retire_status ();
