import 'package:flutter_test/flutter_test.dart';
import 'package:gofer/models/worker_models.dart';
import 'package:gofer/services/worker_document_text_parser.dart';

void main() {
  const parser = WorkerDocumentTextParser();

  test('extracts PAN name from the line following a bilingual name label', () {
    const text = '''
INCOME TAX DEPARTMENT
GOVT. OF INDIA
Permanent Account Number Card
CFOPN3490N
नाम / Name
SABYASACHI NISHANT
पिता का नाम / Father's Name
SURESH PRASAD
Date of Birth
14/07/2001
''';

    final fields = parser.extractFields(IndianIdType.pan, text);

    expect(fields['documentName'], 'SABYASACHI NISHANT');
    expect(fields['documentNumber'], 'CFOPN3490N');
    expect(fields['documentNumberMasked'], 'XXXXXX490N');
  });

  test('extracts a PAN name written on the same line as its label', () {
    const text = '''
Permanent Account Number Card
ABCDE1234F
Name: PRIYA SHARMA
Father's Name: RAKESH SHARMA
''';

    final fields = parser.extractFields(IndianIdType.pan, text);

    expect(fields['documentName'], 'PRIYA SHARMA');
    expect(fields['documentNumber'], 'ABCDE1234F');
  });

  test('does not confuse headers or father name with the cardholder name', () {
    const text = '''
INCOME TAX DEPARTMENT
GOVERNMENT OF INDIA
ABCDE1234F
Father's Name
RAKESH SHARMA
Date of Birth
01/01/1990
''';

    final fields = parser.extractFields(IndianIdType.pan, text);

    expect(fields['documentName'], isNull);
  });
}
