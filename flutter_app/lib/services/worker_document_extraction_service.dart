import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../models/worker_models.dart';

class WorkerDocumentExtractionResult {
  const WorkerDocumentExtractionResult({
    required this.checks,
    this.extractedFields = const <String, String>{},
  });

  final List<DocumentValidationCheck> checks;
  final Map<String, String> extractedFields;
}

class WorkerDocumentExtractionService {
  Future<WorkerDocumentExtractionResult> validate({
    required String path,
    required IndianIdType idType,
    required WorkerDocumentType documentType,
  }) async {
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final recognizedText = await recognizer.processImage(
        InputImage.fromFilePath(path),
      );
      final rawText = recognizedText.text;
      final text = _normalize(rawText);
      final checks = <DocumentValidationCheck>[
        DocumentValidationCheck(
          label: 'Readable document text',
          passed: text.length >= 8,
          message: text.length >= 8
              ? 'Document text was detected.'
              : 'Text could not be read. Use a brighter, sharper photo.',
        ),
      ];

      if (documentType == WorkerDocumentType.nationalIdFront) {
        checks.add(_contentCheck(idType, text));
      } else {
        checks.add(
          DocumentValidationCheck(
            label: 'Back-side content',
            passed: text.length >= 8,
            message: text.length >= 8
                ? 'Back-side content was detected.'
                : 'Show the full back side and retake the photo.',
          ),
        );
      }

      return WorkerDocumentExtractionResult(
        checks: checks,
        extractedFields: _safeFields(idType, rawText, text),
      );
    } catch (_) {
      return const WorkerDocumentExtractionResult(
        checks: [
          DocumentValidationCheck(
            label: 'Document text extraction',
            passed: false,
            message:
                'Could not read this document. Retake it in bright light and keep all text in focus.',
          ),
        ],
      );
    } finally {
      await recognizer.close();
    }
  }

  String _normalize(String value) {
    return value
        .toUpperCase()
        .replaceAll(RegExp(r'[^A-Z0-9]'), '');
  }

  DocumentValidationCheck _contentCheck(IndianIdType idType, String text) {
    final rule = switch (idType) {
      IndianIdType.aadhaar => _hasAadhaar,
      IndianIdType.pan => _hasPan,
      IndianIdType.voterId => _hasVoterId,
      IndianIdType.drivingLicence => _hasDrivingLicence,
      IndianIdType.passport => _hasPassport,
    };
    final passed = rule(text);
    return DocumentValidationCheck(
      label: '${idType.label} format',
      passed: passed,
      message: passed
          ? '${idType.label} number format was detected.'
          : 'The photo does not look like a readable ${idType.label}.',
    );
  }

  Map<String, String> _safeFields(
    IndianIdType idType,
    String rawText,
    String text,
  ) {
    final match = _documentNumber(idType, text);
    final fields = <String, String>{
      'detectedDocumentType': idType.name,
      if (match != null) 'documentNumberMasked': _mask(match),
    };
    final name = _extractName(rawText);
    final address = _extractAddress(rawText);
    if (name != null) fields['documentName'] = name;
    if (address != null) fields['documentAddress'] = address;
    return fields;
  }

  String? _extractName(String rawText) {
    final lines = _candidateLines(rawText);
    for (final line in lines) {
      final upper = line.toUpperCase();
      if (upper.contains('NAME')) {
        final value = line.split(':').skip(1).join(':').trim();
        if (_looksLikeName(value)) return value;
      }
    }
    for (final line in lines.skip(1)) {
      if (_looksLikeName(line) && !_ignoredNameLine(line)) return line;
    }
    return null;
  }

  String? _extractAddress(String rawText) {
    final lines = _candidateLines(rawText);
    final start = lines.indexWhere(
      (line) => RegExp(r'\b(ADDRESS|ADDR|S/O|D/O|W/O|C/O)\b')
          .hasMatch(line.toUpperCase()),
    );
    if (start < 0) return null;

    final values = <String>[];
    for (final line in lines.skip(start)) {
      final value = line
          .replaceFirst(
            RegExp(r'^\s*(ADDRESS|ADDR|S/O|D/O|W/O|C/O)\s*[:\-]?\s*',
                caseSensitive: false),
            '',
          )
          .trim();
      if (value.isEmpty || _isDocumentLabel(value)) break;
      values.add(value);
      if (values.join(' ').length >= 180 || values.length == 3) break;
    }
    final result = values.join(', ').trim();
    if (result.length < 6) return null;
    return result.substring(0, result.length > 200 ? 200 : result.length);
  }

  List<String> _candidateLines(String rawText) {
    return rawText
        .split(RegExp(r'\r?\n'))
        .map((line) => line.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((line) => line.length >= 3)
        .toList();
  }

  bool _looksLikeName(String value) {
    final cleaned = value.replaceAll(RegExp(r'[^A-Za-z .-]'), '').trim();
    final words = cleaned.split(RegExp(r'\s+')).where((word) => word.isNotEmpty);
    return cleaned.length >= 3 && cleaned.length <= 60 && words.length >= 2;
  }

  bool _ignoredNameLine(String value) {
    final upper = value.toUpperCase();
    return _isDocumentLabel(value) ||
        upper.contains('GOVERNMENT') ||
        upper.contains('INDIA') ||
        upper.contains('AADHAAR') ||
        upper.contains('PASSPORT') ||
        upper.contains('ELECTION');
  }

  bool _isDocumentLabel(String value) {
    final upper = value.toUpperCase();
    return upper.contains('DOB') ||
        upper.contains('DATE OF BIRTH') ||
        upper.contains('GENDER') ||
        upper.contains('MALE') ||
        upper.contains('FEMALE') ||
        upper.contains('VALID') ||
        upper.contains('IDENTIFICATION');
  }

  String? _documentNumber(IndianIdType idType, String text) {
    final pattern = switch (idType) {
      IndianIdType.aadhaar => RegExp(r'\d{12}'),
      IndianIdType.pan => RegExp(r'[A-Z]{5}\d{4}[A-Z]'),
      IndianIdType.voterId => RegExp(r'[A-Z]{2,4}\d{6,10}'),
      IndianIdType.drivingLicence => RegExp(r'[A-Z]{2}\d{2}[A-Z0-9]{6,14}'),
      IndianIdType.passport => RegExp(r'[A-Z][A-Z0-9]\d{6,8}'),
    };
    return pattern.firstMatch(text)?.group(0);
  }

  String _mask(String value) {
    if (value.length <= 4) return value;
    return '${'X' * (value.length - 4)}${value.substring(value.length - 4)}';
  }

  bool _hasAadhaar(String text) {
    return RegExp(r'\d{12}').hasMatch(text) ||
        RegExp(r'\d{4}\d{4}\d{4}').hasMatch(text);
  }

  bool _hasPan(String text) {
    return RegExp(r'[A-Z]{5}\d{4}[A-Z]').hasMatch(text);
  }

  bool _hasVoterId(String text) {
    return RegExp(r'[A-Z]{2,4}\d{6,10}').hasMatch(text);
  }

  bool _hasDrivingLicence(String text) {
    return RegExp(r'[A-Z]{2}\d{2}[A-Z0-9]{6,14}').hasMatch(text) ||
        text.contains('DRIVING') ||
        text.contains('LICENCE') ||
        text.contains('LICENSE');
  }

  bool _hasPassport(String text) {
    return RegExp(r'[A-Z][A-Z0-9]\d{6,8}').hasMatch(text) ||
        text.contains('PASSPORT');
  }
}
