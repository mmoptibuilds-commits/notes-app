const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// Short, human date for a card footer: "now", "5 min", "3 h", "Yesterday",
/// "12 Mar", "12 Mar 2025". [now] is injectable for tests.
String formatRelativeDate(DateTime date, {DateTime? now}) {
  now ??= DateTime.now();
  final diff = now.difference(date);
  if (diff.inMinutes < 1) return 'now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min';
  final today = DateTime.utc(now.year, now.month, now.day);
  final day = DateTime.utc(date.year, date.month, date.day);
  final days = today.difference(day).inDays;
  if (days <= 0) return '${diff.inHours} h';
  if (days == 1) return 'Yesterday';
  final short = '${date.day} ${_months[date.month - 1]}';
  return date.year == now.year ? short : '$short ${date.year}';
}

/// "1 note" / "3 notes".
String notesCount(int n) => n == 1 ? '1 note' : '$n notes';
