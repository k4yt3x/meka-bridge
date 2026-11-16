-- A hand-over is one inbox item carrying every message that settled together, rather than one item
-- per message.
--
-- Which messages belong together is the bridge's to say, and only one item says it. Items posted one
-- after another are read as they reach Meka: the first wakes the session and opens a turn on its
-- own, and the rest wait for that turn's first pause, by which time the agent may have answered
-- half of what somebody said. So the hand-over gets a record of its own, holding what was queue row
-- state while a row was an item: the key it is posted under, the bytes posted, Meka's id for it, and
-- the posts made of it. A queue row keeps what is its message's own, and names the hand-over
-- carrying it.
--
-- Every row that already has a key becomes a hand-over of its own, byte for byte, so an item Meka
-- holds is still asked about under the key it was made with. `not_before` and `last_error` move
-- only from a row still waiting on Meka, where they describe its posts and leave the row; on any
-- other row they describe the row.
CREATE TABLE hand_overs (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    -- The `Idempotency-Key` the item is posted under, minted once when the hand-over is made.
    key         TEXT NOT NULL UNIQUE,
    -- The rendered item. Byte-identical on every post, since Meka refuses the same key with other
    -- words. Dropped once nothing will post it again.
    body        TEXT,
    -- The Meka session the item is, or will be, posted to. Meka scopes keys per session.
    session_id  TEXT NOT NULL,
    -- Meka's id for the item, from the 202.
    item_id     TEXT,
    -- The dropped-message count the item reported, taken off the counter when the hand-over is
    -- made and put back if the item never delivers.
    dropped     INTEGER NOT NULL DEFAULT 0,
    -- Posts of the item, successful or not.
    posts       INTEGER NOT NULL DEFAULT 0,
    -- When the item may be posted again after a post that did not go through.
    not_before  TEXT,
    -- Why the last post did not go through.
    last_error  TEXT,
    -- When the item was rendered, which is what `[bridge].hand_over_within` counts from.
    held_at     TEXT NOT NULL,
    -- When Meka accepted it.
    posted_at   TEXT,
    -- When Meka stops retrying it, as its answer to the post said.
    retry_until TEXT
);

INSERT INTO hand_overs
    (key, body, session_id, item_id, dropped, posts, not_before, last_error, held_at, posted_at,
     retry_until)
SELECT key, body, session_id, item_id, dropped, posts,
       CASE WHEN state = 'in_flight' THEN not_before END,
       CASE WHEN state = 'in_flight' THEN last_error END,
       held_at, posted_at, retry_until
FROM inbound_queue
WHERE key IS NOT NULL
ORDER BY seq;

ALTER TABLE inbound_queue ADD COLUMN hand_over_id INTEGER REFERENCES hand_overs (id);

UPDATE inbound_queue
SET hand_over_id = (SELECT h.id FROM hand_overs h WHERE h.key = inbound_queue.key)
WHERE key IS NOT NULL;

UPDATE inbound_queue
SET not_before = NULL, last_error = NULL
WHERE key IS NOT NULL AND state = 'in_flight';

-- A row left without its hand-over would be a message whose item Meka holds and nothing here can
-- name, and a CHECK constraint is the one thing plain SQL can fail on, so a mismatch aborts the
-- migration.
CREATE TEMP TABLE migration_check (lost INTEGER NOT NULL CHECK (lost = 0));
INSERT INTO migration_check
SELECT (SELECT COUNT(*) FROM inbound_queue WHERE key IS NOT NULL)
     - (SELECT COUNT(*) FROM inbound_queue WHERE hand_over_id IS NOT NULL);
DROP TABLE migration_check;

-- Dropped column by column rather than by rebuilding the table: with foreign keys on, dropping the
-- old table deletes its rows first, which would fire `messages.accounted_by`'s `ON DELETE SET NULL`
-- and lose which hand-over reported each backlog.
DROP INDEX idx_inbound_queue_key;
DROP INDEX idx_inbound_queue_item;
ALTER TABLE inbound_queue DROP COLUMN key;
ALTER TABLE inbound_queue DROP COLUMN body;
ALTER TABLE inbound_queue DROP COLUMN session_id;
ALTER TABLE inbound_queue DROP COLUMN item_id;
ALTER TABLE inbound_queue DROP COLUMN dropped;
ALTER TABLE inbound_queue DROP COLUMN posts;
ALTER TABLE inbound_queue DROP COLUMN held_at;
ALTER TABLE inbound_queue DROP COLUMN posted_at;
ALTER TABLE inbound_queue DROP COLUMN retry_until;

CREATE INDEX idx_inbound_queue_hand_over ON inbound_queue (hand_over_id)
    WHERE hand_over_id IS NOT NULL;
CREATE INDEX idx_hand_overs_item ON hand_overs (item_id) WHERE item_id IS NOT NULL;
