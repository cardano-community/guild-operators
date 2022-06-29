DROP TABLE IF EXISTS grest.pool_info_cache;

CREATE TABLE grest.pool_info_cache (
    id SERIAL PRIMARY KEY,
    tx_id bigint NOT NULL,
    tx_hash text,
    block_time numeric,
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
    meta_id bigint,
    meta_url character varying,
    meta_hash text,
    pool_status text,
    retiring_epoch word31type
);

COMMENT ON TABLE grest.pool_info_cache IS 'A summary of all pool parameters and updates';

CREATE FUNCTION grest.pool_info_insert (
        _update_id bigint,
        _tx_id bigint,
        _hash_id bigint,
        _active_epoch_no bigint,
        _vrf_key_hash hash32type,
        _margin double precision,
        _fixed_cost lovelace,
        _pledge lovelace,
        _reward_addr_id bigint,
        _meta_id bigint
    )
    RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    _current_epoch_no word31type;
    _retiring_epoch word31type;
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
        meta_id,
        meta_url,
        meta_hash,
        pool_status,
        retiring_epoch
    )
    SELECT
        _tx_id,
        encode(tx.hash::bytea, 'hex'), 
        EXTRACT(epoch from b.time),
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
            WHERE po.pool_update_id = _update_id
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
        _meta_id,
        pmr.url,
        encode(pmr.hash::bytea, 'hex'),
        _pool_status,
        _retiring_epoch
    FROM public.pool_hash AS ph
    INNER JOIN public.tx ON tx.id = _tx_id
    INNER JOIN public.block AS b ON b.id = tx.block_id
    LEFT JOIN public.pool_metadata_ref AS pmr ON pmr.id = _meta_id
    LEFT JOIN public.stake_address AS sa ON sa.id = _reward_addr_id
    WHERE ph.id = _hash_id;
END;
$$;

COMMENT ON FUNCTION grest.pool_info_insert IS 'Internal function to insert a single pool update';

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

CREATE FUNCTION grest.pool_info_retire_update ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    _current_epoch_no word31type;
    _pool_hash_id bigint;
    _latest_pool_update_tx_id bigint;
    _retiring_epoch word31type;
    _pool_status text;
BEGIN
    SELECT COALESCE(MAX(no), 0) INTO _current_epoch_no FROM public.epoch;

    IF (TG_OP = 'DELETE') THEN
        _pool_hash_id := OLD.hash_id;
    ELSIF (TG_OP = 'INSERT') THEN
        _pool_hash_id := NEW.hash_id;
    END IF;
    SELECT COALESCE(MAX(tx_id), 0) INTO _latest_pool_update_tx_id FROM grest.pool_info_cache AS pic WHERE pic.pool_hash_id = _pool_hash_id;

    SELECT pr.retiring_epoch INTO _retiring_epoch
    FROM public.pool_retire AS pr
    WHERE pr.hash_id = _pool_hash_id
    AND pr.announced_tx_id > _latest_pool_update_tx_id
    ORDER BY pr.id
    LIMIT 1;

    IF _retiring_epoch IS NULL THEN 
        _pool_status := 'registered';
    ELSIF _retiring_epoch > _current_epoch_no THEN
        _pool_status := 'retiring';
    ELSE
        _pool_status := 'retired';
    END IF;

    UPDATE grest.pool_info_cache
    SET
        pool_status = _pool_status,
        retiring_epoch = _retiring_epoch
    WHERE
        pool_hash_id = _pool_hash_id
        AND
        tx_id = _latest_pool_update_tx_id;
        
    RETURN NULL;
END;
$$;

COMMENT ON FUNCTION grest.pool_info_retire_update IS 'Internal function to update pool_info cache table based on insert/delete on pool_retire table';

CREATE FUNCTION grest.pool_info_update ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    _latest_pool_update_id integer;
BEGIN
    IF (TG_TABLE_NAME = 'pool_update') THEN
        IF (TG_OP = 'INSERT') THEN
            PERFORM grest.pool_info_insert(
                NEW.id,
                NEW.registered_tx_id,
                NEW.hash_id,
                NEW.active_epoch_no,
                NEW.vrf_key_hash,
                NEW.margin,
                NEW.fixed_cost,
                NEW.pledge,
                NEW.reward_addr_id,
                NEW.meta_id
            );
        ELSIF (TG_OP = 'DELETE') THEN
            DELETE FROM grest.pool_info_cache
            WHERE tx_id = OLD.registered_tx_id;
        END IF;

    ELSIF (TG_TABLE_NAME = 'pool_relay') THEN
        SELECT pic.id INTO _latest_pool_update_id 
        FROM grest.pool_info_cache AS pic 
        INNER JOIN public.pool_update AS pu ON pu.hash_id = pic.pool_hash_id AND pu.registered_tx_id = pic.tx_id
        WHERE pu.id = NEW.update_id;

        IF (_latest_pool_update_id IS NULL) THEN
            RETURN NULL;
        END IF;

        UPDATE grest.pool_info_cache
        SET
            relays = relays || jsonb_build_object (
                                    'ipv4', NEW.ipv4,
                                    'ipv6', NEW.ipv6,
                                    'dns', NEW.dns_name,
                                    'srv', NEW.dns_srv_name,
                                    'port', NEW.port
                                )
        WHERE
            id = _latest_pool_update_id;

    ELSIF (TG_TABLE_NAME = 'pool_owner') THEN
        UPDATE grest.pool_info_cache
        SET
            owners = owners || (SELECT sa.view FROM public.stake_address AS sa WHERE sa.id = NEW.addr_id)
        WHERE
            pool_hash_id = NEW.pool_hash_id
            AND
            tx_id = NEW.registered_tx_id;
    END IF;

    RETURN NULL;
END;
$$;

COMMENT ON FUNCTION grest.pool_info_update IS 'Internal function to insert/delete pool updates in pool_info cache table';


-- Create pool_info_cache trigger based on new/deleted pool updates
DROP TRIGGER IF EXISTS pool_info_update_trigger ON public.pool_update;

CREATE TRIGGER pool_info_update_trigger
    AFTER INSERT OR DELETE ON public.pool_update
    FOR EACH ROW
        EXECUTE FUNCTION grest.pool_info_update ();

-- Create pool_info_cache trigger based on new entry in pool_relay
DROP TRIGGER IF EXISTS pool_info_update_trigger ON public.pool_relay;

CREATE TRIGGER pool_info_update_trigger
    AFTER INSERT ON public.pool_relay
    FOR EACH ROW
        EXECUTE FUNCTION grest.pool_info_update ();

-- Create pool_info_cache trigger based on new entry in pool_owner
DROP TRIGGER IF EXISTS pool_info_update_trigger ON public.pool_owner;

CREATE TRIGGER pool_info_update_trigger
    AFTER INSERT ON public.pool_owner
    FOR EACH ROW
        EXECUTE FUNCTION grest.pool_info_update ();

-- Create pool_info_cache trigger based on new/deleted pool retire entries
DROP TRIGGER IF EXISTS pool_info_retire_update_trigger ON public.pool_retire;

CREATE TRIGGER pool_info_retire_update_trigger
    AFTER INSERT OR DELETE ON public.pool_retire
    FOR EACH ROW
        EXECUTE FUNCTION grest.pool_info_retire_update ();

-- Create pool_info_cache trigger based on new epoch for retire status update
DROP TRIGGER IF EXISTS pool_info_retire_status_trigger ON public.epoch;

CREATE TRIGGER pool_info_retire_status_trigger
    AFTER INSERT ON public.epoch
    FOR EACH ROW
        EXECUTE FUNCTION grest.pool_info_retire_status ();


-- Initialize pool_info_cache table with all current pool data
DO $$
DECLARE
    _latest_pool_info_tx_id bigint;
    rec RECORD;
BEGIN
    SELECT COALESCE(MAX(tx_id), 0) INTO _latest_pool_info_tx_id FROM grest.pool_info_cache;

    FOR rec IN (
        SELECT * FROM public.pool_update AS pu WHERE pu.registered_tx_id > _latest_pool_info_tx_id
    ) LOOP
        PERFORM grest.pool_info_insert(
            rec.id,
            rec.registered_tx_id,
            rec.hash_id,
            rec.active_epoch_no,
            rec.vrf_key_hash,
            rec.margin,
            rec.fixed_cost,
            rec.pledge,
            rec.reward_addr_id,
            rec.meta_id
        );
    END LOOP;

    CREATE INDEX IF NOT EXISTS idx_tx_id ON grest.pool_info_cache (tx_id);
    CREATE INDEX IF NOT EXISTS idx_pool_id_bech32 ON grest.pool_info_cache (pool_id_bech32);
    CREATE INDEX IF NOT EXISTS idx_pool_hash_id ON grest.pool_info_cache (pool_hash_id);
    CREATE INDEX IF NOT EXISTS idx_pool_status ON grest.pool_info_cache (pool_status);
    CREATE INDEX IF NOT EXISTS idx_meta_id ON grest.pool_info_cache (meta_id);
END;
$$;

