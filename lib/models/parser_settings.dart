class ParserSettings {
  final String senderMarker;
  final String messageRegex;

  ParserSettings({required this.senderMarker, required this.messageRegex});

  factory ParserSettings.fromMap(Map<String, dynamic> m) => ParserSettings(
        senderMarker: m['sender_marker'] as String,
        messageRegex: m['message_regex'] as String,
      );

  // Kept identical to the Kotlin-side defaults in ExpenseDbHelper.kt.
  // Broadened from "HDFCBK" to plain "HDFC" -- some bank SMS come through
  // sender IDs that don't literally contain "HDFCBK" even though your
  // messaging app groups them into the same visual conversation.
  static const defaultSenderMarker = 'HDFC';
  static const defaultMessageRegex =
      r'Sent\s+(?:Rs\.?|INR)?\s*([0-9][0-9,]*\.\d{2})\s+From\s+HDFC\s+Bank\s+A/?C\s+\S+\s+To\s+(.+?)\s+On\s+(\d{1,2}/\d{1,2}/\d{2,4})';
}