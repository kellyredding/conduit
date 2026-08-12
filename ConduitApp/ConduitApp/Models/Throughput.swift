import Foundation

/// Rates, from a client that only reports totals.
///
/// The client's byte counters are cumulative for the life of an attempt, so a
/// rate exists only *between* two readings: Δbytes ÷ Δt. Nothing in the payload
/// supplies that Δt — `updated-at` marks the last state *change*, not the moment
/// the counters were read, so it holds still for the whole life of a connected
/// tunnel and differencing against it would divide by zero forever. The
/// timestamps here are taken when the sample is recorded, which is the only
/// clock that describes when the counters were actually read.
///
/// Foundation-only, and a value type over plain numbers, so the whole of the
/// arithmetic below is exercised by the sandboxed check without a subprocess, a
/// timer, or a tunnel.
struct ThroughputSample: Equatable, Sendable {
    let at: Date
    let counters: VPNByteCounters
}

/// One differenced pair — the only form in which a rate exists here.
struct ThroughputRate: Equatable, Sendable, Identifiable {
    let at: Date
    let inPerSecond: Double
    let outPerSecond: Double

    /// Whether the interval immediately before this rate went unmeasured.
    ///
    /// Recorded here because this is where it is *known*: the series discards
    /// unmeasurable intervals, so by the time a plot sees two consecutive rates
    /// it can no longer tell a two-second step from one that spans a minute of
    /// skipped samples. A line drawn straight between those two points asserts
    /// traffic through a period nobody measured, which is the one claim this
    /// whole type exists to avoid making.
    let startsRun: Bool

    /// The sample time. Two rates cannot share one, since each is produced by a
    /// recording and recordings are serial.
    var id: Date { at }
}

/// A bounded history of differenced rates for one profile.
///
/// Four readings are deliberately *not* turned into rates, and each one would
/// otherwise produce a number that is arithmetically correct and descriptively
/// false:
///
///   - **The first.** There is nothing to difference against. A rate computed
///     from a single cumulative total would report the tunnel's entire lifetime
///     average as though it were the current second.
///   - **A counter that went backwards.** The client resets these when it
///     starts a new attempt, so a decrease is a new tunnel rather than negative
///     traffic. Differencing across it yields a negative rate; taking the new
///     value alone claims a burst that never happened.
///   - **A gap longer than the sampling cadence allows.** Sampling stops when
///     nobody is looking, and the machine sleeps. The counters keep climbing
///     across both, so the next difference spreads however much traffic
///     happened over however long nobody watched and presents the mean as
///     "now".
///   - **An absent reading.** `details` is optional for a reason the client
///     insists on — it arrives present-with-zeros from a stalled attempt — so a
///     missing payload is a hole in the record, not a quiet moment. Treating it
///     as zero would draw a tunnel idling when the truth is that nothing was
///     observed.
///
/// In every one of those cases the reading still becomes the new baseline. That
/// is the point: the interval that could not be measured is skipped, and the
/// *next* one is measurable rather than being poisoned by the same hole.
struct ThroughputSeries: Equatable, Sendable {
    /// Five minutes at the default active cadence. The chart shows minutes, so
    /// history past what it can draw is memory with nothing to display it.
    static let defaultCapacity = 150

    private(set) var rates: [ThroughputRate] = []

    /// The last reading, present or not. Nil means the next reading starts a
    /// new interval rather than closing one.
    private var baseline: ThroughputSample?

    /// Set whenever an interval is skipped, and carried onto the next rate that
    /// is emitted. True to begin with: the first rate of all begins a run.
    private var pendingBreak = true

    let capacity: Int

    init(capacity: Int = ThroughputSeries.defaultCapacity) {
        self.capacity = capacity
    }

    /// Record a reading, emitting a rate when the interval since the previous
    /// one is measurable.
    ///
    /// `counters` is optional because the caller cannot always get them, and
    /// passing the absence through is what keeps this from differencing across
    /// a hole. `staleAfter` is supplied per call rather than stored, so a
    /// cadence changed in settings takes effect on the next sample instead of
    /// on the next launch.
    mutating func record(
        _ counters: VPNByteCounters?,
        at now: Date,
        staleAfter: TimeInterval
    ) {
        guard let counters else {
            baseline = nil
            pendingBreak = true
            return
        }

        let previous = baseline
        baseline = ThroughputSample(at: now, counters: counters)

        guard let previous else {
            pendingBreak = true
            return
        }

        let elapsed = now.timeIntervalSince(previous.at)
        // Zero is two samples in one instant; negative is a clock that moved
        // backwards under us. Neither divides into anything meaningful.
        guard elapsed > 0, elapsed <= staleAfter else {
            pendingBreak = true
            return
        }
        guard
            counters.tunnelIn >= previous.counters.tunnelIn,
            counters.tunnelOut >= previous.counters.tunnelOut
        else {
            pendingBreak = true
            return
        }

        append(
            ThroughputRate(
                at: now,
                inPerSecond:
                    Double(counters.tunnelIn - previous.counters.tunnelIn)
                    / elapsed,
                outPerSecond:
                    Double(counters.tunnelOut - previous.counters.tunnelOut)
                    / elapsed,
                startsRun: pendingBreak
            )
        )
        pendingBreak = false
    }

    /// The most recent measured rate, which is what the readout shows.
    var latest: ThroughputRate? { rates.last }

    var isEmpty: Bool { rates.isEmpty }

    /// The largest rate in either direction, for scaling a plot to its own
    /// contents.
    var peak: Double {
        rates.reduce(0) { max($0, max($1.inPerSecond, $1.outPerSecond)) }
    }

    private mutating func append(_ rate: ThroughputRate) {
        rates.append(rate)
        if rates.count > capacity {
            rates.removeFirst(rates.count - capacity)
        }
    }
}
