// Runs the app's Speller over every partial word and finished word of an evaluation
// corpus and writes the verdicts as JSON, so ft-replay can replay the typo gate and
// autocorrect exactly as the app would decide them (ft-replay --spell FILE).
//
//   swiftc -O tools/spell-map/main.swift mac/Sources/Foretype/Speller.swift -o build/spell-map
//   build/spell-map eval/corpus.jsonl > build/spell-map.json
import AppKit

/// The fields of the app's FieldSnapshot that Speller reads and writes.
struct FieldSnapshot {
    var textBefore = ""
    var spellFragment = ""
    var spellWord = ""
    var spellCorrection = ""
}

let args = CommandLine.arguments
guard args.count == 2, let corpus = try? String(contentsOfFile: args[1], encoding: .utf8) else {
    FileHandle.standardError.write("usage: spell-map CORPUS.jsonl\n".data(using: .utf8)!)
    exit(2)
}
let speller = Speller()
var fragments: [String: String] = [:]
var corrections: [String: String] = [:]
let isWord: (Character) -> Bool = { $0.isLetter || $0.isNumber || "'\u{2019}-_".contains($0) }
for line in corpus.split(separator: "\n") {
    guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
          let text = o["text"] as? String else { continue }
    // Every word, every prefix of it (as typed), and the word followed by a space.
    for word in text.split(whereSeparator: { !isWord($0) }).map(String.init) {
        for n in 3...max(3, word.count) where n <= word.count {
            let frag = String(word.prefix(n))
            guard fragments[frag] == nil else { continue }
            var s = FieldSnapshot(textBefore: "x " + frag)
            speller.annotate(&s)
            if !s.spellFragment.isEmpty { fragments[frag] = s.spellFragment }
        }
        guard corrections[word] == nil else { continue }
        var s = FieldSnapshot(textBefore: "x " + word + " ")
        speller.annotate(&s)
        corrections[word] = s.spellCorrection
    }
}
let out: [String: Any] = ["fragments": fragments, "corrections": corrections.filter { !$0.value.isEmpty }]
let data = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .prettyPrinted])
FileHandle.standardOutput.write(data)
