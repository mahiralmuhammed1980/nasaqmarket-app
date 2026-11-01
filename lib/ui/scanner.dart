import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// يفتح الكاميرا لمسح باركود ويعيد النص الخام (يشمل GS1 DataMatrix).
/// يعمل على الهاتف والتابلت. يعيد null عند الإغلاق.
Future<String?> scanBarcode(BuildContext context) =>
    Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const _ScannerPage()));

class _ScannerPage extends StatefulWidget {
  const _ScannerPage();
  @override
  State<_ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<_ScannerPage> {
  final _c = MobileScannerController(
    formats: const [
      BarcodeFormat.ean13,
      BarcodeFormat.ean8,
      BarcodeFormat.upcA,
      BarcodeFormat.upcE,
      BarcodeFormat.code128,
      BarcodeFormat.code39,
      BarcodeFormat.dataMatrix,
      BarcodeFormat.qrCode,
    ],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _done = false;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('مسح الباركود'), actions: [
          IconButton(icon: const Icon(Icons.flash_on), onPressed: _c.toggleTorch),
          IconButton(icon: const Icon(Icons.cameraswitch), onPressed: _c.switchCamera),
        ]),
        body: Stack(children: [
          MobileScanner(
            controller: _c,
            onDetect: (cap) {
              if (_done) return;
              final raw = cap.barcodes.map((b) => b.rawValue).whereType<String>().firstOrNull;
              if (raw == null || raw.isEmpty) return;
              _done = true;
              Navigator.pop(context, raw);
            },
            errorBuilder: (ctx, e) => Center(
                child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                e.errorCode == MobileScannerErrorCode.permissionDenied
                    ? 'لم يُمنح إذن الكاميرا. فعّله من إعدادات الهاتف.'
                    : 'تعذّر تشغيل الكاميرا. يمكنك إدخال الباركود يدوياً.',
                textAlign: TextAlign.center,
              ),
            )),
          ),
          Center(
            child: Container(
              width: 280,
              height: 160,
              decoration: BoxDecoration(
                  border: Border.all(color: Colors.white, width: 2), borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ]),
      );
}
