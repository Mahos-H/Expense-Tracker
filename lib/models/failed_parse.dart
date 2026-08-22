class FailedParse {
  final int? id;
  final DateTime smsDateTime;
  final String title;
  final String? body;

  FailedParse({this.id, required this.smsDateTime, required this.title, this.body});

  factory FailedParse.fromMap(Map<String, dynamic> m) => FailedParse(
        id: m['id'] as int?,
        smsDateTime: DateTime.parse(m['sms_datetime'] as String),
        title: m['title'] as String,
        body: m['body'] as String?,
      );
}
