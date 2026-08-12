import Foundation

/// Housekeeping for the logs the AWS VPN Client writes on our behalf.
///
/// The client insists on a log directory and writes one file per day into it.
/// Nothing ever removes them, and Conduit never reads them — the daemon's own
/// log is the one with anything worth knowing in it — so left alone they are a
/// slow leak whose only purpose is to exist.
///
/// This is the one place Conduit deletes anything. It is deliberately narrow:
/// only inside the directory Conduit itself created for the client, only files
/// matching the name the client writes, and never the newest ones.
enum ClientLogs {
    /// Where the client puts them, derived the same way the client derives it.
    static func directory(clientHome: URL) -> URL {
        clientHome
            .appendingPathComponent(".config")
            .appendingPathComponent("AWSVPNClient")
            .appendingPathComponent("logs")
    }

    /// The client's own naming. Matching on it rather than deleting whatever is
    /// present means a file put here by anything else survives — this runs
    /// unattended at every launch, and a deletion loop that trusts its
    /// directory is one misconfigured path away from being a problem.
    private static func isClientLog(_ name: String) -> Bool {
        name.hasPrefix("aws_vpn_client") && name.hasSuffix(".log")
    }

    /// Remove client logs last modified more than `retainingDays` ago.
    /// Returns how many were removed.
    ///
    /// Age is taken from modification time rather than parsed out of the file
    /// name. The name encodes a date, but a file the client is still appending
    /// to is not old however it is named, and mtime cannot disagree with that.
    @discardableResult
    static func prune(
        clientHome: URL,
        retainingDays: Int,
        now: Date = Date(),
        calendar: Calendar = .current,
        fileManager: FileManager = .default
    ) -> Int {
        guard retainingDays >= 0 else { return 0 }

        let directory = directory(clientHome: clientHome)

        // Counted in calendar days from the start of today, not in multiples
        // of 24 hours from this instant. With raw arithmetic a retention of
        // zero has a cutoff of *now*, which is a moment after the client last
        // touched the file it is still writing — so the one log that must
        // never be deleted is the first to go. Days are also what the setting
        // says it counts, and an implementation that disagrees with its own
        // description is a trap rather than a bug.
        let today = calendar.startOfDay(for: now)
        let cutoff = calendar.date(byAdding: .day, value: -retainingDays, to: today)
            ?? today

        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        else { return 0 }

        var removed = 0
        for entry in entries where isClientLog(entry.lastPathComponent) {
            guard
                let modified = try? entry.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate,
                modified < cutoff
            else { continue }

            if (try? fileManager.removeItem(at: entry)) != nil {
                removed += 1
            }
        }
        return removed
    }

    /// Delete client logs, oldest first, until the directory fits `maxBytes`.
    /// Returns how many were removed.
    ///
    /// Retention alone cannot bound this. It removes whole days, and says
    /// nothing about a single day that goes chatty — a reconnect loop, or a
    /// machine left up long enough for one file to outgrow every argument for
    /// keeping it. The cap is the backstop that does not care why.
    ///
    /// Deleting even the current day's file is safe, which is what makes this
    /// simple. Nothing holds these open: the client is exec'd fresh for every
    /// query and opens the log each time, so a removed file is recreated on
    /// the next one. The long-lived daemon writes somewhere else entirely and
    /// is never touched by any of this.
    @discardableResult
    static func enforceCap(
        clientHome: URL,
        maxBytes: Int64,
        fileManager: FileManager = .default
    ) -> Int {
        guard maxBytes > 0 else { return 0 }

        let directory = directory(clientHome: clientHome)
        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        else { return 0 }

        struct Entry {
            let url: URL
            let size: Int64
            let modified: Date
        }

        var logs: [Entry] = entries.compactMap { url in
            guard isClientLog(url.lastPathComponent) else { return nil }
            let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]
            )
            return Entry(
                url: url,
                size: Int64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate ?? .distantPast
            )
        }

        var total = logs.reduce(Int64(0)) { $0 + $1.size }
        guard total > maxBytes else { return 0 }

        // Oldest first, so the most recent history is the last thing to go.
        logs.sort { $0.modified < $1.modified }

        var removed = 0
        for log in logs where total > maxBytes {
            guard (try? fileManager.removeItem(at: log.url)) != nil else { continue }
            total -= log.size
            removed += 1
        }
        return removed
    }

    /// Total bytes the client's logs currently occupy, for reporting.
    static func footprint(
        clientHome: URL,
        fileManager: FileManager = .default
    ) -> Int64 {
        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: directory(clientHome: clientHome),
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            )
        else { return 0 }

        return entries
            .filter { isClientLog($0.lastPathComponent) }
            .compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
            .reduce(0) { $0 + Int64($1) }
    }
}
