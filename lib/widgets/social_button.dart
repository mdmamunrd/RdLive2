import 'package:flutter/material.dart';

class SocialButton extends StatelessWidget {
  final String label;
  final Widget icon;
  final Color background;
  final Color foreground;
  final bool loading;
  final VoidCallback? onPressed;

  const SocialButton({
    super.key,
    required this.label,
    required this.icon,
    required this.background,
    required this.foreground,
    this.loading = false,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton(
        onPressed: loading ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: background,
          foregroundColor: foreground,
          disabledBackgroundColor: background.withValues(alpha: .7),
          elevation: 6,
          shadowColor: Colors.black45,
          shape: const StadiumBorder(),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (loading)
              SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.4, color: foreground),
              )
            else
              icon,
            const SizedBox(width: 12),
            Text(label),
          ],
        ),
      ),
    );
  }
}

/// Multicolour "G" mark for Google. Swap with the official asset if desired.
class GoogleMark extends StatelessWidget {
  const GoogleMark({super.key});
  @override
  Widget build(BuildContext context) => ShaderMask(
        shaderCallback: (r) => const SweepGradient(
          colors: [Color(0xFF4285F4), Color(0xFF34A853), Color(0xFFFBBC05), Color(0xFFEA4335), Color(0xFF4285F4)],
          stops: [0, .3, .5, .8, 1],
        ).createShader(r),
        child: const Text('G',
            style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: Colors.white, height: 1)),
      );
}
