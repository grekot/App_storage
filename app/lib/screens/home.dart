import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wspolne/wspolne.dart' show AccountRepository;

import '../services/catalog_controller.dart';
import '../services/store_repository.dart';
import 'app_details_screen.dart';
import 'catalog_screen.dart';
import 'join_screen.dart';

/// Zalogowany użytkownik: kontroler katalogu, linki grekot-sklep://, powiadomienia.
class StoreHome extends StatefulWidget {
  const StoreHome({super.key, required this.uid, required this.email});

  final String uid;
  final String email;

  @override
  State<StoreHome> createState() => _StoreHomeState();
}

class _StoreHomeState extends State<StoreHome> {
  late final CatalogController _c = CatalogController(repo: StoreRepository(widget.uid, widget.email));
  final _navigator = GlobalKey<NavigatorState>();
  StreamSubscription<String>? _links;

  @override
  void initState() {
    super.initState();
    // Wpis w książce adresowej - właściciel może dodać tę osobę do grupy po e-mailu.
    AccountRepository(widget.uid, widget.email).registerEmail().catchError((_) {});
    unawaited(_c.start());
    unawaited(_c.notifications.start(
      onRelease: (pkg, title) {
        unawaited(_c.refresh());
        final ctx = _navigator.currentContext;
        if (ctx != null && title != null) {
          ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(title)));
        }
      },
      onOpen: _openApp,
    ));
    _links = _c.installer.links.listen(_handleLink);
    _c.installer.takeLink().then((l) {
      if (l != null) _handleLink(l);
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _links?.cancel();
    _c.dispose();
    super.dispose();
  }

  /// `grekot-sklep://app/PAKIET` albo `grekot-sklep://join/KOD`
  void _handleLink(String link) {
    final uri = Uri.tryParse(link);
    if (uri == null) return;
    final arg = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : '';
    switch (uri.host) {
      case 'app' when arg.isNotEmpty:
        _openApp(arg);
      case 'join' when arg.isNotEmpty:
        _push(JoinScreen(controller: _c, initialCode: StoreRepository.normalizeCode(arg)));
    }
  }

  void _openApp(String packageName) {
    // Katalog może się jeszcze wczytywać - poczekaj chwilę na wpis.
    var tries = 0;
    Timer.periodic(const Duration(milliseconds: 300), (t) {
      if (_c.entry(packageName) != null || ++tries > 20) {
        t.cancel();
        if (_c.entry(packageName) != null) _push(AppDetailsScreen(controller: _c, packageName: packageName));
      }
    });
  }

  void _push(Widget screen) => _navigator.currentState?.push(MaterialPageRoute(builder: (_) => screen));

  @override
  Widget build(BuildContext context) {
    // Własny Navigator: linki i powiadomienia otwierają ekrany nad katalogiem.
    return NavigatorPopHandler(
      onPopWithResult: (_) => _navigator.currentState?.maybePop(),
      child: Navigator(
        key: _navigator,
        onGenerateRoute: (_) => MaterialPageRoute(builder: (_) => CatalogScreen(controller: _c)),
      ),
    );
  }
}
