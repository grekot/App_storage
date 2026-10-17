import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../domain/release.dart';

/// Pobieranie przerwane przyciskiem „Anuluj".
class DownloadCancelled implements Exception {
  const DownloadCancelled();
  @override
  String toString() => 'Anulowano pobieranie.';
}

class DownloadException implements Exception {
  const DownloadException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Uchwyt anulowania trwającego pobierania.
class CancelToken {
  final _completer = Completer<void>();
  bool get isCancelled => _completer.isCompleted;
  Future<void> get whenCancelled => _completer.future;
  void cancel() {
    if (!_completer.isCompleted) _completer.complete();
  }
}

/// Pobiera APK do katalogu podręcznego (`cache/updates/PAKIET.apk`).
/// Przeniesione z samoaktualizacji GPS RTK: tylko zaufany HTTPS z GitHuba, limity czasu
/// na odpowiedź i na przerwę w danych, limit rozmiaru, anulowanie, weryfikacja SHA-256.
class ApkDownloader {
  ApkDownloader({
    http.Client? client,
    Future<Directory> Function()? tempDir,
    this.requestTimeout = const Duration(seconds: 20),
    this.stallTimeout = const Duration(seconds: 30),
    this.maxBytes = 400 * 1024 * 1024,
  })  : _client = client ?? http.Client(),
        _tempDir = tempDir ?? getTemporaryDirectory;

  final http.Client _client;
  final Future<Directory> Function() _tempDir;
  final Duration requestTimeout;
  final Duration stallTimeout;
  final int maxBytes;

  Future<File> download(
    String url, {
    required String fileName,
    String? expectedSha256,
    void Function(double progress)? onProgress,
    CancelToken? cancel,
  }) async {
    if (!isTrustedDownloadUrl(url)) {
      throw DownloadException('Odrzucono link spoza GitHub: $url');
    }
    final req = http.Request('GET', Uri.parse(url))
      ..followRedirects = true
      ..headers['Accept'] = 'application/octet-stream'
      ..headers['User-Agent'] = 'grekot-sklep';
    final cancelled = cancel?.whenCancelled.then<http.StreamedResponse>((_) => throw const DownloadCancelled());
    cancelled?.ignore();
    final send = _client.send(req).timeout(requestTimeout);
    final resp = await (cancelled == null ? send : Future.any<http.StreamedResponse>([send, cancelled]));
    if (resp.statusCode != 200) {
      throw DownloadException('Pobieranie nie powiodło się (HTTP ${resp.statusCode}).');
    }
    final total = resp.contentLength ?? 0;
    if (total > maxBytes) throw DownloadException('Plik jest podejrzanie duży ($total B).');

    final dir = Directory('${(await _tempDir()).path}${Platform.pathSeparator}updates');
    await dir.create(recursive: true);
    final file = File('${dir.path}${Platform.pathSeparator}$fileName');
    final sink = file.openWrite();
    final digestOut = _DigestSink();
    final hasher = sha256.startChunkedConversion(digestOut);
    var received = 0;
    final done = Completer<void>();
    late final StreamSubscription<List<int>> sub;
    sub = resp.stream.timeout(stallTimeout).listen(
      (chunk) {
        received += chunk.length;
        if (received > maxBytes) {
          sub.cancel();
          if (!done.isCompleted) done.completeError(const DownloadException('Plik przekracza limit rozmiaru.'));
          return;
        }
        sink.add(chunk);
        hasher.add(chunk);
        if (total > 0) onProgress?.call(received / total);
      },
      onError: (Object e) {
        sub.cancel();
        if (!done.isCompleted) {
          done.completeError(e is TimeoutException ? const DownloadException('Łącze przestało przesyłać dane.') : e);
        }
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );
    unawaited(cancel?.whenCancelled.then((_) {
      sub.cancel();
      if (!done.isCompleted) done.completeError(const DownloadCancelled());
    }));
    try {
      await done.future;
    } catch (_) {
      await sink.close();
      await _deleteQuietly(file);
      rethrow;
    }
    await sink.close();
    hasher.close();
    final actual = digestOut.value?.toString();
    if (expectedSha256 != null && expectedSha256.isNotEmpty && actual != expectedSha256.toLowerCase()) {
      await _deleteQuietly(file);
      throw const DownloadException('Suma kontrolna pobranego pliku się nie zgadza - plik odrzucony.');
    }
    return file;
  }

  static Future<void> _deleteQuietly(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
