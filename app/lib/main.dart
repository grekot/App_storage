import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:wspolne/wspolne.dart';

import 'firebase_options.dart';
import 'screens/home.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (firebaseConfigured) {
    await Firebase.initializeApp(options: firebaseOptions);
  }
  runApp(const SklepApp());
}

class SklepApp extends StatelessWidget {
  const SklepApp({super.key});

  static const _seed = Color(0xFF1565C0);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sklep rodzinny',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: _seed), useMaterial3: true),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: _seed, brightness: Brightness.dark),
        useMaterial3: true,
      ),
      home: firebaseConfigured ? const AuthGate() : const _NotConfiguredScreen(),
    );
  }
}

/// Po zalogowaniu katalog, w przeciwnym razie ekran logowania (wspólny z Zakupami i Powrotem).
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        final user = snapshot.data;
        if (user == null) {
          return const LoginScreen(
            appName: 'Sklep rodzinny',
            icon: Icons.storefront_outlined,
            description: 'Instaluj i aktualizuj aplikacje udostępnione Twojej grupie.',
          );
        }
        return StoreHome(key: ValueKey(user.uid), uid: user.uid, email: user.email ?? '');
      },
    );
  }
}

class _NotConfiguredScreen extends StatelessWidget {
  const _NotConfiguredScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'Brak konfiguracji Firebase.\n\n'
            'Zarejestruj aplikację pl.grekot.sklep w projekcie Firebase, zapisz google-services.json '
            'w app/android/app/ i uruchom: node tools/configure.mjs (instrukcja: firebase/KONFIGURACJA.md).',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
