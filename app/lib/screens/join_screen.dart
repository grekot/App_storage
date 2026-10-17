import 'package:flutter/material.dart';

import '../services/catalog_controller.dart';
import '../services/store_repository.dart';

/// Dołączenie do grupy kodem zaproszenia (wpisanym albo z linku grekot-sklep://join/KOD).
class JoinScreen extends StatefulWidget {
  const JoinScreen({super.key, required this.controller, this.initialCode});

  final CatalogController controller;
  final String? initialCode;

  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends State<JoinScreen> {
  late final _code = TextEditingController(text: widget.initialCode ?? '');
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if ((widget.initialCode ?? '').isNotEmpty) WidgetsBinding.instance.addPostFrameCallback((_) => _join());
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final name = await widget.controller.repo.joinWithCode(_code.text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Dołączono do grupy „$name”')));
      Navigator.of(context).pop();
    } on JoinException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Nie udało się dołączyć: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Dołącz do grupy')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text('Wpisz kod zaproszenia, który dostałeś od właściciela sklepu (8 znaków).'),
          const SizedBox(height: 16),
          TextField(
            controller: _code,
            autofocus: (widget.initialCode ?? '').isEmpty,
            textCapitalization: TextCapitalization.characters,
            style: const TextStyle(fontSize: 22, letterSpacing: 4),
            decoration: InputDecoration(
              labelText: 'Kod zaproszenia',
              border: const OutlineInputBorder(),
              errorText: _error,
            ),
            onSubmitted: (_) => _busy ? null : _join(),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _join,
            child: _busy
                ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Dołącz'),
          ),
        ],
      ),
    );
  }
}
