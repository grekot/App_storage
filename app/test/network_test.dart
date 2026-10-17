import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sklep/services/downloader.dart';
import 'package:sklep/services/github_releases.dart';

void main() {
  group('GithubReleases', () {
    late int apiCalls;
    late int jsonCalls;
    String? lastIfNoneMatch;

    final releases = [
      {
        'tag_name': 'zakupy-v1.3.0',
        'draft': false,
        'prerelease': false,
        'body': '',
        'html_url': 'https://github.com/grekot/T_rex_3/releases/tag/zakupy-v1.3.0',
        'published_at': '2026-10-01T10:00:00Z',
        'assets': [
          {'name': 'zakupy.apk', 'size': 5, 'browser_download_url': 'https://github.com/d/zakupy.apk'},
          {'name': 'app.json', 'size': 5, 'browser_download_url': 'https://github.com/d/app.json'},
        ],
      },
    ];

    MockClient client({int status = 200}) => MockClient((req) async {
          if (req.url.host == 'api.github.com') {
            apiCalls++;
            lastIfNoneMatch = req.headers['If-None-Match'];
            if (lastIfNoneMatch == '"e1"') return http.Response('', 304);
            return http.Response(jsonEncode(releases), status, headers: {'etag': '"e1"'});
          }
          jsonCalls++;
          return http.Response(jsonEncode({'versionCode': 31, 'packageName': 'pl.grekot.zakupy'}), 200);
        });

    setUp(() {
      apiCalls = 0;
      jsonCalls = 0;
      lastIfNoneMatch = null;
      SharedPreferences.setMockInitialValues({});
    });

    test('dociąga app.json i pamięta wynik', () async {
      final gh = GithubReleases(client: client());
      final r = await gh.latest(repo: 'grekot/T_rex_3', tagPrefix: 'zakupy-v', assetName: 'zakupy');
      expect(r!.versionCode, 31);
      expect(r.packageName, 'pl.grekot.zakupy');
      expect(apiCalls, 1);
      expect(jsonCalls, 1);

      // Drugi raz w ciągu 15 minut - bez sieci.
      final again = await gh.latest(repo: 'grekot/T_rex_3', tagPrefix: 'zakupy-v', assetName: 'zakupy');
      expect(again!.versionCode, 31);
      expect(apiCalls, 1);
    });

    test('wymuszone odświeżenie pyta warunkowo (304 nie zużywa limitu)', () async {
      final gh = GithubReleases(client: client());
      await gh.latest(repo: 'grekot/T_rex_3', tagPrefix: 'zakupy-v', assetName: 'zakupy');
      final r = await gh.latest(repo: 'grekot/T_rex_3', tagPrefix: 'zakupy-v', assetName: 'zakupy', force: true);
      expect(lastIfNoneMatch, '"e1"');
      expect(apiCalls, 2);
      expect(jsonCalls, 1);
      expect(r!.versionCode, 31);
    });

    test('limit GitHuba bez pamięci podręcznej = czytelny błąd', () async {
      final gh = GithubReleases(client: client(status: 403));
      expect(
        () => gh.latest(repo: 'grekot/T_rex_3', tagPrefix: 'zakupy-v', assetName: 'zakupy'),
        throwsA(isA<ReleaseException>()),
      );
    });
  });

  group('ApkDownloader', () {
    late Directory tmp;
    final bytes = utf8.encode('to jest apk');
    final good = sha256.convert(bytes).toString();

    setUp(() async => tmp = await Directory.systemTemp.createTemp('sklep_test'));
    tearDown(() async => tmp.delete(recursive: true));

    ApkDownloader dl() => ApkDownloader(
          client: MockClient.streaming((req, _) async => http.StreamedResponse(
                Stream.value(bytes),
                200,
                contentLength: bytes.length,
              )),
          tempDir: () async => tmp,
        );

    test('pobiera i sprawdza SHA-256', () async {
      final progress = <double>[];
      final f = await dl().download(
        'https://github.com/a.apk',
        fileName: 'x.apk',
        expectedSha256: good,
        onProgress: progress.add,
      );
      expect(await f.readAsBytes(), bytes);
      expect(progress.last, 1.0);
    });

    test('zła suma kontrolna - plik usunięty', () async {
      await expectLater(
        dl().download('https://github.com/a.apk', fileName: 'x.apk', expectedSha256: '00' * 32),
        throwsA(isA<DownloadException>()),
      );
      expect(File('${tmp.path}/updates/x.apk').existsSync(), isFalse);
    });

    test('link spoza GitHuba odrzucony', () async {
      await expectLater(
        dl().download('https://example.com/a.apk', fileName: 'x.apk'),
        throwsA(isA<DownloadException>()),
      );
    });

    test('anulowanie', () async {
      final token = CancelToken()..cancel();
      await expectLater(
        dl().download('https://github.com/a.apk', fileName: 'x.apk', cancel: token),
        throwsA(isA<DownloadCancelled>()),
      );
    });
  });
}
