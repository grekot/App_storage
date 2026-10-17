import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Powiadomienia o nowych wersjach (FCM, etap 3).
///
/// CI po wydaniu wysyła wiadomość na temat `app_<pakiet z _ zamiast kropek>`.
/// Sklep zapisuje się na tematy aplikacji widocznych w katalogu (i własny),
/// więc powiadomienie dostają tylko osoby, które mają daną aplikację w katalogu.
/// Gdy sklep jest w tle, powiadomienie pokazuje system; na pierwszym planie - [onRelease].
class Notifications {
  Notifications({FirebaseMessaging? messaging}) : _fcm = messaging ?? FirebaseMessaging.instance;

  final FirebaseMessaging _fcm;
  static const _subscribedKey = 'fcm_topics';
  static const enabledKey = 'notifications_enabled';

  StreamSubscription<RemoteMessage>? _onMessage;
  StreamSubscription<RemoteMessage>? _onOpened;

  static String topicFor(String packageName) => 'app_${packageName.replaceAll('.', '_')}';

  /// [onRelease] - nowa wersja przyszła, gdy sklep jest otwarty (odśwież katalog).
  /// [onOpen] - użytkownik stuknął powiadomienie (otwórz kartę aplikacji).
  Future<void> start({
    required void Function(String? packageName, String? title) onRelease,
    required void Function(String packageName) onOpen,
  }) async {
    _onMessage = FirebaseMessaging.onMessage.listen((m) {
      onRelease(m.data['packageName'] as String?, m.notification?.title);
    });
    _onOpened = FirebaseMessaging.onMessageOpenedApp.listen((m) {
      final pkg = m.data['packageName'] as String?;
      if (pkg != null && pkg.isNotEmpty) onOpen(pkg);
    });
    try {
      final initial = await _fcm.getInitialMessage();
      final pkg = initial?.data['packageName'] as String?;
      if (pkg != null && pkg.isNotEmpty) onOpen(pkg);
    } catch (_) {}
  }

  Future<bool> isEnabled() async => (await SharedPreferences.getInstance()).getBool(enabledKey) ?? true;

  Future<void> setEnabled(bool enabled, Iterable<String> packages) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(enabledKey, enabled);
    await sync(enabled ? packages : const []);
  }

  /// Dopasowuje subskrypcje tematów do listy pakietów z katalogu.
  Future<void> sync(Iterable<String> packages) async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(enabledKey) ?? true;
    final wanted = enabled ? packages.where((p) => p.isNotEmpty).map(topicFor).toSet() : <String>{};
    final current = (prefs.getStringList(_subscribedKey) ?? const []).toSet();
    if (wanted.isNotEmpty && current.isEmpty) {
      // Android 13+: systemowe pytanie o zgodę na powiadomienia (raz).
      try {
        await _fcm.requestPermission();
      } catch (_) {}
    }
    final done = <String>{...current};
    for (final t in wanted.difference(current)) {
      try {
        await _fcm.subscribeToTopic(t);
        done.add(t);
      } catch (_) {}
    }
    for (final t in current.difference(wanted)) {
      try {
        await _fcm.unsubscribeFromTopic(t);
        done.remove(t);
      } catch (_) {}
    }
    await prefs.setStringList(_subscribedKey, done.toList());
  }

  Future<void> dispose() async {
    await _onMessage?.cancel();
    await _onOpened?.cancel();
  }
}
