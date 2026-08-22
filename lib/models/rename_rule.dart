class RenameRule {
  final int? id;
  final String fromName;
  final String toName;

  RenameRule({this.id, required this.fromName, required this.toName});

  factory RenameRule.fromMap(Map<String, dynamic> m) => RenameRule(
        id: m['id'] as int?,
        fromName: m['from_name'] as String,
        toName: m['to_name'] as String,
      );
}
