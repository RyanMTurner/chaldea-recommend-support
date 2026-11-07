import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/models/userdata/userdata.dart';

void main() {
  test('SvtStatus keeps exact bond points through json', () {
    final status = SvtStatus(bond: 12, bondPoints: 4321000);
    final copy = SvtStatus.fromJson(status.toJson());
    expect(copy.bond, 12);
    expect(copy.bondPoints, 4321000);
  });

  test('SvtStatus bond points default to null', () {
    expect(SvtStatus().bondPoints, isNull);
    expect(SvtStatus.fromJson({'bond': 5}).bondPoints, isNull);
  });
}
