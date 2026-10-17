import 'package:flutter_test/flutter_test.dart';
import 'package:sklep/domain/release.dart';

Map<String, dynamic> rel(
  String tag, {
  List<Map<String, dynamic>> assets = const [],
  bool draft = false,
  bool pre = false,
}) =>
    {
      'tag_name': tag,
      'draft': draft,
      'prerelease': pre,
      'body': 'Zmiany w $tag',
      'html_url': 'https://github.com/grekot/x/releases/tag/$tag',
      'published_at': '2026-10-01T10:00:00Z',
      'assets': assets,
    };

Map<String, dynamic> asset(String name, {String? digest, int size = 1000, String host = 'github.com'}) => {
      'name': name,
      'size': size,
      'browser_download_url': 'https://$host/grekot/x/releases/download/t/$name',
      'digest': ?digest,
    };

void main() {
  group('pickGithubRelease', () {
    test('pomija szkice, pre-release i wydania bez APK', () {
      final list = [
        rel('v3.0.0', draft: true, assets: [asset('a.apk')]),
        rel('v2.1.0', pre: true, assets: [asset('a.apk')]),
        rel('v2.0.0', assets: [asset('notes.txt')]),
        rel('v1.0.0', assets: [asset('a.apk')]),
      ];
      final r = pickGithubRelease(list, tagPrefix: 'v', assetName: 'a')!;
      expect(r.tag, 'v1.0.0');
      expect(r.versionName, '1.0.0');
    });

    test('pre-release, gdy włączone', () {
      final list = [
        rel('v2.1.0', pre: true, assets: [asset('a.apk')]),
        rel('v1.0.0', assets: [asset('a.apk')]),
      ];
      final r = pickGithubRelease(list, tagPrefix: 'v', assetName: 'a', includePrerelease: true)!;
      expect(r.tag, 'v2.1.0');
      expect(r.prerelease, isTrue);
    });

    test('monorepo: tylko tagi z prefiksem aplikacji', () {
      final list = [
        rel('powrot-v1.1.0', assets: [asset('powrot.apk')]),
        rel('zakupy-v1.3.0', assets: [asset('zakupy.apk'), asset('app.json'), asset('icon.png')]),
      ];
      final r = pickGithubRelease(list, tagPrefix: 'zakupy-v', assetName: 'zakupy')!;
      expect(r.tag, 'zakupy-v1.3.0');
      expect(r.versionName, '1.3.0');
      expect(r.apkUrl, endsWith('/zakupy.apk'));
      expect(r.appJsonUrl, endsWith('/app.json'));
      expect(r.iconUrl, endsWith('/icon.png'));
    });

    test('woli plik o podanej nazwie, a bez niego bierze pierwszy .apk', () {
      final list = [
        rel('v1.0.0', assets: [asset('inny.apk'), asset('gps_rtk.apk')]),
      ];
      expect(pickGithubRelease(list, tagPrefix: 'v', assetName: 'gps_rtk')!.apkUrl, endsWith('/gps_rtk.apk'));
      expect(pickGithubRelease(list, tagPrefix: 'v', assetName: '')!.apkUrl, endsWith('/inny.apk'));
    });

    test('odrzuca linki spoza GitHuba', () {
      final list = [
        rel('v1.0.0', assets: [asset('a.apk', host: 'evil.example.com')]),
      ];
      expect(pickGithubRelease(list, tagPrefix: 'v', assetName: 'a'), isNull);
    });

    test('SHA-256 z pola digest', () {
      final sha = 'ab' * 32;
      final list = [
        rel('v1.0.0', assets: [asset('a.apk', digest: 'sha256:$sha')]),
      ];
      expect(pickGithubRelease(list, tagPrefix: 'v', assetName: 'a')!.sha256, sha);
    });
  });

  test('app.json uzupełnia wersję, pakiet i podpis', () {
    const base = AppRelease(tag: 'v1.0.0', versionName: '1.0.0', apkUrl: 'https://github.com/x.apk');
    final r = base.withAppJson({
      'schema': 'grekot-app-release/1',
      'packageName': 'pl.grekot.zakupy',
      'versionName': '1.0.0',
      'versionCode': 42,
      'minSdk': 24,
      'size': 123,
      'sha256': 'AB' * 32,
      'signerSha256': 'CD' * 32,
      'publishedAt': '2026-10-17T08:00:00Z',
    });
    expect(r.versionCode, 42);
    expect(r.packageName, 'pl.grekot.zakupy');
    expect(r.sha256, 'ab' * 32);
    expect(r.signerSha256, 'cd' * 32);
    expect(r.minSdk, 24);
    expect(r.publishedAt, DateTime.utc(2026, 10, 17, 8));
  });

  test('toJson / fromJson w obie strony', () {
    final r = AppRelease(
      tag: 'v2.0.0',
      versionName: '2.0.0',
      versionCode: 7,
      apkUrl: 'https://github.com/a.apk',
      sha256: 'aa' * 32,
      size: 99,
      notes: 'x',
      publishedAt: DateTime.utc(2026, 1, 2),
    );
    final back = AppRelease.fromJson(r.toJson())!;
    expect(back.versionCode, 7);
    expect(back.sha256, r.sha256);
    expect(back.publishedAt, r.publishedAt);
    expect(AppRelease.fromJson({'tag': 'v1'}), isNull);
  });

  test('isTrustedDownloadUrl', () {
    expect(isTrustedDownloadUrl('https://github.com/a/b/releases/download/v1/a.apk'), isTrue);
    expect(isTrustedDownloadUrl('https://release-assets.githubusercontent.com/x'), isTrue);
    expect(isTrustedDownloadUrl('http://github.com/a.apk'), isFalse);
    expect(isTrustedDownloadUrl('https://github.com.evil.pl/a.apk'), isFalse);
  });
}
