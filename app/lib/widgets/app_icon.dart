import 'package:flutter/material.dart';

/// Ikona aplikacji z sieci, a gdy jej brak - pierwsza litera nazwy na kolorowym tle.
class AppIcon extends StatelessWidget {
  const AppIcon({super.key, required this.name, this.url, this.size = 48});

  final String name;
  final String? url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fallback = _Letter(name: name, size: size);
    final u = url;
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.22),
      child: SizedBox.square(
        dimension: size,
        child: u == null || u.isEmpty
            ? fallback
            : Image.network(u, fit: BoxFit.cover, errorBuilder: (_, _, _) => fallback),
      ),
    );
  }
}

class _Letter extends StatelessWidget {
  const _Letter({required this.name, required this.size});
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final hue = (name.hashCode % 360).abs().toDouble();
    final bg = HSLColor.fromAHSL(1, hue, 0.45, 0.45).toColor();
    return ColoredBox(
      color: bg,
      child: Center(
        child: Text(
          name.isEmpty ? '?' : name.characters.first.toUpperCase(),
          style: TextStyle(color: Colors.white, fontSize: size * 0.45, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
