DROP FUNCTION IF EXISTS grest.addr_txs (text, uinteger, character varying);

CREATE FUNCTION grest.addr_txs (_address text, _limit uinteger DEFAULT 1000, _orderby character varying DEFAULT 'desc' ::character varying)
    RETURNS TABLE (
        in_addrs jsonb,
        out_addrs jsonb,
        tx_hash text,
        block_idx uinteger,
        block_hash text,
        epoch_no uinteger,
        epoch_slot_no uinteger,
        block_time timestamp without time zone,
        stake_addr character varying,
        is_withdrawal text,
        is_delegation text,
        script_data_hash text)
    LANGUAGE plpgsql
    STABLE
    AS $$
BEGIN
    RETURN QUERY (
        SELECT
            x.in_addrs, x.out_addrs, encode(txhash::bytea, 'hex') AS tx_hash, x.block_idx, encode(bhash::bytea, 'hex') AS block_hash, x.epoch_no, x.epoch_slot_no, x.block_time, coalesce(stakeDel, stakeWith) AS stake_addr, x.is_withdrawal, x.is_delegation, 'TODO' AS script_data_hash FROM (
            SELECT
                (
                    SELECT
                        jsonb_agg(txo.address)
                    FROM tx_out txo, tx_in txi
                WHERE
                    txo.index = txi.tx_out_index
                    AND txo.tx_id = txi.tx_out_id
                    AND txi.tx_in_id = txb.id) in_addrs, (
                SELECT
                    jsonb_agg(txo.address) AS addr_list FROM tx_out txo
            WHERE
                txo.tx_id = txb.id GROUP BY txo.tx_id) out_addrs, CASE WHEN EXISTS (
                SELECT
                    NULL FROM delegation d
                WHERE
                    d.tx_id = txb.id) THEN
                'yes'
            ELSE
                'no'
            END AS is_delegation, CASE WHEN EXISTS (
                SELECT
                    NULL FROM withdrawal w
                WHERE
                    w.tx_id = txb.id) THEN
                'yes'
            ELSE
                'no'
            END AS is_withdrawal, (
                SELECT
                    sa.view FROM stake_address sa
                    INNER JOIN delegation d ON sa.id = d.addr_id
                        AND d.tx_id = txb.id) stakeDel, (
                    SELECT
                        sa.view FROM stake_address sa
                    INNER JOIN withdrawal d ON sa.id = d.addr_id
                        AND d.tx_id = txb.id) stakeWith, txb.hash AS txhash, txb.block_index AS block_idx, b.hash AS bhash, b.epoch_no, b.epoch_slot_no, b.time AS block_time FROM block b, tx txb
        WHERE
            txb.id IN (
                SELECT
                    my_tx_id FROM ((
                        SELECT
                            txo.tx_id AS my_tx_id FROM tx_out txo
                        WHERE
                            txo.address = _address ORDER BY (
                                CASE WHEN _orderby = 'desc' THEN
                                    txo.tx_id
                                END) DESC, txo.tx_id ASC LIMIT _limit)
        UNION ALL (
            SELECT
                txb.id AS my_tx_id FROM tx_out txo, tx_in txi, tx txb
            WHERE
                txo.index = txi.tx_out_index
                AND txo.tx_id = txi.tx_out_id
                AND txi.tx_in_id = txb.id
                AND txo.address = _address ORDER BY (
                    CASE WHEN _orderby = 'desc' THEN
                        txb.id
                    END) DESC, txb.id ASC LIMIT _limit)) x ORDER BY (
        CASE WHEN _orderby = 'desc' THEN
            my_tx_id
        END) DESC, my_tx_id ASC LIMIT _limit)
AND txb.block_id = b.id) x);
END;
$$;

COMMENT ON FUNCTION grest.addr_txs IS 'Get up to _limit transactions associated WITH a given _address';
