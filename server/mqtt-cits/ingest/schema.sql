-- CITS-to-go Paketdatenbank (TimescaleDB). Wird beim ersten Start des Ingest-Dienstes angelegt.
CREATE EXTENSION IF NOT EXISTS timescaledb;

CREATE TABLE IF NOT EXISTS packets (
    time            timestamptz      NOT NULL,   -- Empfang am Server (UTC)
    node            text             NOT NULL,   -- Empfänger (its/<node>/packet)
    msg_type        text,                        -- CAM, DENM, SPATEM, MAPEM, …
    message_id      smallint,
    btp_port        integer,
    station_id      bigint,                      -- ITS-Stations-ID des Senders
    secured         boolean,                     -- GeoNetworking-Sicherheitshülle vorhanden
    lat             double precision,            -- Senderposition (CAM-Referenz bzw. GN-Header)
    lon             double precision,
    station_type    smallint,                    -- 5 = Pkw, 15 = Straßenstation, …
    speed_kmh       real,
    heading         real,                        -- Grad, 0 = Nord
    vehicle_role    smallint,
    light_bar       boolean,
    siren           boolean,
    denm_origin     bigint,
    denm_sequence   integer,
    denm_cause      smallint,
    denm_subcause   smallint,
    denm_detection  timestamptz,
    denm_reference  timestamptz,
    denm_validity   integer,                     -- Sekunden
    denm_terminated boolean,
    event_lat       double precision,            -- DENM-Ereignisort
    event_lon       double precision,
    decode_error    text,
    raw             bytea            NOT NULL    -- vollständiges IEEE-802.11-Frame
);
SELECT create_hypertable('packets', 'time', chunk_time_interval => interval '1 day', if_not_exists => true);
CREATE INDEX IF NOT EXISTS packets_node_time    ON packets (node, time DESC);
CREATE INDEX IF NOT EXISTS packets_station_time ON packets (station_id, time DESC);
CREATE INDEX IF NOT EXISTS packets_type_time    ON packets (msg_type, time DESC);

DO $$
BEGIN
    IF NOT (SELECT compression_enabled FROM timescaledb_information.hypertables WHERE hypertable_name = 'packets') THEN
        ALTER TABLE packets SET (timescaledb.compress, timescaledb.compress_segmentby = 'node',
                                 timescaledb.compress_orderby = 'time DESC');
    END IF;
END $$;
SELECT add_compression_policy('packets', interval '7 days', if_not_exists => true);

CREATE TABLE IF NOT EXISTS receivers (
    node        text PRIMARY KEY,
    status      text,
    info        jsonb,
    name        text GENERATED ALWAYS AS (info->>'name') STORED,
    first_seen  timestamptz NOT NULL DEFAULT now(),
    updated     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS receiver_stats (
    time  timestamptz NOT NULL,
    node  text        NOT NULL,
    stats jsonb       NOT NULL
);
SELECT create_hypertable('receiver_stats', 'time', chunk_time_interval => interval '7 days', if_not_exists => true);

-- Stündliche Zusammenfassung pro Empfänger und Nachrichtentyp (z. B. für Grafana)
CREATE MATERIALIZED VIEW IF NOT EXISTS packets_hourly
WITH (timescaledb.continuous) AS
SELECT time_bucket('1 hour', time) AS bucket, node, msg_type,
       count(*) AS packets
FROM packets GROUP BY bucket, node, msg_type
WITH NO DATA;
SELECT add_continuous_aggregate_policy('packets_hourly',
    start_offset => interval '3 days', end_offset => interval '1 hour',
    schedule_interval => interval '30 minutes', if_not_exists => true);
