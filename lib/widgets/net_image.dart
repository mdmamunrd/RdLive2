import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// Network image with a gradient placeholder. Pass a null/empty [url] to
/// show only the placeholder (used while the API is not connected).
class NetImage extends StatelessWidget {
  final String? url;
  final List<Color> placeholder;
  final BoxFit fit;

  const NetImage({
    super.key,
    this.url,
    this.placeholder = const [Color(0xFF8B5CF6), Color(0xFFEC4899)],
    this.fit = BoxFit.cover,
  });

  Widget get _fallback => DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: placeholder,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: const Center(
          child: Icon(Icons.mic_rounded, color: Colors.white54, size: 44),
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (url == null || url!.isEmpty) return _fallback;
    return CachedNetworkImage(
      imageUrl: url!,
      fit: fit,
      placeholder: (_, __) => _fallback,
      errorWidget: (_, __, ___) => _fallback,
    );
  }
}
