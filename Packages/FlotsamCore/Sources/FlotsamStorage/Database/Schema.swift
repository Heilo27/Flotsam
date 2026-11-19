import GRDB

/// The FR-007-03 schema, as migration 1.
///
/// Version 1 is the full schema (FR-007-17: "Version 1 is the schema in FR-007-03"). The skeleton's `meta`-only
/// migration never shipped, so folding it in here costs nothing and keeps `user_version` equal to the FRD's numbering
/// (AC-007-15: a version-0 database migrates to 1).
///
/// Decisions worth knowing before editing:
/// - Times are INTEGER UTC milliseconds, so ordering and age arithmetic are integer comparisons.
/// - `contentKey` is indexed but not unique: FRD-004 FR-004-08 lets an edit create duplicates.
/// - Exemption is never stored as a flag; `Exemption.sqlPredicate` derives it from pinned, trigger and hotkey.
/// - `auto_vacuum = INCREMENTAL` (needed by Clear History to hand freed pages back, FR-007-11) is not set here: a
///   PRAGMA inside a transaction is silently ignored. `FlotsamDatabase.open` sets it before migrating.
enum Schema {
    static func createVersion1(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE meta (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            ) WITHOUT ROWID;

            CREATE TABLE item (
                id TEXT PRIMARY KEY NOT NULL,
                kind TEXT NOT NULL,
                createdAt INTEGER NOT NULL,
                lastCopiedAt INTEGER NOT NULL,
                copyCount INTEGER NOT NULL DEFAULT 1,
                pasteCount INTEGER NOT NULL DEFAULT 0,
                lastUsedAt INTEGER,
                contentKey TEXT NOT NULL,
                plainText TEXT,
                searchText TEXT NOT NULL DEFAULT '',
                sourceBundleId TEXT,
                sourceName TEXT,
                byteSize INTEGER NOT NULL DEFAULT 0,
                pixelWidth INTEGER,
                pixelHeight INTEGER,
                originalPath TEXT,
                pinned INTEGER NOT NULL DEFAULT 0 CHECK (pinned IN (0, 1)),
                note TEXT CHECK (note IS NULL OR length(note) <= 2000),
                updatedAt INTEGER NOT NULL,
                hotkeyCode INTEGER,
                hotkeyModifiers INTEGER,
                "trigger" TEXT COLLATE NOCASE,
                exemptReleasedAt INTEGER,
                CHECK ((hotkeyCode IS NULL) = (hotkeyModifiers IS NULL))
            );
            CREATE INDEX item_contentKey ON item(contentKey);
            CREATE INDEX item_lastCopiedAt ON item(lastCopiedAt);
            CREATE INDEX item_kind ON item(kind);
            CREATE INDEX item_sourceBundleId ON item(sourceBundleId);
            CREATE UNIQUE INDEX item_hotkey ON item(hotkeyCode, hotkeyModifiers) WHERE hotkeyCode IS NOT NULL;
            CREATE UNIQUE INDEX item_trigger ON item("trigger") WHERE "trigger" IS NOT NULL;

            CREATE TABLE representation (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                itemId TEXT NOT NULL REFERENCES item(id) ON DELETE CASCADE,
                uti TEXT NOT NULL,
                byteSize INTEGER NOT NULL,
                blobName TEXT NOT NULL
            );
            CREATE INDEX representation_itemId ON representation(itemId);

            CREATE TABLE bundleMember (
                itemId TEXT NOT NULL REFERENCES item(id) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL,
                path TEXT NOT NULL,
                bookmark BLOB,
                isDirectory INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (itemId, ordinal)
            ) WITHOUT ROWID;

            CREATE TABLE tag (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL UNIQUE COLLATE NOCASE,
                color TEXT,
                createdAt INTEGER NOT NULL
            );

            CREATE TABLE itemTag (
                itemId TEXT NOT NULL REFERENCES item(id) ON DELETE CASCADE,
                tagId INTEGER NOT NULL REFERENCES tag(id) ON DELETE CASCADE,
                PRIMARY KEY (itemId, tagId)
            ) WITHOUT ROWID;
            CREATE INDEX itemTag_tagId ON itemTag(tagId);
            """)
    }

    /// Secure clips (FRD-007 FR-007-03 secure columns): what a password manager copied, kept as ciphertext.
    ///
    /// - `isSecure` marks the row; `secureCiphertext` is the AES-GCM sealed text (`SecureClipVaulting`). `plainText`
    ///   stays NULL, so the text is in neither the row, the search index nor the WAL.
    /// - The triggers are the last line of defence for three rules the code also enforces, so a code path that
    ///   forgets one fails the write instead of storing something it must not: a secure row carries no hotkey and no
    ///   trigger (FR-004-13; the typed refusal is `TRG-VAL-006`), no plain text, and always has its ciphertext.
    /// - Existing rows take the column defaults (`isSecure = 0`, no ciphertext): nothing to backfill.
    static func createVersion2(_ db: Database) throws {
        try db.execute(sql: """
            ALTER TABLE item ADD COLUMN isSecure INTEGER NOT NULL DEFAULT 0 CHECK (isSecure IN (0, 1));
            ALTER TABLE item ADD COLUMN secureCiphertext BLOB;

            CREATE TRIGGER item_secure_insert BEFORE INSERT ON item
            WHEN NEW.isSecure = 1 AND (
                NEW.hotkeyCode IS NOT NULL OR NEW."trigger" IS NOT NULL
                OR NEW.plainText IS NOT NULL OR NEW.secureCiphertext IS NULL)
            BEGIN
                SELECT RAISE(ABORT, 'secure item invariant violated');
            END;

            CREATE TRIGGER item_secure_update BEFORE UPDATE ON item
            WHEN NEW.isSecure = 1 AND (
                NEW.hotkeyCode IS NOT NULL OR NEW."trigger" IS NOT NULL
                OR NEW.plainText IS NOT NULL OR NEW.secureCiphertext IS NULL)
            BEGIN
                SELECT RAISE(ABORT, 'secure item invariant violated');
            END;
            """)
    }

    /// A bundle's own name (FRD-007 FR-007-03, FRD-004 FR-004-15). NULL is "no name": the row shows the default
    /// primary line. Existing rows take NULL, so there is nothing to backfill.
    static func createVersion3(_ db: Database) throws {
        try db.execute(sql: """
            ALTER TABLE item ADD COLUMN name TEXT CHECK (name IS NULL OR length(name) BETWEEN 1 AND 100);
            """)
    }

    /// Recognised text for image search (FRD-007 FR-007-23, FRD-003 FR-003-55). Additive only: two nullable columns and a
    /// partial index, so no existing row is rewritten and nothing is dropped.
    ///
    /// - `ocrText` is what on-device text recognition read from an image or screenshot: NULL when nothing has been read
    ///   or nothing was found, never an empty string. It lives on the item row, so every deletion path that removes the
    ///   row removes the text with it. It is read only by `SearchIndex`, which folds it into `searchText`.
    /// - `ocrAt` is when recognition last finished for the item (UTC ms), whether or not it found text, so an image with
    ///   no text is not read again. NULL means not attempted yet: every row that exists before this migration, which is
    ///   the backfill queue.
    /// - The CHECK is the last line of defence for two rules the code also enforces: a secure clip never carries
    ///   recognised text, and the text is bounded (`SearchIndex.recognizedTextCharacterLimit`, the same 10,000).
    /// - `item_ocrPending` serves "the newest items still waiting for recognition" and holds only those rows, so it is
    ///   empty once the backfill has finished. Its WHERE terms are spelt exactly as `FlotsamDatabase.itemsAwaitingRecognition`
    ///   spells them, which is what lets SQLite use it.
    static func createVersion4(_ db: Database) throws {
        try db.execute(sql: """
            ALTER TABLE item ADD COLUMN ocrText TEXT CHECK (ocrText IS NULL OR (isSecure = 0 AND length(ocrText) BETWEEN 1 AND 10000));
            ALTER TABLE item ADD COLUMN ocrAt INTEGER;
            CREATE INDEX item_ocrPending ON item(lastCopiedAt) WHERE ocrAt IS NULL AND isSecure = 0 AND kind IN ('image', 'screenshot');
            """)
    }
}
