/// Tells a summarizer's refusal from a summary.
///
/// A model that will not retell a scene answers with a line or a paragraph of
/// apology — "I'm sorry, but I can't help with that." — which is shorter than
/// its source and would be kept as a block, standing in for the messages with
/// nothing of them in it. The chain would then carry an apology in the
/// prompt and, with the messages gone, the story would lose that stretch.
///
/// A refusal is short and opens with the refusing phrase. A real summary that
/// quotes "I can't" is long, and the phrase is not in its first words.
class SummaryRefusal {
  const SummaryRefusal._();

  /// Longer than this is a summary, whatever it opens with.
  static const maxChars = 600;

  /// Only the opening is read for the phrase: a refusal leads with it.
  static const _openingChars = 160;

  // `\b` knows only ASCII letters, so a Cyrillic word gets its own boundary.
  static final _phrase = RegExp(
    r"(?<![\p{L}\p{N}])(?:"
    // "I can't / cannot / won't / am unable to / am not able to"
    r"i\s+(?:can['’]?t|cannot|won['’]?t|am\s+(?:unable|not\s+able)|do\s+not|don['’]?t)\s+"
    r"(?:help|assist|comply|continue|provide|generate|create|write|summari[sz]e|do|fulfil|feel)"
    r"|i['’]?m\s+(?:unable|not\s+able|not\s+comfortable|sorry)"
    r"|as\s+an\s+ai"
    r"|(?:unable|not\s+able)\s+to\s+(?:help|assist|comply|continue|provide|summari[sz]e)"
    r"|(?:can['’]?t|cannot)\s+(?:help|assist|comply|continue|provide|fulfil)"
    // Russian: "я не могу / не буду", "извините", "к сожалению, я"
    r"|я\s+не\s+(?:могу|буду|стану)"
    r"|не\s+могу\s+(?:помочь|продолж|выполн|предостав)"
    r"|извините|прошу\s+прощения|к\s+сожалению,?\s+я"
    r")",
    caseSensitive: false,
    unicode: true,
  );

  /// Whether [text] reads as a refusal rather than a summary.
  static bool looksLike(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty || trimmed.length > maxChars) return false;
    final opening = trimmed.length > _openingChars
        ? trimmed.substring(0, _openingChars)
        : trimmed;
    return _phrase.hasMatch(opening);
  }
}
