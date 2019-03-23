CREATE TABLE xmit_history (
        xmit_key		SERIAL PRIMARY KEY,
        freq_key		INTEGER REFERENCES freqs (freq_key),
	source			TEXT NOT NULL DEFAULT 'scanner',
        file                    TEXT NOT NULL,
	duration		INTERVAL,
	detect_voice		BOOLEAN,
	class   		VARCHAR(1) DEFAULT 'U',
	entered			TIMESTAMPTZ NOT NULL DEFAULT current_timestamp
);

GRANT SELECT,UPDATE,INSERT,DELETE ON xmit_history TO script;
GRANT SELECT,UPDATE ON xmit_history_xmit_key_seq TO script;
