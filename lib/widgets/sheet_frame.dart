import 'package:flutter/material.dart';

/// White rounded bottom-sheet container with a drag handle.
/// Use as the builder result of showModalBottomSheet (backgroundColor: transparent).
class SheetFrame extends StatelessWidget {
  final Widget child;

  /// Optional fixed height as a fraction of the screen (e.g. 0.78).
  final double? heightFactor;

  const SheetFrame({super.key, required this.child, this.heightFactor});

  @override
  Widget build(BuildContext context) {
    final h = heightFactor == null ? null : MediaQuery.of(context).size.height * heightFactor!;
    return Container(
      height: h,
      width: double.infinity,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: Column(
            mainAxisSize: heightFactor == null ? MainAxisSize.min : MainAxisSize.max,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.black12,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(height: 12),
              if (heightFactor == null) child else Expanded(child: child),
            ],
          ),
        ),
      ),
    );
  }
}
