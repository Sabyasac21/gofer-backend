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
      final text = _normalize(recognizedText.text);
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
        extractedFields: _safeFields(idType, text),
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

  Map<String, String> _safeFields(IndianIdType idType, String text) {
    final match = _documentNumber(idType, text);
    return {
      'detectedDocumentType': idType.name,
      if (match != null) 'documentNumberMasked': _mask(match),
    };
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
