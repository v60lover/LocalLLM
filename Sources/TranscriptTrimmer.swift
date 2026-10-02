import FoundationModels

/// Frees context by forgetting the oldest turns while keeping the instructions.
enum TranscriptTrimmer {
    struct Result {
        let transcript: Transcript
        let droppedTurns: Int
    }

    /// A turn starts at a `.prompt` entry and runs up to the next one.
    static func turnCount(in transcript: Transcript) -> Int {
        transcript.reduce(0) { count, entry in
            if case .prompt = entry { count + 1 } else { count }
        }
    }

    /// Drops the older half of the turns (rounded up, so at least one when any exist).
    /// `droppedTurns == 0` means there was nothing left to forget.
    static func dropOldestHalf(of transcript: Transcript) -> Result {
        let turns = turnCount(in: transcript)
        let toDrop = (turns + 1) / 2
        guard toDrop > 0 else { return Result(transcript: transcript, droppedTurns: 0) }

        var kept: [Transcript.Entry] = []
        var seenPrompts = 0
        for entry in transcript {
            switch entry {
            case .instructions:
                kept.append(entry)
            case .prompt:
                seenPrompts += 1
                if seenPrompts > toDrop { kept.append(entry) }
            default:
                if seenPrompts > toDrop { kept.append(entry) }
            }
        }
        return Result(transcript: Transcript(entries: kept), droppedTurns: toDrop)
    }
}
