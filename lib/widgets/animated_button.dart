import 'package:flutter/material.dart';

class AnimatedButton extends StatefulWidget {
  final VoidCallback onPressed;
  final Widget child;
  final ButtonStyle? style;

  const AnimatedButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.style,
  });

  @override
  State<AnimatedButton> createState() => _AnimatedButtonState();
}

class _AnimatedButtonState extends State<AnimatedButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
      reverseDuration: const Duration(milliseconds: 100),
    );
    _scaleAnimation = Tween<double>(
      begin: 1.0,
      end: 0.95,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _scaleAnimation,
      child: ElevatedButton(
        onPressed: () {
          widget.onPressed();
        },
        onFocusChange: (hasFocus) {
          if (hasFocus) {
            _controller.forward();
          } else {
            _controller.reverse();
          }
        },
        onHover: (isHovering) {
          if (isHovering) {
            _controller.forward();
          } else {
            _controller.reverse();
          }
        },
        style: widget.style,
        child: Listener(
          onPointerDown: (_) => _controller.forward(),
          onPointerUp: (_) => _controller.reverse(),
          onPointerCancel: (_) => _controller.reverse(),
          child: widget.child,
        ),
      ),
    );
  }
}
