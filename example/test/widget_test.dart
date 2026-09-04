import 'package:flutter_test/flutter_test.dart';
import 'package:camera_kit_plus_example/main.dart';

void main() {
  testWidgets('example home shows OCR mode title', (tester) async {
    await tester.pumpWidget(const MyApp());
    expect(find.text('OCR'), findsWidgets);
    expect(find.text('Barcode'), findsOneWidget);
  });
}
