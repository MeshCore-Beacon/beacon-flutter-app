import 'package:beacon/core/api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a superseded screen does not start a read', () async {
    var reads = 0;
    expect(
      await retryTransient(() async => ++reads, isCurrent: () => false),
      isNull,
    );
    expect(reads, 0);
  });
}
