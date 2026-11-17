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
}

/// The one definition of "exempt" (FR-007-10), as a SQL predicate. Retention, budget eviction and Clear History all
/// splice this in, so they cannot disagree about which items are protected.
enum Exemption {
    static let sqlPredicate = "(pinned = 1 OR \"trigger\" IS NOT NULL OR hotkeyCode IS NOT NULL)"
    static let notExemptSQL = "(pinned = 0 AND \"trigger\" IS NULL AND hotkeyCode IS NULL)"
    /// After an exemption is released, the item stays safe from sweeps for this long (FR-007-10).
    static let graceMillis: Int64 = 24 * 60 * 60 * 1000
}
