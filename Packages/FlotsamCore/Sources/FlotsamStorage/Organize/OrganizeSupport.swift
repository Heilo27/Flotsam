import FlotsamBase
import Foundation
import GRDB

/// Thrown inside a write transaction to roll it back and hand a specific FRD-004 code to the caller. Anything else
/// thrown in there is a database failure and becomes `STO-DB-001`.
struct OrganizeRejection: Error {
    let error: FlotsamError
}

/// Limits FRD-004 owns. The note ceiling stays with the other ingest ceilings (`IngestLimits`).
public enum OrganizeLimits {
    /// FR-004-02.
    public static let maxTagNameCharacters = 32
    public static let maxTags = 100
    public static let maxTagsPerItem = 10
}

extension FlotsamDatabase {
    /// One FRD-004 action as one transaction (FR-004-14): the body's result, the rejection it threw, or `STO-DB-001`
    /// with everything rolled back.
    func organizeWrite<T: Sendable>(_ body: @Sendable (Database) throws -> T) async -> FlotsamResult<T> {
        do {
            return .success(try await pool.write(body))
        } catch let rejection as OrganizeRejection {
            return .failure(rejection.error)
        } catch {
            return .failure(Self.writeFailure(error))
        }
    }

    /// Items were edited by an organise action: Library and counts refresh (FR-004-13). Called after commit.
    func publishOrganizeChange() {
        events.publish(.itemsChanged)
    }
}
