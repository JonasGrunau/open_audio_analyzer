import 'package:oaa_mock/oaa_mock.dart';

void main() {
  final s = MockSource(captureAt: double.infinity);
  for (var i = 0; i < 5; i++) {
    print('frame ${i}  t=${s.elapsedSeconds.toStringAsFixed(3)}  '
        'M=${s.lufsMomentary}  I=${s.lufsIntegrated}  frozen=${s.isFrozen}');
    s.refresh();
  }
  for (var i = 0; i < 400; i++) {
    s.refresh();
  }
  print('after 405 refreshes: t=${s.elapsedSeconds.toStringAsFixed(2)} '
      'M=${s.lufsMomentary.toStringAsFixed(2)} '
      'I=${s.lufsIntegrated.toStringAsFixed(2)} '
      'LRA=${s.loudnessRange.toStringAsFixed(2)}');
}
