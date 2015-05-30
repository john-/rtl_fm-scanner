CREATE TABLE xmit_history (
        xmit_key		SERIAL PRIMARY KEY,
        freq_key		INTEGER REFERENCES freqs (freq_key),
	source			TEXT NOT NULL DEFAULT 'scanner',
	start			TIMESTAMPTZ NOT NULL,
	stop			TIMESTAMPTZ NOT NULL,
	entered			TIMESTAMPTZ NOT NULL DEFAULT current_timestamp
);

GRANT SELECT,INSERT ON xmit_history TO script;
GRANT SELECT,UPDATE ON xmit_history_xmit_key_seq TO script;
