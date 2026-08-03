import '../models/worker_models.dart';

class WorkerDocumentTextParser {
  const WorkerDocumentTextParser();

  String normalize(String value) {
    return value.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  }

  Map<String, String> extractFields(IndianIdType idType, String rawText) {
    final normalizedText = normalize(rawText);
    final number = documentNumber(idType, normalizedText);
    final name = extractName(idType, rawText);
    final address = extractAddress(rawText);
    return <String, String>{
      'detectedDocumentType': idType.name,
      if (number != null) ...{
        'documentNumber': number,
        'documentNumberMasked': mask(number),
      },
      if (name != null) 'documentName': name,
      if (address != null) 'documentAddress': address,
    };
  }

  String? extractName(IndianIdType idType, String rawText) {
    final lines = candidateLines(rawText);
    for (var index = 0; index < lines.length; index += 1) {
      final line = lines[index];
      final upper = line.toUpperCase();
      if (!_isPrimaryNameLabel(upper)) continue;

      final inlineValue = _valueFollowingNameLabel(line);
      if (_looksLikeName(inlineValue) && !_ignoredNameLine(inlineValue)) {
        return _cleanName(inlineValue);
      }

      for (var next = index + 1;
          next < lines.length && next <= index + 3;
          next += 1) {
        final candidate = lines[next];
        if (_isNameBoundary(candidate)) break;
        if (_looksLikeName(candidate) && !_ignoredNameLine(candidate)) {
          return _cleanName(candidate);
        }
      }
    }

    if (idType == IndianIdType.pan) {
      final panLine = lines.indexWhere(
        (line) => documentNumber(idType, normalize(line)) != null,
      );
      if (panLine >= 0) {
        for (final candidate in lines.skip(panLine + 1).take(5)) {
          if (_isNameBoundary(candidate)) break;
          if (_looksLikeName(candidate) && !_ignoredNameLine(candidate)) {
            return _cleanName(candidate);
          }
        }
      }
    }

    return null;
  }

  String? extractAddress(String rawText) {
    final lines = candidateLines(rawText);
    final start = lines.indexWhere(
      (line) => RegExp(r'\b(ADDRESS|ADDR|S/O|D/O|W/O|C/O)\b')
          .hasMatch(line.toUpperCase()),
    );
    if (start < 0) return null;

    final values = <String>[];
    for (final line in lines.skip(start)) {
      final value = line
          .replaceFirst(
            RegExp(
              r'^\s*(ADDRESS|ADDR|S/O|D/O|W/O|C/O)\s*[:\-]?\s*',
              caseSensitive: false,
            ),
            '',
          )
          .trim();
      if (value.isEmpty || isDocumentLabel(value)) break;
      values.add(value);
      if (values.join(' ').length >= 180 || values.length == 3) break;
    }
    final result = values.join(', ').trim();
    if (result.length < 6) return null;
    return result.substring(0, result.length > 200 ? 200 : result.length);
  }

  List<String> candidateLines(String rawText) {
    return rawText
        .split(RegExp(r'\r?\n'))
        .map((line) => line.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((line) => line.length >= 2)
        .toList();
  }

  String? documentNumber(IndianIdType idType, String text) {
    final pattern = switch (idType) {
      IndianIdType.aadhaar => RegExp(r'\d{12}'),
      IndianIdType.pan => RegExp(r'[A-Z]{5}\d{4}[A-Z]'),
      IndianIdType.voterId => RegExp(r'[A-Z]{2,4}\d{6,10}'),
      IndianIdType.drivingLicence => RegExp(r'[A-Z]{2}\d{2}[A-Z0-9]{6,14}'),
      IndianIdType.passport => RegExp(r'[A-Z][A-Z0-9]\d{6,8}'),
    };
    return pattern.firstMatch(text)?.group(0);
  }

  String mask(String value) {
    if (value.length <= 4) return value;
    return '${'X' * (value.length - 4)}${value.substring(value.length - 4)}';
  }

  bool _isPrimaryNameLabel(String upper) {
    if (!upper.contains('NAME')) return false;
    return !upper.contains('FATHER') &&
        !upper.contains('MOTHER') &&
        !upper.contains('SURNAME');
  }

  String _valueFollowingNameLabel(String line) {
    final upper = line.toUpperCase();
    final nameIndex = upper.lastIndexOf('NAME');
    if (nameIndex < 0) return '';
    return line
        .substring(nameIndex + 4)
        .replaceFirst(RegExp(r'^\s*[/|:\-]+\s*'), '')
        .trim();
  }

  bool _isNameBoundary(String value) {
    final upper = value.toUpperCase();
    return upper.contains('FATHER') ||
        upper.contains('MOTHER') ||
        upper.contains('DATE OF BIRTH') ||
        RegExp(r'\bDOB\b').hasMatch(upper) ||
        upper.contains('SIGNATURE');
  }

  bool _looksLikeName(String value) {
    final cleaned = _cleanName(value);
    final words = cleaned
        .split(RegExp(r'\s+'))
        .where((word) => word.length >= 2)
        .toList();
    return cleaned.length >= 3 && cleaned.length <= 60 && words.length >= 2;
  }

  String _cleanName(String value) {
    return value
        .replaceAll(RegExp(r'[^A-Za-z .-]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  bool _ignoredNameLine(String value) {
    final upper = value.toUpperCase();
    return isDocumentLabel(value) ||
        upper.contains('INCOME TAX') ||
        upper.contains('DEPARTMENT') ||
        upper.contains('GOVERNMENT') ||
        upper.contains('GOVT') ||
        upper.contains('INDIA') ||
        upper.contains('AADHAAR') ||
        upper.contains('PASSPORT') ||
        upper.contains('ELECTION') ||
        upper.contains('PERMANENT ACCOUNT') ||
        upper.contains('IDENTITY CARD') ||
        upper.contains('FATHER') ||
        upper.contains('MOTHER') ||
        upper.contains('SIGNATURE');
  }

  bool isDocumentLabel(String value) {
    final upper = value.toUpperCase();
    return upper.contains('DOB') ||
        upper.contains('DATE OF BIRTH') ||
        upper.contains('GENDER') ||
        upper.contains('MALE') ||
        upper.contains('FEMALE') ||
        upper.contains('VALID') ||
        upper.contains('IDENTIFICATION');
  }
}
