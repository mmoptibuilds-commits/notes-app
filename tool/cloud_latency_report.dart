// Turns the `LAT` lines of the two latency roles into timings.
//   dart run tool/cloud_latency_report.dart [--offset-ms N] <log>...
// N is the phone clock minus the Linux clock. Cross-device timings are
// accurate to about the clock-offset error (tens of milliseconds).
import 'dart:io';

void main(List<String> args) {
  var offset = 0;
  final files = <String>[];
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--offset-ms') {
      offset = int.parse(args[++i]);
    } else {
      files.add(args[i]);
    }
  }
  final line = RegExp(r'\bLAT k=(\d+) kind=(\w+) to=(\w) (.*)$');
  final idle = RegExp(r'\bLATIDLE (.*)$');
  final idleLines = <String>[];
  final samples = <String, List<int>>{};
  final problems = <String, int>{};
  for (final file in files) {
    for (final text in File(file).readAsLinesSync()) {
      final i = idle.firstMatch(text);
      if (i != null) idleLines.add(i.group(1)!);
      final m = line.firstMatch(text);
      if (m == null) continue;
      final kind = m.group(2)!;
      final to = m.group(3)!;
      final direction = to == 'A' ? 'Linux to phone' : 'phone to Linux';
      final key = '$kind, $direction';
      final fields = {
        for (final f in m.group(4)!.split(' '))
          if (f.contains('='))
            f.split('=').first: f.substring(f.indexOf('=') + 1),
      };
      if (fields['timedOut'] == 'true') {
        problems.update('$key: timed out', (n) => n + 1, ifAbsent: () => 1);
        continue;
      }
      if (fields['valid'] == 'false') {
        problems.update(
          '$key: invalid sample',
          (n) => n + 1,
          ifAbsent: () => 1,
        );
        continue;
      }
      final arrival = int.parse(fields['arrival']!);
      final local = int.parse(fields['local']!);
      final saved = int.parse(fields['saved']!);
      final hold = int.parse(fields['hold']!);
      final ms = local >= 0
          ? local
          : to == 'A'
          ? arrival - offset - (saved + hold)
          : arrival - (saved - offset + hold);
      samples.putIfAbsent(key, () => []).add(ms);
    }
  }
  stdout.writeln(
    'kind, direction                     n   median     max   samples (s)',
  );
  for (final key in samples.keys.toList()..sort()) {
    final values = samples[key]!..sort();
    final median = values[values.length ~/ 2];
    stdout.writeln(
      '${key.padRight(34)} ${values.length}  ${_s(median)}  ${_s(values.last)}   '
      '${values.map(_s).join(' ')}',
    );
  }
  for (final l in idleLines) {
    stdout.writeln('idle: $l');
  }
  for (final entry in problems.entries) {
    stdout.writeln('${entry.key} x${entry.value}');
  }
  if (samples.isEmpty && problems.isEmpty) {
    stdout.writeln('No LAT lines found.');
  }
}

String _s(int ms) => (ms / 1000).toStringAsFixed(1).padLeft(6);
