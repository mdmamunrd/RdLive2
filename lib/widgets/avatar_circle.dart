import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

const _palette = <List<Color>>[
  [Color(0xFFF472B6), Color(0xFF7C3AED)],
  [Color(0xFF10B981), Color(0xFF065F46)],
  [Color(0xFFF59E0B), Color(0xFFB91C1C)],
  [Color(0xFF38BDF8), Color(0xFF4338CA)],
  [Color(0xFFA78BFA), Color(0xFFEC4899)],
];

/// Round (or rounded-square) avatar. Shows [url] when given, otherwise a
/// gradient with the first letter of [name].
class AvatarCircle extends StatelessWidget {
  final String name;
  final String? url;
  final double size;

  /// null = perfect circle.
  final double? cornerRadius;

  const AvatarCircle({
    super.key,
    required this.name,
    this.url,
    this.size = 48,
    this.cornerRadius,
  });

  List<Color> get _colors =>
      _palette[name.codeUnits.fold<int>(0, (a, b) => a + b) % _palette.length];

  Widget _initial() => DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: _colors,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Center(
          child: Text(
            name.isEmpty ? '?' : String.fromCharCode(name.runes.first).toUpperCase(),
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: size * .42,
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final hasUrl = url != null && url!.isNotEmpty;
    return ClipRRect(
      borderRadius: BorderRadius.circular(cornerRadius ?? size / 2),
      child: SizedBox(
        width: size,
        height: size,
        child: hasUrl
            ? CachedNetworkImage(
                imageUrl: url!,
                fit: BoxFit.cover,
                placeholder: (_, __) => _initial(),
                errorWidget: (_, __, ___) => _initial(),
              )
            : _initial(),
      ),
    );
  }
}
