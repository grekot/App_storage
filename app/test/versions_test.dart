import 'package:flutter_test/flutter_test.dart';
import 'package:sklep/domain/versions.dart';

void main() {
  group('compareVersionNames', () {
    test('numerycznie po segmentach', () {
      expect(compareVersionNames('1.2.10', '1.2.9'), greaterThan(0));
      expect(compareVersionNames('v1.2.0', '1.2.0'), 0);
      expect(compareVersionNames('1.2', '1.2.0'), 0);
      expect(compareVersionNames('1.0.0+5', '1.0.0+9'), 0);
      expect(compareVersionNames('2.0.0-beta', '1.9.9'), greaterThan(0));
      expect(compareVersionNames('', '0.0.1'), lessThan(0));
    });
  });

  group('tagi', () {
    test('wersja z tagu', () {
      expect(versionFromTag('v1.2.0', 'v'), '1.2.0');
      expect(versionFromTag('zakupy-v1.4.1', 'zakupy-v'), '1.4.1');
      expect(versionFromTag('1.0.0', 'v'), '1.0.0');
    });

    test('prefiks v akceptuje zwykłe tagi wersji', () {
      expect(tagMatchesPrefix('v1.2.0', 'v'), isTrue);
      expect(tagMatchesPrefix('1.2.0', 'v'), isTrue);
      expect(tagMatchesPrefix('zakupy-v1.2.0', 'v'), isFalse);
    });

    test('prefiks monorepo', () {
      expect(tagMatchesPrefix('zakupy-v1.2.0', 'zakupy-v'), isTrue);
      expect(tagMatchesPrefix('powrot-v1.2.0', 'zakupy-v'), isFalse);
      expect(tagMatchesPrefix('zakupy-vX', 'zakupy-v'), isFalse);
    });
  });

  group('decideStatus', () {
    test('brak wydania', () {
      expect(decideStatus(installed: false, hasRelease: false), AppStatus.unavailable);
      expect(decideStatus(installed: true, hasRelease: false), AppStatus.upToDate);
    });

    test('niezainstalowana', () {
      expect(decideStatus(installed: false, hasRelease: true, releaseName: '1.0.0'), AppStatus.notInstalled);
    });

    test('versionCode ma pierwszeństwo przed nazwą', () {
      expect(
        decideStatus(
            installed: true, installedName: '1.0.0', installedCode: 1, hasRelease: true, releaseName: '1.0.0', releaseCode: 12),
        AppStatus.updateAvailable,
      );
      expect(
        decideStatus(
            installed: true, installedName: '1.0.0', installedCode: 12, hasRelease: true, releaseName: '1.0.0', releaseCode: 12),
        AppStatus.upToDate,
      );
      expect(
        decideStatus(
            installed: true, installedName: '9.0.0', installedCode: 99, hasRelease: true, releaseName: '1.0.0', releaseCode: 12),
        AppStatus.newerInstalled,
      );
    });

    test('bez versionCode wydania porównuje nazwy', () {
      expect(
        decideStatus(installed: true, installedName: '1.1.0', installedCode: 5, hasRelease: true, releaseName: '1.2.0'),
        AppStatus.updateAvailable,
      );
    });

    test('inny podpis = ponowna instalacja', () {
      expect(
        decideStatus(
          installed: true,
          installedCode: 1,
          installedSigner: 'AA:BB',
          hasRelease: true,
          releaseCode: 2,
          releaseSigner: 'ccdd',
        ),
        AppStatus.needsReinstall,
      );
      expect(
        decideStatus(
          installed: true,
          installedCode: 1,
          installedSigner: 'ccdd',
          hasRelease: true,
          releaseCode: 2,
          releaseSigner: 'CCDD',
        ),
        AppStatus.updateAvailable,
      );
    });
  });

  group('isSignerTrusted', () {
    final a = 'aa' * 32, b = 'bb' * 32, c = 'cc' * 32;

    test('klucz sklepu', () {
      expect(isSignerTrusted(apkSigner: a, storeSigner: a), isTrue);
      expect(isSignerTrusted(apkSigner: a.toUpperCase(), storeSigner: a), isTrue);
    });

    test('lista grupy', () {
      expect(isSignerTrusted(apkSigner: b, storeSigner: a, trustedSigners: [b]), isTrue);
    });

    test('klucz zainstalowanej aplikacji', () {
      expect(isSignerTrusted(apkSigner: c, storeSigner: a, installedSigner: c), isTrue);
    });

    test('nieznany albo pusty', () {
      expect(isSignerTrusted(apkSigner: c, storeSigner: a, trustedSigners: [b]), isFalse);
      expect(isSignerTrusted(apkSigner: null, storeSigner: a), isFalse);
      expect(isSignerTrusted(apkSigner: '', storeSigner: ''), isFalse);
    });

    test('odcisk z dwukropkami', () {
      expect(normalizeFingerprint('AB:CD:EF'), 'abcdef');
    });
  });
}
