import 'package:flutter/material.dart';

/// Pozycja na liście wyboru.
class PickItem {
  const PickItem({required this.id, required this.title, this.subtitle, this.leading, this.locked = false});

  final String id;
  final String title;
  final String? subtitle;
  final Widget? leading;

  /// Zawsze zaznaczona i niezmienna (np. administrator we własnej grupie).
  final bool locked;
}

/// Okno z listą do zaznaczania. Zwraca wybrane id albo null po anulowaniu.
Future<Set<String>?> showPicker(
  BuildContext context, {
  required String title,
  required List<PickItem> items,
  required Set<String> selected,
  String? hint,
  String emptyText = 'Brak pozycji.',
}) {
  return showDialog<Set<String>>(
    context: context,
    builder: (ctx) => _PickerDialog(title: title, items: items, initial: selected, hint: hint, emptyText: emptyText),
  );
}

class _PickerDialog extends StatefulWidget {
  const _PickerDialog({
    required this.title,
    required this.items,
    required this.initial,
    required this.emptyText,
    this.hint,
  });

  final String title;
  final List<PickItem> items;
  final Set<String> initial;
  final String? hint;
  final String emptyText;

  @override
  State<_PickerDialog> createState() => _PickerDialogState();
}

class _PickerDialogState extends State<_PickerDialog> {
  late final Set<String> _sel = {...widget.initial};

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      contentPadding: const EdgeInsets.fromLTRB(0, 12, 0, 0),
      content: SizedBox(
        width: double.maxFinite,
        child: widget.items.isEmpty
            ? Padding(padding: const EdgeInsets.all(24), child: Text(widget.emptyText))
            : ListView(
                shrinkWrap: true,
                children: [
                  if (widget.hint != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                      child: Text(widget.hint!, style: Theme.of(context).textTheme.bodySmall),
                    ),
                  for (final it in widget.items)
                    CheckboxListTile(
                      value: it.locked || _sel.contains(it.id),
                      onChanged: it.locked
                          ? null
                          : (v) => setState(() => v == true ? _sel.add(it.id) : _sel.remove(it.id)),
                      secondary: it.leading,
                      title: Text(it.title),
                      subtitle: it.subtitle == null ? null : Text(it.subtitle!),
                      controlAffinity: ListTileControlAffinity.trailing,
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Anuluj')),
        FilledButton(onPressed: () => Navigator.pop(context, _sel), child: const Text('Zapisz')),
      ],
    );
  }
}
